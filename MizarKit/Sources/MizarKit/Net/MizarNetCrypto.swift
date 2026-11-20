//
//  MizarNetCrypto.swift
//  MizarKit
//
//  The handshake and the per-packet seal.
//
//  The design is a stripped-down Noise IK with identities the pairing
//  already established:
//
//    - both sides hold a static Ed25519 identity (``MizarNetIdentity``),
//      derived from the host secret or the device token — the same trust
//      the pairing code created, carried into the direct path;
//    - both sides generate a fresh X25519 ephemeral per connection and
//      *sign* it with the static identity, so a peer that answers is
//      provably the endpoint the ticket named, and an impersonator cannot
//      produce the signature;
//    - the session keys come from the ephemeral-ephemeral shared secret
//      through HKDF, one key per direction, salted with a hash of the two
//      endpoint ids — so the session is bound to *these two* peers, and a
//      reflected transcript from another connection does not decrypt;
//    - every post-handshake packet is sealed with ChaCha20-Poly1305 under
//      a nonce derived from its packet number, with the packet header as
//      authenticated data — the QUIC packet-protection idea, minus the
//      header-protection layer this deployment does not need.
//
//  Ephemeral keys mean forward secrecy: a stolen identity key does not
//  decrypt a recorded session. Signing them means no unauthenticated
//  Diffie-Hellman: the man-in-the-middle that a bare ECDH would allow is
//  exactly what the signature closes.
//

import CryptoKit
import Foundation

/// The AEAD. CryptoKit has always spelled it `ChaChaPoly`; there is no
/// `ChaCha20Poly1305` type in any released SDK, so the package builds on the
/// oldest supported toolchain and on Xcode 27 alike.
typealias MizarNetAEAD = ChaChaPoly

enum MizarNetCrypto {
    /// The info string baked into every derived key. Part of the wire
    /// contract: changing it invalidates every session in flight.
    static let sessionSaltInfo = "mizar-net/session/v1"

    /// A fresh ephemeral X25519 key pair.
    static func ephemeralKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// The salt that binds a session to its two peers.
    ///
    /// Sorted by endpoint id, so both sides derive the same salt without
    /// negotiating who is "first".
    static func sessionSalt(localEndpointId: String, remoteEndpointId: String) -> Data {
        var material = Data(sessionSaltInfo.utf8)
        let ordered = [localEndpointId, remoteEndpointId].sorted()
        for id in ordered {
            material.append(Data(id.utf8))
            material.append(0x00)
        }
        return Data(SHA256.hash(data: material))
    }

    /// The two session keys: one per direction.
    ///
    /// - Parameters:
    ///   - sharedSecret: the ephemeral-ephemeral agreement.
    ///   - salt: from ``sessionSalt(localEndpointId:remoteEndpointId:)``.
    ///   - localIsDialer: whether the local side dialled. Decides which
    ///     derived key seals and which opens.
    /// - Returns: `(seal, open)`: the key this side sends with, and the key
    ///   it expects the peer's packets under.
    static func sessionKeys(
        sharedSecret: SharedSecret,
        salt: Data,
        localIsDialer: Bool,
    ) -> (seal: SymmetricKey, open: SymmetricKey) {
        let bytes = sharedSecret.withUnsafeBytes { Data($0) }
        let keys = sessionKeyBytes(sharedSecret: bytes, salt: salt, localIsDialer: localIsDialer)
        return (SymmetricKey(data: keys.seal), SymmetricKey(data: keys.open))
    }

