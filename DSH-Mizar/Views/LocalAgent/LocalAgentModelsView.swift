//
//  LocalAgentModelsView.swift
//  DSH-Mizar
//
//  The providers the on-device agent may call, and the way to add another.
//
//  A list rather than a form because there is more than one now: the kernel
//  ships with DeepSeek configured (no key), and an operator can add any
//  OpenAI-compatible deployment beside it. Every row says the two things that
//  decide whether a turn will work -- is there a key, and is this the route.
//

import MizarKit
import SwiftUI

struct LocalAgentModelsView: View {
    /// The kernel this screen configures.
    let agent: LocalAgentController
    /// Called after a write, so the screen behind can refresh what it shows.
    var onChanged: () -> Void = {}

    @State private var store = LocalModelSettingsModel()

    var body: some View {
        List {
            switch store.state {
            case .loading:
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await store.load(agent: agent) }
                    }
                    .tint(Theme.accentText)
                }
            case .ready:
                providersSection
                addSection
            }
        }
        .navigationTitle(Text("Model configuration"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load(agent: agent)
        }
        .onDisappear {
            Task { await store.close() }
        }
    }

    @ViewBuilder
    private var providersSection: some View {
        if store.providers.isEmpty {
            Section {
                Text("No model provider yet. Add one to use the on-device agent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Model providers")
            }
        } else {
            Section {
                ForEach(store.providers) { provider in
                    NavigationLink {
                        LocalProviderFormView(
                            store: store,
                            provider: provider,
                            hasKey: store.hasKey(provider),
                            onChanged: onChanged,
                        )
                    } label: {
                        ProviderRow(
                            provider: provider,
                            hasKey: store.hasKey(provider),
                            isDefault: store.defaultModel?.provider == provider.id,
                        )
                    }
                    .accessibilityIdentifier("localAgent.provider.\(provider.id)")
                }
            } header: {
                Text("Model providers")
            } footer: {
                Text("The key is kept in this phone's keychain. The address has to speak the OpenAI-compatible /chat/completions API.")
            }
        }
    }

    @ViewBuilder
    private var addSection: some View {
        Section {
            NavigationLink {
                LocalProviderFormView(
                    store: store,
                    provider: nil,
                    hasKey: false,
                    onChanged: onChanged,
                )
            } label: {
                Label("Add a model provider", systemImage: "plus")
            }
            .accessibilityIdentifier("localAgent.addProvider")
        }
    }
}

/// One provider: what it is called, where it points, and whether it can call.
private struct ProviderRow: View {
    let provider: KernelProviderConfig
    let hasKey: Bool
    let isDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(provider.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accentText)
                        .accessibilityLabel(Text("Default model"))
                }
            }
            HStack(spacing: 4) {
                LocalPill(
                    text: Text(verbatim: provider.baseUrl),
                    tint: .secondary,
                    fill: AnyShapeStyle(.fill.tertiary),
                )
                if !hasKey {
                    LocalPill(
                        // Short on purpose: this is a capsule in a row that
                        // already carries an address, and the sentence version
                        // belongs in the form where it explains itself.
                        text: Text("No API key"),
                        tint: .red,
                        fill: AnyShapeStyle(Color.red.opacity(0.15)),
                    )
                    .accessibilityIdentifier("localAgent.provider.\(provider.id).nokey")
                }
            }
        }
        .padding(.vertical, 1)
    }
}

/// The capsule this feature uses for secondary facts.
///
/// Takes a `Text` rather than a `String` so the URL can stay verbatim while the
/// messages are localised; the app's other pills are built the same way.
struct LocalPill: View {
    let text: Text
    let tint: Color
    let fill: AnyShapeStyle

    var body: some View {
        text
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(fill, in: Capsule())
    }
}
