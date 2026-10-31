//
//  DSHMizarLiveActivityWidget.swift
//  DSH-Mizar-LiveActivity
//
//  The island and the lock screen: what the phone shows while the computer works.
//
//  Two processes are involved and this is the second one. The app decides what
//  the activity *is* -- which sessions are running, what to call them, when the
//  whole thing should come down -- and hands the answer over as a value
//  (`LiveActivityState`, in MizarKit). This file draws that value and decides
//  nothing: which of the two phases it is *is* the difference between a clock and
//  a green check.
//
//  Two things about Live Activities are not obvious and shaped everything here:
//
//    - **The clock is the system's.** `Text(_:style:.timer)` counts up from an
//      instant, redrawn by the system on its own schedule -- no `Activity.update`
//      per second, no push, no waking the app. That is why a row carries
//      `countingSince` rather than a figure, and why an activity that goes
//      minutes without an update still tells the time correctly.
//
//    - **The island tints what it draws.** There is no colour to pick inside the
//      Dynamic Island: the system draws the compact and minimal presentations in
//      its own tint on its own black background, and the lock-screen card is
//      drawn in the vibrant mode widgets use. An app-icon bitmap dropped in
//      here would therefore come out as whatever the system does to a bitmap --
//      and, less obviously, *the app's own asset catalog is not visible from
//      this process at all*: the extension has its own bundle, so `Image` here
//      can only find assets in `DSH-Mizar-LiveActivity/Assets.xcassets`. The mark
//      is a template image in that catalog (`MizarIcon`, white on transparent,
//      `template-rendering-intent`), derived from the app icon's glyph with the
//      icon's navy background dropped -- see the note on `Mark`.
//
//  Nothing here reads a model, a cache or a network: a Live Activity runs in its
//  own sandbox with no network access, and everything it may draw arrived in the
//  content state.
//

import ActivityKit
import MizarKit
import SwiftUI
import WidgetKit

// MARK: - Why every string here is resolved before SwiftUI sees it

