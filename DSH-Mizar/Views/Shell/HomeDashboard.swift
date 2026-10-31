//
//  HomeDashboard.swift
//  DSH-Mizar
//
//  The home page's record of the last month, and the way back into the last
//  conversation.
//
//  The desktop's home page answers "what have I been doing" with a year of
//  squares. On a phone that is the wrong shape twice over: a year does not fit
//  the width, and a year of history is not what somebody opening the app at a
//  bus stop is asking. Thirty days fit, at a size a thumb can read, and thirty
//  days is long enough to see a rhythm -- a deadline week, a quiet Sunday.
//
//  The chart is drawn from the host's own usage rows (`usage.overview`), folded
//  across every agent it serves. A day with no row is a day with no work: the
//  host only reports days that had any, so absence is the zero.
//

import SwiftUI
import MizarKit

/// A year of work, as one column per week.
struct UsageHeatmap: View {
    /// The host's rows, oldest first.
    let days: [UsageDay]
    /// How many days the chart shows, ending today.
    var span = 371
    /// Whether the read is on the socket.
    var loading = false

    /// The calendar the columns are laid out in. Local, because the days the
    /// host reports are its own local days.
    private var calendar: Calendar { .current }

    /// The days to draw, oldest first, with `nil` for one that had no work.
    ///
    /// The window starts on the week boundary before it, so every column is a
    /// whole week and the rows line up with the days they mean. The first
    /// column is usually short -- the year did not start on that weekday -- and
    /// the chart pads it rather than shifting every other column by a day.
    private var cells: [(date: String, day: UsageDay?)] {
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -(span - 1), to: today) ?? today
        // Back to the first weekday of the calendar (Sunday in the US, Monday
        // elsewhere), which is what makes a column a week.
        let weekday = calendar.component(.weekday, from: start)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -lead, to: start) ?? start
        let count = calendar.dateComponents([.day], from: first, to: today).day ?? span
        return (0...count).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: first) ?? first
            let label = formatter.string(from: date)
            return (label, byDate[label])
        }
    }

    /// The busiest day in the window, which is what the colours scale against.
    private var peak: Int {
        max(1, cells.compactMap { $0.day?.tokens }.max() ?? 0)
    }

    /// Seven rows, as many columns as the span needs.
    private var columns: [[(date: String, day: UsageDay?)]] {
        stride(from: 0, to: cells.count, by: 7).map { start in
            Array(cells[start..<min(start + 7, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // The grid takes whatever room the card was given, and the squares
            // grow into it. They used to be a fixed eleven points, which made
            // "two thirds of the page" a card two thirds of the page tall with
            // a stamp-sized month inside it -- the figure the page exists for,
            // drawn as a footnote.
            // A fixed strip: seven rows of the squares the width allows, so
            // the card is as tall as a year of weeks needs and no taller.
            GeometryReader { proxy in
                // A year across the card: as many columns as the year has
                // weeks, each as wide as the row allows. The squares are small
                // because there are fifty-three of them, which is the point --
                // the year reads as one bar, the way the desktop draws it.
                let gap: CGFloat = 2
                let across = CGFloat(max(1, columns.count))
                let side = min(
                    9,
                    max(2.5, (proxy.size.width - gap * (across - 1)) / across),
                )
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: gap) {
                            ForEach(column, id: \.date) { cell in
                                square(for: cell.day, side: side)
                            }
                            // A short column (the last one, usually) keeps the
                            // rows aligned by holding its own height.
                            if column.count < 7 {
                                Color.clear.frame(width: 1, height: 0)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 64)
            footer
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Work in the last year"))
        .accessibilityValue(Text("\(totalMessages) messages, \(totalTokens) tokens"))
        .accessibilityIdentifier("home.heatmap")
    }

    private var totalMessages: Int {
        cells.reduce(0) { $0 + ($1.day?.messages ?? 0) }
    }

    private var totalTokens: Int {
        cells.reduce(0) { $0 + ($1.day?.tokens ?? 0) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Last year")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if loading {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            reading("\(totalMessages.formatted())", "messages")
            reading(totalTokens.formatted(.number.notation(.compactName)), "tokens")
            Spacer(minLength: 0)
            // What the colours mean, said once rather than in a legend box.
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(level(step, of: 3))
                        .frame(width: 9, height: 9)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func reading(_ value: String, _ unit: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
            Text(unit)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// One day's square.
    ///
    /// - Parameters:
    ///   - day: the day, when the host has a figure for it.
    ///   - side: the edge length the grid worked out for the room it has.
    private func square(for day: UsageDay?, side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: max(2.5, side * 0.22), style: .continuous)
            .fill(fill(for: day))
            .frame(width: side, height: side)
    }

    /// The colour of one day: the accent, four steps up from an empty square.
    private func fill(for day: UsageDay?) -> Color {
        guard let day, day.tokens > 0 || day.messages > 0 else {
            return Color.secondary.opacity(0.16)
        }
        let share = Double(day.tokens) / Double(peak)
        let step = min(3, max(0, Int((share * 4).rounded(.up)) - 1))
        return level(step, of: 3)
    }

    private func level(_ step: Int, of highest: Int) -> Color {
        let opacity = highest == 0 ? 1 : 0.22 + 0.78 * (Double(step) / Double(highest))
        return Color.accentColor.opacity(opacity)
    }
}

/// The door back into the conversation that was last on screen.
struct LastSessionButton: View {
    /// The session to open, when there is one.
    let session: SessionRow?
    /// What that session is called, as the sidebar calls it.
    let title: String?
    /// Called with the session's id.
    let open: (String) -> Void
    /// Whether this is the first of several: only the first explains itself,
    /// because three identical subtitles is a column of noise.
    var leads: Bool = true

    private var label: String {
        guard session != nil else { return String(localized: "No conversation yet") }
        guard let title, !title.isEmpty else { return session?.sessionId ?? "" }
        return title
    }

    var body: some View {
        Button {
            if let session { open(session.sessionId) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.fill.tertiary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if leads {
                        Text("Continue where you left off")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: leads ? 62 : 48)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(scale: 0.98))
        .disabled(session == nil)
        .accessibilityIdentifier("home.lastSession")
    }
}