    /// The two session keys, from raw bytes.
    ///
    /// The same derivation as ``sessionKeys(sharedSecret:salt:localIsDialer:)``,
    /// expressed over bytes rather than CryptoKit's `SharedSecret` — which is
    /// what a second implementation of this protocol can actually reproduce.
    /// It exists so the TypeScript side can be checked against this one: the
    /// fixture emitter asserts the two forms agree, and a mistake in either
    /// is a failed test rather than a session that silently will not open.
    ///
    /// - Parameters:
    ///   - sharedSecret: the raw ephemeral-ephemeral agreement, 32 bytes.
    ///   - salt: from ``sessionSalt(localEndpointId:remoteEndpointId:)``.
    ///   - localIsDialer: whether the local side dialled.
    /// - Returns: `(seal, open)`, 32 bytes each.
    static func sessionKeyBytes(
        sharedSecret: Data,
        salt: Data,
        localIsDialer: Bool,
    ) -> (seal: Data, open: Data) {
        let material = SymmetricKey(data: sharedSecret)
        let dialerToAcceptor = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: Data("mizar-net/dialer-to-acceptor/v1".utf8),
            outputByteCount: 32,
        )
        let acceptorToDialer = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: Data("mizar-net/acceptor-to-dialer/v1".utf8),
            outputByteCount: 32,
        )
        let seal = localIsDialer ? dialerToAcceptor : acceptorToDialer
        let open = localIsDialer ? acceptorToDialer : dialerToAcceptor
        return (seal.withUnsafeBytes { Data($0) }, open.withUnsafeBytes { Data($0) })
    }

    /// The nonce for a packet number: twelve bytes, the packet number in
    /// the last eight, zeroes before it.
    ///
    /// A 32-bit packet number leaves four leading zero bytes, so the nonce
    /// space per key is 2^32 — the connection is long gone before any
    /// reuse is conceivable, and the receiver's window rejects replays of
    /// packet numbers it has already delivered.
    static func nonce(packetNumber: UInt32) throws -> MizarNetAEAD.Nonce {
        // Four zero bytes, then the packet number as eight big-endian bytes.
        // Appended to an empty Data on purpose: `Data(count: 4)` followed by
        // an append yields eight bytes, and the leading zeros would silently
        // become part of the "number".
        var bytes = Data()
        bytes.appendUInt32(0)
        bytes.appendUInt64(UInt64(packetNumber))
        return try MizarNetAEAD.Nonce(data: bytes)
    }

    /// Seal one packet's payload.
    ///
    /// - Parameters:
    ///   - plaintext: the chunk.
    ///   - key: this side's seal key.
    ///   - packetNumber: the packet's number — its nonce.
    ///   - authenticatedData: the header bytes that must not change in
    ///     flight: magic, type, connection id, packet number, message
    ///     length. Sealing them means a relay or an attacker cannot rewrite
    ///     a data packet into a keepalive.
    /// - Returns: ciphertext with the tag appended. The nonce is *not*
    ///   carried: it is the packet number, and the receiver derives the
    ///   same one — twelve bytes saved per packet, and no nonce to forge.
    static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        packetNumber: UInt32,
        authenticatedData: Data,
    ) throws -> Data {
        let box = try MizarNetAEAD.seal(
            plaintext,
            using: key,
            nonce: try nonce(packetNumber: packetNumber),
            authenticating: authenticatedData,
        )
        // Built with `append`, not `+`: CryptoKit hands back slices whose
        // `startIndex` is not zero, `+` preserves that, and a Data with a
        // non-zero base index traps the first time somebody slices it by
        // absolute position. Everything downstream of here assumes 0.
        var wire = Data()
        wire.reserveCapacity(box.ciphertext.count + box.tag.count)
        wire.append(box.ciphertext)
        wire.append(box.tag)
        return wire
    }

    /// Open one packet's payload.
    ///
    /// - Returns: the chunk, or `nil` when the tag does not verify — which
    ///   covers corruption, tampering and the wrong key alike. A failed
    ///   open is a *return value*, not a thrown error: the caller is a
    ///   receive loop, and one bad packet is not a reason to tear down a
    ///   session.
    static func open(
        _ sealed: Data,
        key: SymmetricKey,
        packetNumber: UInt32,
        authenticatedData: Data,
    ) throws -> Data? {
        // The tag is all there is for an empty message, so 16 is a valid
        // length: ciphertext || tag, with the ciphertext possibly empty.
        // The empty case is split out rather than expressed as a range,
        // because `Data.subdata(in: 0..<0)` traps on current SDKs.
        guard sealed.count >= 16 else { return nil }
        // Sliced by the Data's own start index: a payload that reached us
        // as a slice must not be re-sliced from zero.
        let base = sealed.startIndex
        let split = base + sealed.count - 16
        let ciphertext = split == base ? Data() : sealed.subdata(in: base..<split)
        let tag = sealed.subdata(in: split..<(base + sealed.count))
        do {
            let box = try MizarNetAEAD.SealedBox(nonce: try nonce(packetNumber: packetNumber), ciphertext: ciphertext, tag: tag)
            return try MizarNetAEAD.open(box, using: key, authenticating: authenticatedData)
        } catch {
            return nil
        }
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in (0..<8).reversed() {
            append(UInt8((value >> (shift * 8)) & 0xFF))
        }
    }
}