/// A string out of this extension's `Localizable.strings`, translated by hand
/// rather than by `Text("…")`.
///
/// **`Text("…")` — the `LocalizedStringKey` initialiser — cannot be used
/// anywhere in this widget.** Not for a label, not for content. It is the one
/// API in this file that crashes the extension, and it does it in this process
/// rather than in the app's, so what the operator sees is the app's Live
/// Activity failing to draw and what XCTest reports is a failure of whichever
/// test happened to be running:
///
///     <unknown>:0: error: -[DSH_MizarUITests.AppFlowTests test…] :
///         Critical process DSH-Mizar-LiveActivity crashed in (null)
///
/// The mechanism, from the crash report's own `lastExceptionBacktrace`:
/// a `LocalizedStringKey` text is marked with SwiftUI's
/// `ResolvableTextSegmentAttribute` — the process-local note that says "this run
/// of characters is a localisable segment, re-resolve it if the language
/// changes". A Live Activity is not drawn where it is built: WidgetKit
/// *archives* the rendered tree to protobuf and hands the bytes across the
/// process boundary, and `CodableAttributedString.encode(to:)` strips that
/// attribute first, because a segment resolved in this process means nothing in
/// the host. Stripping it goes through `removeAttribute(_:range:)` with a range
/// that was only ever valid for the string that carried it, and that call
/// **throws** (`NSRangeException`):
///
///     CodableAttributedString.encode(to:)
///       −[NSAttributedString enumerateAttribute:inRange:options:usingBlock:]
///         ResolvableTextSegmentAttribute.Value.toggleAttributes(in:of:)
///           ResolvableTextSegmentAttribute.Value.restoreDefault(in:of:)
///             −[NSMutableAttributedString removeAttribute:range:]   ← throws
///
/// The exception is rethrown out of `enumerateAttribute`, reaches
/// `_objc_terminate`, and aborts the extension with SIGABRT.
///
/// `Text(verbatim:)` carries no such attribute, so there is nothing to strip and
/// nothing to throw. That is not a way of giving up the translation: it means
/// the lookup has already happened, here, through `Bundle.main` — which in an
/// app extension is *this* extension's bundle, the one holding `en.lproj` and
/// `zh-Hans.lproj`. The keys are the same ones `Text("…")` would have looked up,
/// so the words on the island, on the Lock Screen and in VoiceOver are the ones
/// `Localizable.strings` holds, unchanged. What is gone is only the promise that
/// SwiftUI could re-resolve them later in a different process — a promise this
/// widget can never keep and must not make.
///
/// ## `verbatim` alone was not enough: the clock is the second source
///
/// A `LocalizedStringKey` is not the only text SwiftUI resolves *while drawing*.
/// `Text(_:style:)` holds no string at all — it is a date and a style, and the
/// words are produced when it is drawn, which is exactly what lets the system
/// tick it without the app sending anything. `Text`'s storage for it is
/// `TimeDataFormattingStorage`, not `verbatim`, so the string it resolves to
/// carries the same process-local segment. Drawn as itself that is what a Live
/// Activity clock is *for*; it becomes the crash above the moment that string is
/// merged into another string, which is what accessibility does.
///
/// So this file keeps two rules, and they are both about the same archive:
///
///  1. **Every string is resolved here**, through `Text.translated` or
///     `Text(verbatim:)`, before SwiftUI sees it. A key is looked up with
///     `NSLocalizedString` and never handed to `Text("…")`; a sentence is
///     assembled out of those strings *here*, with no format specifier left in
///     it for SwiftUI to find.
///  2. **Nothing SwiftUI resolves while drawing is handed to accessibility.**
///     No accessibility-element merge anywhere — not the `children:` `.combine`
///     mode, not any other: an element's
///     words are put together in this process and attached with
///     `children: .ignore`. The clock is drawn with `accessibilityHidden(true)`
///     (see `Clock`) and described in words by whoever draws it. The mark's
///     asset is found by a `String` name rather than by a
///     `LocalizedStringKey`, and its label is `verbatim`, so the one label it
///     has is one this process wrote.
///
/// `grep -n 'Text(' DSHMizarLiveActivityWidget.swift` should therefore show
/// `Text(verbatim:)`, `Text.translated(…)` and the one date-styled `Text` inside
/// `Clock` — which is hidden from accessibility and never used as a label.
private extension Text {
    /// - Parameter key: a key in this extension's `Localizable.strings`.
    /// - Returns: the same text, already in the operator's language, and free of
    ///   the localisable segment attribute that cannot cross the process
    ///   boundary.
    static func translated(_ key: String) -> Text {
        Text(verbatim: String.translated(key))
    }
}

