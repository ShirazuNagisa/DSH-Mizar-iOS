//
//  EnginePickerSheet.swift
//  DSH-Mizar
//
//  The five destinations a computer can open: DSH, CC GUI, CC CLI, Codex GUI,
//  Codex CLI. The wire token is still scoped by engine, so GUI and CLI share a
//  connection; the surface is a phone-side filter over `SessionRow.source`.
//
//  There is deliberately no "All agents" row. A mixed list was useful while the
//  host could only answer for one engine at a time; with two surfaces per coding
//  agent it turns every heading into an ambiguity instead of a choice.
//

import SwiftUI

struct EnginePickerSheet: View {
    let desktopName: String
    /// The destinations worth offering. Empty means "ask for all five".
    var targets: [AgentTarget] = AgentTarget.all
    /// The destination already in use, ticked so a switch is visibly a switch.
    var current: AgentTarget?
    /// Called with the destination the operator chose.
    let onPick: (AgentTarget) -> Void

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
                ForEach(targets.isEmpty ? AgentTarget.all : targets) { target in
                    Button {
                        dismiss()
                        onPick(target)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(target.experimentalTitle)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if target.surface == .cli {
                                        Text(">_")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(target.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if target == current {
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
                    .accessibilityIdentifier("agent.row.\(target.id)")
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
    }
}
