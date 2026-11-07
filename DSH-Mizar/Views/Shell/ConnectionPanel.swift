//
//  ConnectionPanel.swift
//  DSH-Mizar
//
//  How the phone is talking to the computer, right now.
//
//  The small window out of the connection capsule at the foot of the sidebar.
//  Three questions, in the order somebody asks them when something looks stale:
//
//    - **Is it connected, and how?** Direct or through the relay, to which
//      address, and for how long.
//    - **How fast is it?** Measured while the window is open -- a `ping` every
//      two seconds, drawn as a trace, so a link that is getting worse is seen
//      getting worse rather than reported as one number.
//    - **Is anything keeping it current?** The poll that follows a running turn
//      -- with a dial that runs down to its next read -- the host's pushed
//      events, and the slow fallback behind them.
//
//  Nothing here is sent while the window is closed: the pings start when it
//  opens and stop when it goes.
//

import SwiftUI
import MizarKit

struct ConnectionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                status(now: context.date)
                latency
                polling(now: context.date)
                if !model.isConnected {
                    Button {
                        Task {
                            // Manual refresh rather than a plain list read: a
                            // reconnect that lands on the relay while the computer
                            // is also audible on this network is a connection the
                            // operator did not need to pay for, and the scan is
                            // what picks the direct link up.
                            if await model.reconnectFromUser() { await model.manualRefresh() }
                        }
                    } label: {
                        HStack {
                            if model.reconnecting { ProgressView().controlSize(.small) }
                            Text(model.reconnecting ? "Trying…" : "Reconnect")
                        }
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(model.reconnecting)
                    .accessibilityIdentifier("connection.reconnect")
                    .transition(.rise)
                }
            }
            .padding(18)
            .frame(width: 320)
        }
        .animation(.mizarSmooth, value: model.isConnected)
        .task(id: model.isConnected) {
            // Measured while somebody is looking, and only then.
            guard model.isConnected else { return }
            while !Task.isCancelled {
                await model.measureLatency()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection.panel")
    }

    // MARK: Status

    private func status(now: Date) -> some View {
        HStack(spacing: 14) {
            ConnectionDot(live: model.isConnected, size: 14)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                    .contentTransition(.opacity)
                Text(route)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if let since = model.connectedSince {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Up for")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(TurnIndexFormat.spell(now.timeIntervalSince(since)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var statusTitle: String {
        if model.isConnected { return String(localized: "Connected") }
        if model.reconnecting { return String(localized: "Connecting…") }
        return String(localized: "Offline")
    }

    /// How the phone is reaching the computer, in the operator's terms.
    ///
    /// A relay's own address is not something anybody can act on -- it is a
    /// string of a hostname -- so a relayed link says which tier of the relay is
    /// carrying it instead. The label follows the relay the socket is actually
    /// on, not the account's plan: a paid phone whose host has not moved yet is
    /// still on the free relay, and claiming otherwise is the one thing this
    /// line exists to avoid. A direct link on the operator's own network says
    /// what it is rather than which address answered: there it is the *kind* of
    /// link that matters, because that is what opened the paid features. A
    /// loopback direct link keeps the address, as it always has -- that is the
    /// simulator talking to the Mac, where "the local network" would be a claim
    /// the route does not support.
    private var route: String {
        guard model.isConnected else {
            return model.hasStoredIndex ? String(localized: "Showing saved history") : String(localized: "Not reachable")
        }
        // The same fact the sidebar's footer is drawn from; the model owns the
        // classification so the two lines cannot disagree.
        if model.isLocalAgentMode { return String(localized: "On this device") }
        if model.isLocalCommunication { return String(localized: "On the local network") }
        switch model.activeEndpoint {
        case .relay(let baseURL):
            return RelayTier.isPaidRelay(baseURL)
                ? String(localized: "High-bandwidth server")
                : String(localized: "Free-tier server")
        case .direct(let authority):
            return String(format: String(localized: "Direct · %@"), authority)
        case .p2p:
            // No address to show: the two ends met at a port neither of them
            // chose and neither keeps. What the operator can act on is the kind
            // of link it is, which is the same word the switch uses.
            return String(localized: "P2P direct connection")
        case nil:
            return model.host?.authority ?? ""
        }
    }

    // MARK: Latency

    private var latency: some View {
        let samples = model.latencySamples
        let last = samples.last
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Latency")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                // Always drawn, so the reading has one element to find it by:
                // the verdict once there is a sample, "Measuring…" until then.
                Text(last.map { quality($0).label } ?? String(localized: "Measuring…"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(last.map { quality($0).tint } ?? Color.secondary)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("connection.latency")
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                // One line, whatever the reading is. Three digits plus the
                // Chinese unit -- "毫秒" is twice the width of "ms" -- used to
                // be squeezed onto two lines the moment a relay's latency
                // crossed 100 ms: the number is a value, and a value split
                // between two lines is a different number. The reading keeps
                // its width (it is the answer); the unit gives way first.
                Text(last.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .layoutPriority(1)
                    .contentTransition(.numericText())
                    .animation(.mizarSnappy, value: last.map { Int($0) })
                Text("ms")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                LatencyTrace(samples: samples, tint: last.map { quality($0).tint } ?? .secondary)
                    .frame(width: 140, height: 38)
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private func quality(_ milliseconds: Double) -> (label: String, tint: Color) {
        switch milliseconds {
        case ..<80: (String(localized: "Excellent"), Theme.running)
        case ..<250: (String(localized: "Good"), Theme.accentText)
        case ..<700: (String(localized: "Slow"), Theme.waiting)
        default: (String(localized: "Poor"), Theme.failed)
        }
    }

    // MARK: Polling

    private func polling(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keeping current")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            row {
                if model.runningPollIsActive {
                    PollDial(fraction: nextTickFraction(now: now))
                } else {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.tertiary)
                }
            } title: {
                Text(model.runningPollIsActive ? "Following the running turn" : "Running-turn poll is idle")
            } detail: {
                Text(pollDetail(now: now))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("connection.poll")
            }

            row {
                Image(systemName: model.listensForHostEvents ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(model.listensForHostEvents ? Theme.accentText : Color.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: model.listensForHostEvents)
            } title: {
                Text(model.listensForHostEvents ? "Live updates from the computer" : "Not receiving live updates")
            } detail: {
                Text(String(format: String(localized: "Requests re-checked every %lld s as a fallback"), seconds(model.interactionFallbackInterval)))
            }

            if model.runningPollFailures > 0 {
                row {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.waiting)
                } title: {
                    Text(String(format: String(localized: "%lld reads in a row did not land"), model.runningPollFailures))
                } detail: {
                    Text("The socket is rebuilt after two.")
                }
                .transition(.rise)
            }
        }
        .animation(.mizarSmooth, value: model.runningPollIsActive)
        .animation(.mizarSmooth, value: model.runningPollFailures)
    }

    private func row<Icon: View, Title: View, Detail: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder title: () -> Title,
        @ViewBuilder detail: () -> Detail,
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon()
                .font(.body)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                title()
                    .font(.subheadline.weight(.medium))
                detail()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }

    private func nextTickFraction(now: Date) -> Double {
        guard let last = model.lastPollTickAt else { return 0 }
        let interval = Double(seconds(model.runningPollInterval))
        return min(1, max(0, now.timeIntervalSince(last) / max(1, interval)))
    }

    private func pollDetail(now: Date) -> String {
        let interval = seconds(model.runningPollInterval)
        guard model.runningPollIsActive else {
            return String(format: String(localized: "Starts by itself when a turn runs, every %lld s"), interval)
        }
        guard let last = model.lastPollTickAt else {
            return String(format: String(localized: "Every %lld s · first read soon"), interval)
        }
        let next = max(0, interval - Int(now.timeIntervalSince(last)))
        return String(format: String(localized: "Every %lld s · next read in %lld s"), interval, next)
    }
}

/// A dial that fills towards the poll's next read.
private struct PollDial: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
            MizarRing(ink: 13, motion: .running)
        }
        .frame(width: 20, height: 20)
    }
}

