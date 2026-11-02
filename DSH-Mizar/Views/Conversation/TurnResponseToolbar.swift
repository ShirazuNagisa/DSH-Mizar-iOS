import SwiftUI
import UIKit
import MizarKit

/// Actions belong to the durable closing response, not the typewriter's visible prefix.
struct TurnResponseToolbar: View {
    let turn: ConversationTurn
    let sessionId: String
    let text: String
    let at: Date

    @Environment(AppModel.self) private var model
    @State private var copied = false
    @State private var branching = false
    @State private var failure: String?

    private var prefix: String { "turn.\(turn.id)" }
    private var unavailableReason: String? {
        guard turn.endSeq != nil, turn.branchUnavailable != nil else {
            return String(localized: "Complete turn metadata is unavailable. Refresh or update the computer plugin.")
        }
        if turn.branchUnavailable == true {
            return String(localized: "This response is followed by tool activity or an error and cannot be branched here.")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(copied ? Text("Response copied") : Text("Copy response"))
                .accessibilityIdentifier("\(prefix).copy")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    copied = false
                }

                // Forking is a host feature the kernel does not implement: it
                // has the records but not the machinery to branch a session at a
                // turn. Hidden rather than disabled, like the attachments.
                if !model.isLocalAgentMode {
                    Button {
                        guard !branching, let seq = turn.endSeq, unavailableReason == nil else { return }
                        branching = true
                        failure = nil
                        Task { @MainActor in
                            defer { branching = false }
                            do {
                                try await model.forkSession(sessionId: sessionId, atSeq: seq)
                            } catch let error as MizarError {
                                failure = AppModel.displayMessage(for: error)
                            } catch {
                                failure = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .opacity(branching ? 0.4 : 1)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(branching || unavailableReason != nil)
                    .accessibilityLabel(Text("Branch in a new conversation"))
                    .accessibilityHint(Text(unavailableReason ?? (branching ? String(localized: "Branching…") : "")))
                    .help(unavailableReason ?? String(localized: "Branch in a new conversation"))
                    .accessibilityIdentifier("\(prefix).branch")

                }
                // Metadata may wrap on a narrow phone or at accessibility sizes;
                // the action hit targets never shrink and the reading order stays fixed.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { usage; clock }
                    VStack(alignment: .leading, spacing: 2) { usage; clock }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(prefix).toolbar")

            if let failure {
                Text(failure.isEmpty ? String(localized: "The conversation was not branched. Try again.") : failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(prefix).branch.error")
            }
        }
    }

    private var usage: some View {
        Group {
            if let count = turn.tokenUsage?.totalTokens {
                Text("\(count.formatted(.number.grouping(.never))) tokens")
            } else {
                Text("Token usage unavailable")
            }
        }
        .accessibilityIdentifier("\(prefix).usage")
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if at.timeIntervalSince1970.isFinite, at.timeIntervalSince1970 > 0 {
                Text(TurnResponseClock.text(at: at, now: context.date))
            } else {
                Text("Time unavailable")
            }
        }
        .accessibilityIdentifier("\(prefix).time")
    }
}
