//
//  CommandSkillPaletteView.swift
//  DSH-Mizar
//
//  The command palette: the two commands the phone owns, and every skill the
//  connected computer synced, in one searchable page.
//
//  It replaced two rows in the `+` popover. The popover is a small window about
//  what to put in the message; the palette is a page, opened from that window or
//  from the lone `/` typed in the field, where a machine's whole skill list can
//  be searched without a second trip through the popover.
//
//  The view reads no environment and no `AppModel`: everything it draws is
//  handed in from `SessionDetailView`, so the snapshot suite can pin every
//  support state from a fixture. It is split in two on purpose -- the leaf with
//  no navigation chrome (`CommandSkillPalette`) is what a snapshot renders, and
//  the sheet is the thin `NavigationStack` around it.
//
//  One deliberate shape: the rows are a plain `VStack` inside a `ScrollView`
//  rather than a `List`. Two reasons, both measured in this repo --
//  `ImageRenderer` draws nothing inside a `List` (``HomeModelSnapshotTests``),
//  so a `List` here would make the palette's reference an empty rectangle; and
//  `CommandList` already records that taps on `List` rows with a plain button
//  style were not delivered, while the same rows in a `VStack` were. The
//  snapshot renderer cannot draw a `ScrollView` either, so `scrolls: false`
//  lets the reference draw exactly the same rows without the UIKit container.
//  This is the same stopgap as `MarkdownTableGrid`'s reference. The search
//  field is a UIKit-backed `TextField`, which `ImageRenderer` paints as its
//  yellow "unsupported view" marker, so snapshot mode draws the same capsule
//  with a static placeholder; its live identifier and key are pinned by the
//  snapshot test's source contract.
//

import MizarKit
import SwiftUI
import UIKit

/// The palette's content, without a `NavigationStack` or a sheet around it.
///
/// A leaf view for the same reason as `CommandList`: it takes plain values and
/// closures, owns no environment, and can be rendered from fixtures. The search
/// box is deliberately not focused on appearance: opening the palette to read
/// the list should not raise the keyboard over it.
struct CommandSkillPalette: View {
    /// How skills are available on this connection.
    enum Support: Equatable {
        /// `host.info` advertises `agent.skills.v1`.
        case ready
        /// The computer is older than the skill catalogue, or answered
        /// `NOT_IMPLEMENTED`.
        case unsupported
        /// The on-device agent: it has no agents' skill directories to read.
        case localMode
    }

    let support: Support
    let skills: [AgentSkill]
    /// Called with the literal to put in the field (`/goal`, `/icon-draw`).
    let onPick: (String) -> Void
    /// Whether the page scrolls. Production does; a snapshot passes `false`
    /// because `ImageRenderer` cannot draw a `ScrollView`, and the rows are the
    /// part worth pinning. It also switches the search box's `TextField` to a
    /// static placeholder, for the same renderer limitation.
    var scrolls = true

    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if scrolls {
                TextField("Search commands and skills", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("palette.search")
            } else {
                // The snapshot path. `ImageRenderer` paints a UIKit-backed
                // `TextField` as a yellow "unsupported view" rectangle, so the
                // reference draws the same capsule with the same placeholder as
                // a static text. The live field's identifier and copy are
                // pinned by `CommandSkillPaletteSnapshotTests`' source
                // contract; production never takes this branch.
                Text("Search commands and skills")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !query.isEmpty {
                Button {
                    withMizarAnimation(.mizarSnappy) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.pop)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .liquidCapsule()
        .animation(.mizarSnappy, value: query.isEmpty)
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if scrolls {
            ScrollView {
                listBody
                    .padding(.bottom, 24)
            }
        } else {
            VStack(spacing: 0) {
                listBody
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            if matchesNothing {
                Text("No commands or skills match.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 44)
                    .accessibilityIdentifier("palette.empty")
            } else {
                if !filteredCommands.isEmpty {
                    section("Commands") {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                if index > 0 {
                                    Divider().padding(.leading, 14)
                                }
                                commandRow(command)
                            }
                        }
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                        )
                    }
                }
                skillsSection
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    /// The skills half: rows when there are some, and one sentence when there
    /// are none for a reason the operator can act on.
    @ViewBuilder
    private var skillsSection: some View {
        switch support {
        case .ready:
            if !filteredSkills.isEmpty {
                section("Skills") {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredSkills.enumerated()), id: \.element.id) { index, skill in
                            if index > 0 {
                                Divider().padding(.leading, 14)
                            }
                            skillRow(skill)
                        }
                    }
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    )
                }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // No search is narrowing the list: the catalogue really is
                // empty, which is a different sentence from "nothing matched".
                section("Skills") {
                    statusRow(
                        "No skills have been synced yet.",
                        identifier: "palette.noSkills",
                    )
                }
            }
        case .unsupported:
            section("Skills") {
                statusRow(
                    "This computer's AGI Mizar doesn't sync skills yet. Update the desktop app and they'll appear here.",
                    identifier: "palette.unsupported",
                )
            }
        case .localMode:
            section("Skills") {
                statusRow(
                    "The on-device agent has no skills. Connect a computer to browse them.",
                    identifier: "palette.localMode",
                )
            }
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
        }
    }

    private func commandRow(_ command: ComposerCommand) -> some View {
        Button {
            onPick(command.literal)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                    Text(command.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(command.literal)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98, dims: true))
        .accessibilityIdentifier("palette.command.\(command.name)")
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        Button {
            onPick("/" + skill.name)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98, dims: true))
        .accessibilityIdentifier("palette.skill.\(skill.id)")
    }

    private func statusRow(_ message: LocalizedStringKey, identifier: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            )
            .accessibilityIdentifier(identifier)
    }

    // MARK: - Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive, over both the raw catalogue keys and the strings they
    /// resolve to, so `目标`, `goal` and `Goal` all find `/goal`.
    private var filteredCommands: [ComposerCommand] {
        guard !trimmedQuery.isEmpty else { return ComposerCommand.all }
        return ComposerCommand.all.filter {
            $0.searchText.range(of: trimmedQuery, options: .caseInsensitive) != nil
        }
    }

    private var filteredSkills: [AgentSkill] {
        let sorted = skills.sorted { $0.name < $1.name }
        guard !trimmedQuery.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.range(of: trimmedQuery, options: .caseInsensitive) != nil
                || $0.description.range(of: trimmedQuery, options: .caseInsensitive) != nil
        }
    }

    private var matchesNothing: Bool {
        filteredCommands.isEmpty && filteredSkills.isEmpty
    }
}

/// The palette as a sheet: a navigation bar with a title and Done around the
/// leaf above.
///
/// The `.sheet`, its detents and its drag indicator belong to the caller, so
/// this type stays a plain page that a snapshot could host too.
struct CommandSkillPaletteSheet: View {
    let support: CommandSkillPalette.Support
    let skills: [AgentSkill]
    let onDone: () -> Void
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            CommandSkillPalette(support: support, skills: skills, onPick: onPick)
                .navigationTitle(Text("Commands & Skills"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("palette.done")
                    }
                }
        }
    }
}
