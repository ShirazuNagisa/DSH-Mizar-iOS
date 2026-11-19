import MizarKit
import SwiftUI

struct OfflineDemoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("demo.open", systemImage: "play.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

struct OfflineDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: OfflineDemoScenario?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var conversations: [OfflineDemoScenario: [OfflineDemoTurn]] = [:]
    @State private var drafts: [OfflineDemoScenario: String] = [:]
    @State private var preview: OfflineDemoScenario?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            List(selection: $selection) {
                Section {
                    ForEach(OfflineDemoScenario.allCases) { scenario in
                        NavigationLink(value: scenario) {
                            Label(scenario.title, systemImage: scenario.symbol)
                                .padding(.vertical, 5)
                        }
                        .accessibilityIdentifier("demo.session.\(scenario.rawValue)")
                    }
                } footer: {
                    Text("demo.description")
                }
            }
            .navigationTitle("demo.title")
            .toolbar {
                if sizeClass == .compact {
                    ToolbarItem(placement: .cancellationAction) { closeButton }
                }
            }
        } detail: {
            Group {
                if let selection {
                    OfflineDemoConversation(
                        scenario: selection,
                        turns: Binding(
                            get: { conversations[selection, default: []] },
                            set: { conversations[selection] = $0 },
                        ),
                        draft: Binding(
                            get: { drafts[selection, default: ""] },
                            set: { drafts[selection] = $0 },
                        ),
                        openFile: { preview = selection },
                    )
                    .id(selection)
                    .navigationTitle(selection.title)
                } else {
                    ContentUnavailableView("demo.select", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { closeButton }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $preview) { scenario in
            OfflineDemoFilePreview(scenario: scenario)
        }
    }

    private var closeButton: some View {
        Button("Close") { dismiss() }
            .accessibilityIdentifier("demo.close")
    }
}

private struct OfflineDemoConversation: View {
    let scenario: OfflineDemoScenario
    @Binding var turns: [OfflineDemoTurn]
    @Binding var draft: String
    let openFile: () -> Void

    @FocusState private var composerFocused: Bool

    private var awaitingResponse: Bool {
        guard let turn = turns.last else { return false }
        if case .finished = turn.stage { return false }
        return true
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarkdownMessage(scenario.opening)
                    if turns.isEmpty {
                        Button {
                            send(scenario.samplePrompt)
                        } label: {
                            Label(scenario.samplePrompt, systemImage: "arrow.up.circle")
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("demo.tryPrompt")
                    }

                    ForEach(turns) { turn in
                        turnContent(turn)
                    }

                    Color.clear.frame(height: 1).id("demo.bottom")
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: 640)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: turns) {
                proxy.scrollTo("demo.bottom", anchor: .bottom)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Label("demo.title", systemImage: "play.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .accessibilityIdentifier("demo.banner")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("demo.composer", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .accessibilityIdentifier("demo.composer")

            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(awaitingResponse || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("demo.send")
        }
        .disabled(awaitingResponse)
    }

    private func turnContent(_ turn: OfflineDemoTurn) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sentBubble(turn.prompt)

            switch turn.stage {
            case .question:
                OfflineDemoQuestion(scenario: scenario) { answer in
                    advance(turn, to: .approval(answer: answer))
                }
                .id(turn.id)
            case .approval(let answer):
                sentBubble(answer.title)
                ApprovalCard(
                    id: turn.id.uuidString,
                    title: "demo.approval.title",
                    reason: String(localized: "demo.approval.reason \(scenario.fileName)"),
                ) { outcome in
                    advance(turn, to: .finished(answer: answer, outcome: outcome))
                }
                .padding(14)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            case .finished(let answer, let outcome):
                sentBubble(answer.title)
                MarkdownMessage(answer.reply(outcome: outcome))
                    .accessibilityIdentifier(outcome == .allowedOnce ? "demo.allowed" : "demo.rejected")
                if outcome == .allowedOnce {
                    Button(action: openFile) {
                        HStack(spacing: 10) {
                            DeliveredFileIcon(kind: .markdown, size: 34)
                            Text(scenario.fileName)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint(Text("Opens the preview"))
                    .accessibilityIdentifier("demo.file")
                }
            }
        }
    }

    private func sentBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            SentBubbleBody(text: text)
        }
    }

    private func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !awaitingResponse else { return }
        composerFocused = false
        draft = ""
        turns.append(OfflineDemoTurn(prompt: prompt))
    }

    private func advance(_ turn: OfflineDemoTurn, to nextStage: OfflineDemoTurn.Stage) {
        guard let index = turns.indices.last, turns[index] == turn else { return }
        turns[index].stage = nextStage
    }
}

private struct OfflineDemoQuestion: View {
    let scenario: OfflineDemoScenario
    let submit: (OfflineDemoOption) -> Void
    @State private var answer: OfflineDemoOption?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("demo.question.title")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.question)
            Text(scenario.question)
                .font(.headline)
                .accessibilityIdentifier("demo.question")
            ForEach(Array(scenario.options.enumerated()), id: \.offset) { index, option in
                Button {
                    answer = option
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: answer == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Theme.question)
                            .accessibilityHidden(true)
                        Text(option.title)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(answer == option ? .isSelected : [])
                .accessibilityIdentifier("demo.question.option.\(index)")
            }
            Button {
                if let answer { submit(answer) }
            } label: {
                Text("Send answers")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(answer == nil)
            .accessibilityIdentifier("demo.question.submit")
        }
        .padding(14)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }
}

private struct OfflineDemoFilePreview: View {
    @Environment(\.dismiss) private var dismiss
    let scenario: OfflineDemoScenario

    var body: some View {
        NavigationStack {
            Group {
                if let url = scenario.fileURL {
                    MarkdownPreview(url: url)
                } else {
                    ContentUnavailableView("demo.file.missing", systemImage: "doc")
                }
            }
            .navigationTitle(scenario.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("demo.file.done")
                }
            }
        }
    }
}