/// The last couple of dozen round trips, as a line with a soft fill under it.
private struct LatencyTrace: View {
    let samples: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else {
                let y = size.height * 0.7
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                return
            }
            let ceiling = max(60, (samples.max() ?? 60) * 1.25)
            let step = size.width / CGFloat(AppModel.latencyHistory - 1)
            let start = size.width - step * CGFloat(samples.count - 1)
            let points = samples.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step, y: size.height * (1 - CGFloat(value / ceiling)))
            }
            var line = Path()
            line.addLines(points)
            var fill = line
            fill.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            fill.addLine(to: CGPoint(x: points.first!.x, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.28), tint.opacity(0)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height),
            ))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            if let last = points.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(tint))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Green and breathing while the computer is reachable; grey and still when it is
/// not.
struct ConnectionDot: View {
    let live: Bool
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if live && !reduceMotion {
                Circle()
                    .fill(Theme.running.opacity(0.35))
                    .frame(width: size, height: size)
                    .phaseAnimator([false, true]) { content, out in
                        content
                            .scaleEffect(out ? 2.4 : 1)
                            .opacity(out ? 0 : 1)
                    } animation: { out in
                        out ? .easeOut(duration: 1.6) : .linear(duration: 0.01).delay(0.6)
                    }
            }
            Circle()
                .fill(live ? Theme.running : Color.secondary.opacity(0.5))
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .accessibilityHidden(true)
    }
}
