//
//  CommandPaletteHint.swift
//  DSH-Mizar
//
//  The door to the palette while typing.
//
//  It is deliberately the same shape as the confirmation capsule the approval
//  dock shows after an answer -- a `liquidCapsule`, 38 points tall, directly
//  above the field -- because it is the same kind of thing: one sentence, one
//  tap, and it goes away by itself. The difference is that this one is a
//  control, so it takes a touch, and it lives until the lone `/` that summoned
//  it stops being a lone slash.
//

import SwiftUI

/// The "open the command palette" capsule, shown while a lone `/` is typed.
struct CommandPaletteHint: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.accentText)
                Text("Open commands and skills")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(.capsule)
            .liquidCapsule(interactive: true)
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityIdentifier("composer.paletteHint")
        .accessibilityLabel(Text("Open commands and skills"))
    }
}