private extension String {
    /// The words behind a key in this extension's `Localizable.strings`.
    ///
    /// Here as well as on `Text` because one label in this file is a *sentence*
    /// rather than a single string -- `LiveActivityRow.spokenLabel` -- and a
    /// sentence has to be assembled before SwiftUI sees it.
    ///
    /// - Parameter key: a key in this extension's `Localizable.strings`.
    /// - Returns: the translation, or the key itself when there is none.
    static func translated(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}

/// One row as VoiceOver reads it.
private extension LiveActivityRow {
    /// What the row says, then what the number beside it is.
    ///
    /// The row is one element and this is its whole label, so the two parts are
    /// joined here rather than by the `.combine` mode of
    /// `accessibilityElement(children:)` --
    /// see the note on `SessionRows`. The row's left side is the session's title
    /// when the host has named it and the operator's instruction otherwise; that
    /// is `displayTitle`, so a listener hears the same name a reader sees. A row
    /// with neither contributes nothing, and the label is then just the noun: a
    /// duration announced with no noun is a number about nothing, which is what
    /// `Localizable.strings` says about this key.
    var spokenLabel: Text {
        Text(verbatim: [displayTitle, String.translated("Running time")]
            .filter { !$0.isEmpty }
            .joined(separator: ", "))
    }
}

/// The one Live Activity this app posts.
struct DSHMizarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DSHMizarActivityAttributes.self) { context in
            // The Lock Screen presentation, and the banner on a device without
            // an island. The same card the expanded island draws, because there
            // is nothing about it that depends on where it is drawn.
            LiveActivityCard(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // The title row: the mark and the app's name, on the leading
                // side of the camera. `belowIfTooWide` is not decoration --
                // "DSH-Mizar" beside a glyph is wider than the space left of
                // the TrueDepth camera on a compact island, and without it the
                // label is truncated to something nobody can read.
                DynamicIslandExpandedRegion(.leading) {
                    TitleRow()
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Headline(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        // A blocked turn comes before the clocks: the operator
                        // can answer it from here, and a question under two
                        // counting rows is a question nobody sees.
                        if !context.state.approvals.isEmpty {
                            ApprovalRows(approvals: context.state.approvals)
                        }
                        SessionRows(state: context.state)
                    }
                }
            // The compact presentation is content, and only content -- but the
            // content has to say how wide it is, and a date-styled `Text` will
            // not: in WidgetKit a timer fills whatever width it is offered
            // instead of taking the width of the number it draws. On iOS 27 the
            // compact views are flexible in width in portrait (see the note
            // below), so what the trailing view is offered can be the whole
            // trailing edge of a wide capsule; with no finite width of its own
            // the number had no frame to be drawn in and the right side stayed
            // black. `Clock` bounds itself with a hidden placeholder of the
            // widest count it can draw (0:00:00), so the slot has a width and the
            // digits sit at the capsule's trailing edge. Nothing here adds
            // padding, spacing, or a `fixedSize` that would ask for width the
            // content does not need.
            //
            // The capsule itself is the system's: in iOS 27 the compact views are
            // flexible in width in portrait and constrained in landscape
            // (`isDynamicIslandLimitedInWidth`). There is no environment value or
            // API with which an app narrows the portrait capsule; the most this
            // builder can do is make both of its sides exactly as wide as what
            // they draw, which is what the mark's 14-point frame and the clock's
            // placeholder do.
            } compactLeading: {
                // Left: the mark, at the smallest size that still reads as the
                // app. The image's own frame is the whole of its size; a
                // `fixedSize` beside it would be a second opinion about a frame
                // that is already exact.
                Mark(diameter: 14)
            } compactTrailing: {
                // Right: the clock and nothing else. The clock carries its own
                // bound (see `Clock`), and `.lineLimit(1)` inside it keeps the
                // number on one line; a `fixedSize` here cannot bound a timer
                // text and only repeats what the view already says.
                Headline(state: context.state, font: .caption2.monospacedDigit())
            } minimal: {
                // One slot, no left and right: the mark only. The check the old
                // build drew here made a finished activity wider than a mark for
                // no information a one-glyph slot can carry.
                Mark(diameter: 14)
            }
        }
    }
}

// MARK: - The pieces both presentations draw

/// The app's mark.
///
/// `MizarIcon` in this extension's asset catalog is a **template** image: white
/// on transparent, with `template-rendering-intent` set, so the system tints it
/// for wherever it is drawn instead of pasting a bitmap of an app icon onto the
/// island's black background. It is derived from `AppIcon-1024.png` -- the
/// glyph's pixels kept, white; the icon's navy background dropped to alpha; the
/// glyph's own bounding box cropped square so the mark fills the frame rather
/// than sitting inside a square of nothing.
///
/// It is also **small** on purpose. Apple's rule for a Live Activity asset is
/// that its resolution must not exceed the presentation it is drawn in, and a
/// 1024-pixel app icon is larger than every one of them -- at which point the
/// system may refuse to start the activity at all. The imageset is 32/64/96
/// pixels, so nothing here can trip that.
///
/// The name is a `String`, not a `LocalizedStringKey`: `Image("…")` has both
/// initialisers and a literal picks the `String` one, which is what this is --
/// verified with `-dump-ast`, not assumed. SwiftUI still labels an image found
/// by name with that name, resolved the localisable way, which is the other
/// reason the label below is `verbatim` and the reason nothing merges this
/// element into anything (see the note at the top of this file).
private struct Mark: View {
    var diameter: CGFloat

