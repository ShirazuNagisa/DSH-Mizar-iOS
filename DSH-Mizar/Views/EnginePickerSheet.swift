//
//  EnginePickerSheet.swift
//  DSH-Mizar
//
//  The three agents a computer can serve, as a short sheet from the bottom.
//
//  One computer runs three agents and they share nothing: their sessions, their
//  working directories and their tool surfaces are separate. Connecting is
//  therefore not "connect to the Mac" but "connect to one agent on the Mac", and
//  the question is asked the moment the computer is tapped -- not afterwards,
//  from a picker that would then have to reload everything.
//

import SwiftUI

struct EnginePickerSheet: View {
    let desktopName: String
    /// The agents worth offering. Empty means "ask the standard three", which is
    /// what a computer that has never been connected to can say.
    var engines: [AgentEngine] = AgentEngine.allCases
    /// The agent already in use, ticked so a switch is visibly a switch.
    var current: AgentEngine?
    /// Whether "all agents" is one of the answers.
    ///
    /// False for the first connection -- there is no reason to open a three-agent
    /// computer and ask for all three at once -- and true when switching a
    /// computer that may have been opened that way before this choice existed.
    var allowsAll = false
    /// Called with the agent the operator chose, or `nil` for all of them.
    let onPick: (AgentEngine?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("Connect to which agent")
                    .font(.headline)
                Text(desktopName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 6) {
                // An empty list is not an answer this sheet can draw: it is what
                // a caller passes when it has nothing to choose between, so it
                // falls back to the three this app knows instead of showing a
                // sheet with no rows.
                ForEach(engines.isEmpty ? AgentEngine.allCases : engines) { engine in
                    Button {
                        dismiss()
                        onPick(engine)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(engine.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(engine.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if engine == current {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .accessibilityIdentifier("engine.row.\(engine.rawValue)")
                }

                if allowsAll {
                    Button {
                        dismiss()
                        onPick(nil)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("All agents")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("Every session on this computer, mixed together")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if current == nil {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .accessibilityIdentifier("engine.row.all")
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(allowsAll ? 356 : 300)])
        .presentationDragIndicator(.visible)
    }
}
