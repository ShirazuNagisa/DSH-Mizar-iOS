//
//  HomeView.swift
//  DSH-Mizar
//
//  The conversation pane with no conversation in it.
//
//  It used to open with the mark, the computer's name and a composer -- an
//  invitation to start work. The operator's answer was that this is a *report*,
//  not a form: what they want on opening the app is the month, in figures, the
//  way the desktop's home page shows it. So the top of the page is six readings
//  folded from the same history the heatmap draws, and the only thing to press
//  is the way back into the last conversation.
//

import SwiftUI
import MizarKit

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // The top half, and no more: the six figures and the year they
            // describe. Anything taller pushes the way back into the work off
            // the bottom of the screen.
            VStack(spacing: 16) {
                UsageReadings(
                    overview: model.usageOverview,
                    loading: model.usageLoading,
                )
                UsageHeatmap(
                    days: model.usageOverview?.days ?? [],
                    loading: model.usageLoading,
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            // Right under the year, not pinned to the bottom of the screen: the
            // page reads top to bottom, and a list floating at the bottom of an
            // empty screen reads as a mistake.
            .padding(.bottom, 22)
            // The conversations that were last on screen, under a title that
            // says what they are.
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick up where you left off")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("home.recent.title")
                ForEach(Array(recentSessions.enumerated()), id: \.element.sessionId) { index, session in
                    LastSessionButton(
                        session: session,
                        title: model.titles[session.sessionId],
                        open: { model.selectedSessionId = $0 },
                        leads: index == 0,
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            // Whatever room is left stays at the bottom, so the page is filled
            // from the top rather than spread out.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await model.loadUsageOverview() }
        }
    }

    /// The four most recently touched conversations, newest first.
    private var recentSessions: [SessionRow] {
        Array(
            model.sessions
                .filter { !$0.blank && !$0.isSubagent }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(4),
        )
    }
}

/// The month in six readings, above the heatmap.
///
/// The same six the desktop's home page shows: how many conversations, how many
/// messages, how many tokens, how many days had any work, when in the day it
/// happens, and which model did most of it. Every one is folded from the
/// history the heatmap draws -- no second request, no second source -- so the
/// figures cannot disagree with the squares under them.
private struct UsageReadings: View {
    let overview: UsageOverview?
    let loading: Bool

    /// Three across, two down: a phone reads six short figures as a block.
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            reading("Sessions", sessions)
            reading("Messages", messages)
            reading("Total tokens", tokens)
            reading("Active days", activeDays)
            reading("Busiest hour", busiestHour)
            reading("Top model", topModel, compact: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.readings")
    }

    /// One figure.
    ///
    /// - Parameters:
    ///   - title: already localised.
    ///   - value: the figure, formatted for reading.
    ///   - compact: whether the value is a name rather than a number, which is
    ///     set smaller so a long model id fits its card.
    private func reading(_ title: String, _ value: String, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(compact ? .footnote.weight(.semibold) : .title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(compact ? 0.6 : 0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            .fill.quaternary,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous),
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.reading.\(title)")
    }

    private var sessions: String {
        guard let overview else { return loading ? "…" : "—" }
        return overview.sessions.formatted()
    }

    private var messages: String {
        guard let overview else { return loading ? "…" : "—" }
        return overview.days.reduce(0) { $0 + $1.messages }.formatted()
    }

    private var tokens: String {
        guard let overview else { return loading ? "…" : "—" }
        let total = overview.days.reduce(0) { $0 + $1.tokens }
        return total.formatted(.number.notation(.compactName))
    }

    private var activeDays: String {
        guard let overview else { return loading ? "…" : "—" }
        return overview.days.count.formatted()
    }

    /// The hour the month spent most of its messages in, as `HH:00`.
    private var busiestHour: String {
        guard let overview else { return loading ? "…" : "—" }
        var buckets = Array(repeating: 0, count: 24)
        for day in overview.days {
            for (hour, count) in (day.hours ?? []).enumerated() where hour < 24 {
                buckets[hour] += count
            }
        }
        guard let peak = buckets.max(), peak > 0, let hour = buckets.firstIndex(of: peak) else {
            return "—"
        }
        return String(format: "%02d:00", hour)
    }

    /// The model that answered most of the month's messages.
    private var topModel: String {
        guard let overview else { return loading ? "…" : "—" }
        var byModel: [String: Int] = [:]
        for day in overview.days {
            for usage in day.models ?? [] {
                byModel[usage.model, default: 0] += usage.messages
            }
        }
        return byModel.max { $0.value < $1.value }?.key ?? "—"
    }
}

#Preview {
    UsageReadings(overview: nil, loading: true)
        .padding()
}