    var body: some View {
        Image("MizarIcon")
            .resizable()
            .scaledToFit()
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(Text(verbatim: "DSH-Mizar"))
    }
}

/// The icon and the app's name, which is what the activity is about.
///
/// The name is `verbatim`: it is the app's name on the App Store and on the
/// computer, not a phrase to be translated. An activity that reads 米扎尔 in one
/// language and DSH-Mizar in another would be a different app's card.
///
/// One element with one set of words, assembled here rather than by the
/// `.combine` merge of a single accessibility element: see the note at the top
/// of the file. The mark inside is decorative and says nothing; the words beside
/// it say everything this row has to say.
private struct TitleRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Mark(diameter: 16)
            Text(verbatim: "DSH-Mizar")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "DSH-Mizar"))
    }
}

/// The system's ticking clock: drawn, and never handed to accessibility.
///
/// This is the one text in this file that SwiftUI resolves while drawing, so it
/// is the one text that must not reach an accessibility node — its own or an
/// element's, because a segment merged into a label is what throws when
/// WidgetKit strips the attribute (see the note at the top of the file).
/// `accessibilityHidden(true)` is why the clock is a view of its own instead of
/// two lines inside `Headline`: it keeps the string the clock resolves to out of
/// the accessibility tree, and whoever draws the clock says in words what it is
/// (`Headline`, `SessionRows`), out of strings that are already plain.
///
/// ## Why the number is drawn over a hidden one
///
/// In WidgetKit a date-styled `Text` **fills the width it is offered** instead of
/// taking the width of the string it draws. That is deliberate on the system's
/// part — it lets the host swap the number without asking this process to lay
/// out again — and it means a timer has no intrinsic width to lay out against.
/// In the island's trailing slot there is nothing else to give that slot a size,
/// so it is left with no width of its own and the number is not drawn: on a
/// real device that is a wide black capsule with the mark on the left and
/// nothing at all on the right. A `fixedSize` does not help, because the width
/// the timer wants is the one it is offered rather than one it computes.
///
/// So the bound is made out of a text that cannot stretch: the hidden
/// `Text(verbatim:)` below is the widest count a Live Activity can draw
/// (`0:00:00`, seven monospaced digits — a Live Activity ends after eight hours),
/// and the ticking clock is an overlay on it, so the slot has a real width and
/// the host draws the number into it, right-aligned. The host draws "0:00" in
/// that width with room to its left and "7:59:59" filling it; nothing is
/// truncated, and the number is where the trailing side of the capsule is.
private struct Clock: View {
    /// The instant the count starts at.
    let since: Date
    /// The size it is drawn at. The compact island asks for the smallest one;
    /// the card asks for a body-sized figure.
    var font: Font = .caption.monospacedDigit()

    /// The widest string this clock can draw, in the same font and therefore at
    /// the same width.
    ///
    /// Seven characters is the format the system uses past the first hour
    /// ("1:23:45"); the eight-hour limit on a Live Activity means it can never
    /// need more. "0:00:00" has the same character count as "7:59:59", so the
    /// placeholder is the true maximum rather than an estimate.
    private static let widest = "0:00:00"

    var body: some View {
        Text(verbatim: Self.widest)
            .font(font)
            .lineLimit(1)
            // The placeholder exists for its width, not for its words.
            .hidden()
            .overlay(alignment: .trailing) {
                Text(since, style: .timer)
                    // Monospaced digits so the text does not jitter sideways as
                    // the numbers change.
                    .font(font)
                    .lineLimit(1)
            }
            // The string SwiftUI resolves for this clock never enters the
            // accessibility tree. Whoever draws it says in words what it is.
            .accessibilityHidden(true)
    }
}

