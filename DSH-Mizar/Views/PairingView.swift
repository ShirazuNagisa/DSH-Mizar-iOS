//
//  PairingView.swift
//  DSH-Mizar
//
//  Getting a device connected, once.
//
//  Two ways in, because the QR path can fail for reasons that have nothing to do
//  with the app: a camera that will not focus, a code on a screen across the
//  room, or a simulator with no camera at all. The scan is the one big button,
//  and the camera opens out of it inside the same small window; the manual path
//  folds out beneath it for the times the scan cannot work.
//
//  The camera is asked for at the moment "Scan" is tapped, never before: a
//  permission most sessions never need, asked at launch, is a permission the
//  operator learns to refuse with their eyes closed.
//

import SwiftUI
import MizarKit
import VisionKit

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Whether the camera is open, reported so the window holding this screen
    /// can grow for it. See ``PairingSheet``.
    var onScanningChange: (Bool) -> Void = { _ in }

    /// The camera is open, inside this window.
    @State private var scanning = false
    @State private var manual = false
    @State private var authority = ""
    @State private var code = ""
    @State private var deviceName = ""
    @State private var pairing = false
    @State private var scans = 0
    @Namespace private var lens

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MizarRing(motion: .running, size: 56)
                    .padding(.top, 22)
                    .padding(.bottom, 16)

                Text("Connect to DSH")
                    .font(.title2.weight(.bold))
                Text("On the computer, open DSH and look for the Mizar panel in the sidebar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 8)

                // The camera opens out of the button that asked for it, in this
                // window -- a viewfinder the size of the code it is looking
                // for, not a screen given over to a camera.
                ZStack {
                    if scanning {
                        viewfinder
                            .transition(.identity)
                    } else {
                        Button {
                            withMizarAnimation(.mizarBouncy) { scanning = true }
                        } label: {
                            Label("Scan the code on your computer", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!DataScannerViewController.isSupported)
                        .matchedGeometryEffect(id: "lens", in: lens)
                        .transition(.identity)
                    }
                }
                .padding(.top, 22)

                Button {
                    withMizarAnimation(.mizarSmooth) { manual.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Or enter it by hand")
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(manual ? 180 : 0))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(scale: 0.97, dims: true))
                .padding(.top, 6)

                if manual {
                    manualForm
                        .transition(.rise(distance: -12, blur: 6))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .mizarFeedback(.success, trigger: scans)
        .onChange(of: scanning) { _, open in
            onScanningChange(open)
        }
    }

    /// The camera, inside the window: square, with corners that frame the code
    /// and a way back to the button.
    private var viewfinder: some View {
        ZStack {
            Scanner { value in
                guard let target = PairingURI.parse(value) else { return }
                scans += 1
                // The code is read, so the camera and this window go away at
                // once: pairing, connecting and the first download are the
                // model's screens now. A viewfinder that stayed up over them
                // read as "the scan did not land". The haptic above is the
                // acknowledgement; what replaces this window is the proof.
                scanning = false
                dismiss()
                Task { await model.pair(with: target, deviceName: resolvedDeviceName) }
            }
            ViewfinderCorners()
                .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .padding(34)
                .shadow(color: .black.opacity(0.4), radius: 6)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withMizarAnimation(.mizarSmooth) { scanning = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                }
                Spacer()
                Text("Point at the code on your computer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .liquidCapsule()
                    .contentTransition(.opacity)
            }
            .padding(10)
            .environment(\.colorScheme, .dark)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .matchedGeometryEffect(id: "lens", in: lens)
    }

    private var manualForm: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                field {
                    TextField("Host, for example 100.64.0.1:19390", text: $authority)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Divider().padding(.leading, 16)
                field {
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("This device")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                field {
                    TextField(deviceNamePlaceholder, text: $deviceName)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }

            Button {
                pair()
            } label: {
                ZStack {
                    Text("Pair").opacity(pairing ? 0 : 1)
                    if pairing { ProgressView() }
                }
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!canSubmit || pairing)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
    }

    /// Whether both required fields look usable.
    private var canSubmit: Bool {
        !authority.trimmingCharacters(in: .whitespaces).isEmpty
            && !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A blank name is fine — the host falls back to the device model.
    private var resolvedDeviceName: String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "iPhone" : trimmed
    }

    private var deviceNamePlaceholder: String { "iPhone" }

    private func pair() {
        let target = PairingTarget(
            authority: authority.trimmingCharacters(in: .whitespaces),
            code: code.trimmingCharacters(in: .whitespaces),
        )
        pairing = true
        Task {
            await model.pair(with: target, deviceName: resolvedDeviceName)
            pairing = false
            // Whatever the outcome, the root view has already moved on to the
            // screen that owns it -- connecting, the first download, or the
            // failure -- and this window closing is what uncovers it.
            dismiss()
        }
    }
}

/// The pairing screen, in a card that grows for the camera.
///
/// A popover was the obvious window for this -- it comes out of the button that
/// asked for it -- and it cannot do the one thing this screen needs: a popover's
/// size is fixed when it is presented. A `.frame` that changes afterwards
/// re-lays the content out and leaves the card where it opened (measured: the
/// new `preferredContentSize` reaches the presentation controller and the card
/// does not follow), so the camera -- a square as wide as the window -- was
/// always taller than the window showing it, and the screen scrolled.
///
/// A sheet with detents is the platform's own answer to exactly this. The card
/// has two sizes, UIKit animates between them, and that animation is the same
/// smooth one every other sheet in this app uses: the small detent is the size
/// this screen has always been given, the large one is everything at once with
/// the camera in it, and letting go of the camera shrinks it back.
struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The size the card has while it is only a button and a paragraph.
    private static let collapsed = PresentationDetent.height(520)
    /// How long the card takes to grow or shrink.
    private static let growth: TimeInterval = 0.3

    /// Which of the two sizes the card is at.
    @State private var detent: PresentationDetent = PairingSheet.collapsed

    var body: some View {
        NavigationStack {
            PairingView(onScanningChange: { scanning in
                withAnimation(.linear(duration: Self.growth)) {
                    detent = scanning ? .large : Self.collapsed
                }
            })
            .toolbar {
                // A sheet is dismissed by dragging, but a screen that pairs a
                // phone should say how to leave it without a gesture.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("pairing.cancel")
                }
            }
        }
        .presentationDetents([Self.collapsed, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }
}

/// Four rounded corners of a square.
private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.18
        let r: CGFloat = 14
        var p = Path()
        // Top left.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Top right.
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Bottom right.
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // Bottom left.
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

/// A camera view that reports the first pairing URI it recognises.
///
/// VisionKit is picky about being presented without a container, so this wraps it
/// in a `UIViewControllerRepresentable` rather than trying to embed the
/// controller directly.
private struct Scanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: false,
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var reported = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem],
        ) {
            // The camera keeps firing while the code stays in frame; only the
            // first read should start a pairing attempt.
            guard !reported else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue
                else { continue }
                reported = true
                onScan(value)
                return
            }
        }
    }
}
