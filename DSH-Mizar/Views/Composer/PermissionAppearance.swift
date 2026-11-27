//
//  PermissionAppearance.swift
//  DSH-Mizar
//
//  How a permission preset is named and drawn, and the bar's key that opens it.
//
//  The three figures -- the word, the shield and its tint -- used to live on
//  `SessionDetailView` for a toolbar button. They moved here with the button
//  into the composer's own bar, so the picker and the control that opens it
//  read one spelling of a preset rather than two.
//

import SwiftUI
import MizarKit

/// The permission preset, as a word rather than a raw value.
enum PermissionAppearance {
    /// Through the catalogue's own rows when the host has listed this preset,
    /// so the bar and the picker behind it cannot disagree -- and through the
    /// app's own names when the catalogue has not been read yet, which is the
    /// case on the first frame of a session. A preset nobody has a name for
    /// reads as its value, which is what the host called it.
    static func label(for preset: String?, catalog: PermissionCatalog?) -> String {
        guard let preset else { return String(localized: "Permissions") }
        if let option = catalog?.options.first(where: { $0.value == preset }) {
            return option.title
        }
        return PermissionOption.title(for: preset) ?? preset
    }

    /// The shield, shaped by how much the session may do.
    static func symbol(for preset: String?) -> String {
        switch preset {
        case "read-only": "lock.shield"
        case "danger-full-access": "exclamationmark.shield.fill"
        default: "checkmark.shield"
        }
    }

    /// Neutral for read-only, the accent for workspace writes, amber for full
    /// access: the one place a dangerous setting stays visible.
    static func tint(for preset: String?) -> Color {
        switch preset {
        case "workspace-write": .accentColor
        case "danger-full-access": Theme.waiting
        default: .primary
        }
    }
}

/// The permission key, in the composer's bottom row.
struct ComposerPermissionButton: View {
    let sessionId: String
    let stats: SessionStatsFrame?
    @Binding var isPresented: Bool
    var onApplied: () async -> Void = {}

    @Environment(AppModel.self) private var model

    var body: some View {
        let preset = model.permissionPreset(for: sessionId, reported: stats?.permissionPreset)
        Button { isPresented = true } label: {
            Image(systemName: PermissionAppearance.symbol(for: preset))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PermissionAppearance.tint(for: preset))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(.fill.tertiary, in: Circle())
                .contentShape(.circle)
        }
        .buttonStyle(.pressable)
        .mizarPopover(isPresented: $isPresented, arrowEdge: .bottom) {
            PermissionPickerView(sessionId: sessionId, current: preset, onApplied: onApplied)
        }
        .accessibilityLabel(Text(verbatim: "\(String(localized: "Permissions")), \(PermissionAppearance.label(for: preset, catalog: model.permissionCatalog))"))
        .accessibilityIdentifier("composer.permissions")
    }
}