/// The island's right side: a counting clock, or the check that says nothing is.
///
/// One row's worth of information, deliberately. On the compact island it is a
/// duration and nothing else; the card asks for the same view at a larger size.
private struct Headline: View {
    let state: LiveActivityState
    var font: Font = .caption.monospacedDigit()

    var body: some View {
        if let longest = state.rows.first {
            // The system ticks this. No update from the app, ever, for the
            // seconds to move.
            Clock(since: longest.countingSince, font: font)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text.translated("Running time"))
        } else {
            FinishedCheck()
        }
    }
}

/// The green check every finished presentation ends with.
private struct FinishedCheck: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityLabel(Text.translated("Every session has finished"))
    }
}

/// The rows the decision layer produced: one or two, longest-running first.
///
/// Each row's left side is the session's title, falling back to the beginning
/// of that session's most recent instruction when the host has not named it;
/// its right side is the time it has been going. The cutting of the fallback is
/// not done here -- `LiveActivityDecision` decides how much of an instruction
/// survives, and this file would be a second opinion about it if it cut again.
///
/// The card asks for the prominent size: a body-sized title, a body-sized clock,
/// a 44-point row and a grid, so the two rows line up and the time column is
/// right-aligned whether the session has been running for nine seconds or nine
/// hours. The expanded island keeps the compact type: its height is its own cap
/// and the operator asked for the card to grow, not the island.
private struct SessionRows: View {
    let state: LiveActivityState
    /// Whether to draw the larger card typography.
    var prominent = false

    private var titleFont: Font { prominent ? .body.weight(.medium) : .caption }
    private var clockFont: Font {
        prominent ? .body.monospacedDigit().weight(.semibold) : .caption.monospacedDigit()
    }
    private var rowHeight: CGFloat? { prominent ? 44 : nil }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(state.rows) { row in
                GridRow(alignment: .center) {
                    // A row with no title and no instruction is a session the
                    // app has not read yet. It says only how long, which is
                    // true; the session id in the operator's place would be the
                    // app talking.
                    Text(verbatim: row.displayTitle)
                        .font(titleFont)
                        .lineLimit(1)
                        // The first column takes the width the card leaves and
                        // the second keeps its natural width, so the numbers
                        // form one right-aligned column rather than drifting
                        // with the title beside them.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridCellAnchor(.leading)
                    Clock(since: row.countingSince, font: clockFont)
                        .foregroundStyle(.white.opacity(0.72))
                        .gridCellAnchor(.trailing)
                }
                .frame(minHeight: rowHeight)
                // One element for VoiceOver, but its words are put together here
                // rather than by SwiftUI. `.combine` is the other way to get one
                // element, and it is the one thing in this file that must not be
                // used: it builds the element's label by merging the children's
                // accessibility text, and the second child above is a `Clock` --
                // a `Text(_:style:.timer)`, a *resolvable* segment, the same kind
                // of attribute as the localisable one the note at the top of this
                // file is about. The merged label then carries a segment range
                // measured against the timer's own string, WidgetKit's archiver
                // strips that attribute with `removeAttribute(_:range:)`, and
                // Foundation throws `NSRangeException` -- out of
                // `enumerateAttribute:inRange:options:usingBlock:`, past every
                // catch, and into SIGABRT. A label assembled out of plain strings
                // has no segment to strip.
                //
                // `.ignore` is what makes the label the whole element: the two
                // `Text`s above stay exactly as they are on screen, and VoiceOver
                // reads the one sentence below instead of their fragments. The
                // clock is hidden from accessibility inside `Clock` as well, so
                // there is no version of this element -- combined, ignored or
                // read on its own -- that can carry the timer's string.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spokenLabel)
            }
        }
    }
}

