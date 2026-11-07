//
//  LiveActivityAttributes.swift
//  MizarKit
//
//  The one type the app and the widget have to agree on.
//
//  ActivityKit routes a Live Activity to a widget by its *attributes type*: the
//  app asks for an activity of `DSHMizarActivityAttributes`, and the widget that
//  declared `ActivityConfiguration(for: DSHMizarActivityAttributes.self)` draws
//  it. The two are separate processes, built from separate targets, and they
//  share nothing except this file -- which is why it lives in MizarKit, the one
//  module both targets link.
//
//  The attributes are almost empty, and that is the design. Static attributes are
//  for what is *constant about one activity and varies between activities*: a
//  match, a flight, a delivery. This app posts one kind of activity for one host,
//  whose title row -- the icon and the literal "DSH-Mizar" -- is the same on
//  every activity it will ever post, so that is drawn by the widget rather than
//  carried. The one thing that does vary per activity is the appearance the
//  operator had when it started: a light card and a dark card are different
//  activities, and the widget cannot read it from its own environment because
//  the Lock Screen asks WidgetKit to draw the card in its vibrant, dark
//  presentation even when the phone is in light mode.
//
//  So the whole of what crosses the process boundary is this small fixed value
//  plus the `ContentState` (`LiveActivityState`): the rows, their clocks, and
//  whether anything is running at all. Every rule about what it means was decided
//  in this module before either process asked -- see ``LiveActivityDecision``.
//
//  The conformance is conditional because `ActivityKit` does not exist on macOS,
//  where this package's test suite runs. The type is plain everywhere; it only
//  becomes an attributes type on a platform that has activities.
//

import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// The appearance the phone was in when the activity was posted.
///
/// Part of the attributes rather than the content state on purpose: pushes from
/// the computer replace the state and know nothing about the phone's appearance,
/// so a value in the state would be reset to a default by every push. Attributes
/// are fixed for the activity's lifetime, which is the right scope for "this card
/// started as a light card".
public enum LiveActivityAppearance: String, Codable, Sendable, Hashable, CaseIterable {
    case light
    case dark
}

/// What one DSH-Mizar Live Activity is about.
///
/// One field, and it is the appearance; see the note at the top of this file. The
/// activity's state -- which is everything else the widget draws -- is
/// ``LiveActivityState``.
///
/// `Codable` here rather than only inside the conditional conformance below,
/// because an attributes type *is* `Codable` -- `ActivityAttributes` refines
/// both -- and because this way the wire shape of the type is pinned by a test
/// that runs on the host, where there is no ActivityKit to conform to.
public struct DSHMizarActivityAttributes: Codable, Sendable, Equatable {
    /// The phone's appearance at the moment the activity was started.
    public var appearance: LiveActivityAppearance

    /// - Parameter appearance: the phone's appearance when the activity starts.
    ///   Defaults to dark, which is the old card's appearance and the value an
    ///   activity encoded before this field existed decodes to.
    public init(appearance: LiveActivityAppearance = .dark) {
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case appearance
    }

    /// Decode, tolerating an activity encoded before `appearance` existed.
    ///
    /// The app and the extension can be updated at different moments; an
    /// activity started by the previous build has only `{}`. Without the default
    /// that card would decode to nothing, which is a Live Activity that draws a
    /// blank screen rather than the dark card it actually was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(LiveActivityAppearance.self, forKey: .appearance) ?? .dark
    }
}

#if os(iOS) && canImport(ActivityKit)
extension DSHMizarActivityAttributes: ActivityAttributes {
    /// The rows and whether anything is counting.
    public typealias ContentState = LiveActivityState
}
#endif