/// The approval block: what is blocked, and the two answers.
///
/// The only interactive thing this extension draws. Two rules shape it:
///
///   - **The buttons are intents, not taps into the app.**
///     `Button(intent: AllowOnceIntent(...))` runs in the app's process, which the
///     system wakes for exactly this, so the operator answers from the Lock
///     Screen without the app coming up.
///   - **Every string is resolved here.** `Text.translated` and
///     `Text(verbatim:)` only -- see the note at the top of this file about the
///     localisable segment attribute that cannot cross into the host process.
private struct ApprovalRows: View {
    let approvals: [LiveActivityApproval]
    /// Whether to draw the larger card typography.
    var prominent = false

    private var titleFont: Font {
        prominent ? .subheadline.weight(.semibold) : .caption.weight(.semibold)
    }
    private var detailFont: Font { prominent ? .footnote : .caption2 }
    private var buttonFont: Font {
        prominent ? .footnote.weight(.semibold) : .caption2.weight(.semibold)
    }

    var body: some View {
        ForEach(approvals) { approval in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    // The tool's name, from the computer. `verbatim`: it is an
                    // identifier the operator already knows, not a phrase.
                    Text(verbatim: approval.headline)
                        .font(titleFont)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if !approval.detail.isEmpty {
                    Text(verbatim: approval.detail)
                        .font(detailFont)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button(intent: AllowOnceIntent(requestId: approval.requestId)) {
                        Text.translated("Allow once")
                            .font(buttonFont)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(intent: RejectIntent(requestId: approval.requestId)) {
                        Text.translated("Reject")
                            .font(buttonFont)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// The card's heading: the mark and the app's name, at reading size.
///
/// Larger than the island's title row on purpose. The card is the thing that
/// has to read as a card on a lock screen full of notifications, and a caption
/// above body-sized rows reads as a footnote to them.
private struct CardTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            Mark(diameter: 22)
            Text(verbatim: "DSH-Mizar")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "DSH-Mizar"))
    }
}

/// The whole card: the title row, then the rows.
///
/// The height is content, not a frame: a 24-point title, two 44-point rows and
/// 6 points of padding above and below come to about 136 points before
/// WidgetKit's own margins. That is as tall as the Lock Screen's activity cap
/// leaves room for -- the system's limit is around 160 points, so the two
/// notification banners this is asked to match cannot both fit whole. The rows
/// are the part that must not be squeezed, and they are the part that grows.
private struct LiveActivityCard: View {
    let state: LiveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle()
            // A blocked turn first, for the same reason as on the island: this is
            // the row the operator can act on.
            if !state.approvals.isEmpty {
                ApprovalRows(approvals: state.approvals, prominent: true)
            }
            if state.rows.isEmpty && state.approvals.isEmpty {
                // Nothing is running. The decision layer has no rows to give and
                // the card says so in words rather than by being blank, because
                // an activity is only ever *started* running: no rows here
                // means work that has just stopped, not an empty start.
                HStack(spacing: 6) {
                    FinishedCheck()
                    Text.translated("Every session has finished")
                        .font(.body)
                    Spacer(minLength: 0)
                }
            } else {
                SessionRows(state: state, prominent: true)
            }
        }
        // The system leaves only a few points between a Live Activity's content
        // and its rounded edge, so a leading-aligned card ends up with its title
        // against the glass -- a real device screenshot showed exactly that. This
        // is the inset that makes it read as a card rather than as text that
        // overflowed it; 10 vertical against 16 horizontal keeps the optical
        // balance at these type sizes.
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        // The icon's own navy, so the card belongs to the app whose glyph is on
        // it. Set here rather than left to the system because the card's content
        // is drawn in one colour in every mode, and a tint that changed with the
        // wallpaper would leave white text on a pale card.
        .activityBackgroundTint(Color(red: 19 / 255, green: 31 / 255, blue: 61 / 255))
        .activitySystemActionForegroundColor(.white)
    }
}
