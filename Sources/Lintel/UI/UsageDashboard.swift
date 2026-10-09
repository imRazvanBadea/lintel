import SwiftUI
import Charts

/// Cost (API estimate) or tokens over 24h / 7d / 30d / 90d, per tool and per model.
struct UsageDashboard: View {
    @Environment(UsageHistory.self) private var history
    @Environment(IslandModel.self) private var model
    /// The hover tooltip's size, to keep it inside the chart.
    @State private var tipSize: CGSize = .zero

    // Kept on the model so the dashboard reopens where you left it.
    private var range: UsageHistory.Range { model.usageRange }
    private var showCost: Bool { model.usageShowsCost }
    private var hovered: Date? { model.usageHover }

    var body: some View {
        let s = history.summary(range)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { IslandModel.shared.showingUsage = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(IconButtonStyle(size: 26))
                Text("Usage").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                Spacer()
                Segmented(options: ["Cost", "Tokens"], selection: Binding(get: { showCost ? 0 : 1 }, set: { model.usageShowsCost = $0 == 0 }))
            }
            .padding([.horizontal, .top], 20)

            // Everything below the header scrolls once the card would be taller than the screen allows.
            CappedScroll(maxHeight: model.maxCardHeight - 66) {
                details(s)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: range)
        .animation(.easeInOut(duration: 0.25), value: showCost)
        .onAppear { history.refresh() }
    }

    private func details(_ s: UsageHistory.Summary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showCost ? money(s.cost) : formatTokens(s.totals.total))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                    HStack(spacing: 4) {
                        Text("\(s.sessions) sessions" + (showCost ? " · API estimate" : ""))
                        if showCost {
                            Image(systemName: "info.circle").font(.system(size: 10))
                                .help("What this usage would cost at API list prices. Subscriptions bill differently. Models without a published price aren't counted.")
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Segmented(options: UsageHistory.Range.allCases.map(\.rawValue),
                          selection: Binding(get: { UsageHistory.Range.allCases.firstIndex(of: range) ?? 1 },
                                             set: { model.usageRange = UsageHistory.Range.allCases[$0] }))
            }

            chart(s)

            VStack(spacing: 10) {
                ForEach(s.tools) { t in toolRow(t, s) }
            }

            if !s.models.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("By model").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiary).padding(.bottom, 6)
                    ForEach(s.models.prefix(6)) { m in modelRow(m, s) }
                }
            }

            HStack {
                stat("Cached input", formatTokens(s.totals.cacheRead))
                stat("Uncached input", formatTokens(s.totals.input + s.totals.cacheWrite5m + s.totals.cacheWrite1h))
                stat("Output", formatTokens(s.totals.output))
                stat("Cache savings", money(s.savings))
            }
            .padding(.top, 2)

            if history.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading history…").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 14)
    }

    // MARK: Pieces

    /// Tools with something to plot in the current mode (Codex has tokens but no published price).
    private func plotted(_ s: UsageHistory.Summary) -> [AgentKind] {
        s.tools.filter { showCost ? $0.cost > 0 : $0.tokens > 0 }.map(\.tool)
    }

    private func value(_ p: UsageHistory.Point) -> Double { showCost ? p.cost : Double(p.tokens) }

    private func chart(_ s: UsageHistory.Summary) -> some View {
        let tools = plotted(s)
        return Chart(s.points.filter { tools.contains($0.tool) }) { p in
            AreaMark(x: .value("Time", p.date), y: .value(showCost ? "Cost" : "Tokens", showCost ? p.cost : Double(p.tokens)),
                     stacking: .unstacked)
                .foregroundStyle(by: .value("Tool", p.tool.label))
                .interpolationMethod(.monotone)
                .opacity(0.16)
            LineMark(x: .value("Time", p.date), y: .value(showCost ? "Cost" : "Tokens", showCost ? p.cost : Double(p.tokens)))
                .foregroundStyle(by: .value("Tool", p.tool.label))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
        }
        .chartForegroundStyleScale(domain: AgentKind.allCases.map(\.label), range: AgentKind.allCases.map(\.chartColor))
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(showCost ? money(d, compact: true) : formatTokens(Int(d))) }
                }
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                hoverLayer(proxy, g, s, tools)
            }
        }
        .frame(height: 150)
    }

    // MARK: Hover

    @ViewBuilder
    private func hoverLayer(_ proxy: ChartProxy, _ g: GeometryProxy, _ s: UsageHistory.Summary, _ tools: [AgentKind]) -> some View {
        let plot = proxy.plotFrame.map { g[$0] } ?? .zero
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let d: Date? = proxy.value(atX: p.x - plot.minX)
                        model.usageHover = d.flatMap { nearestBucket($0, s) }
                    case .ended:
                        model.usageHover = nil
                    }
                }
            if let h = hovered, let x = proxy.position(forX: h) {
                let lineX = plot.minX + x
                Rectangle().fill(Theme.secondary.opacity(0.5))
                    .frame(width: 1, height: plot.height)
                    .offset(x: lineX, y: plot.minY)
                    .allowsHitTesting(false)
                tooltip(h, s, tools)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                    .offset(x: lineX + 12 + tipSize.width > plot.maxX ? lineX - 12 - tipSize.width : lineX + 12,
                            y: plot.minY + max(0, (plot.height - tipSize.height) / 2))
                    .allowsHitTesting(false)
            }
        }
    }

    private func nearestBucket(_ d: Date, _ s: UsageHistory.Summary) -> Date? {
        let start = Date().addingTimeInterval(-range.seconds)
        guard d >= start.addingTimeInterval(-range.step), d <= Date().addingTimeInterval(range.step) else { return nil }
        return Set(s.points.map(\.date)).min { abs($0.timeIntervalSince(d)) < abs($1.timeIntervalSince(d)) }
    }

    private func tooltip(_ date: Date, _ s: UsageHistory.Summary, _ tools: [AgentKind]) -> some View {
        let here = s.points.filter { $0.date == date }
        let rows = (tools.isEmpty ? s.tools.map(\.tool) : tools).map { t in (t, here.filter { $0.tool == t }.reduce(0) { $0 + value($1) }) }
        let total = rows.reduce(0) { $0 + $1.1 }
        func fmt(_ v: Double) -> String { showCost ? money(v) : formatTokens(Int(v)) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(range == .day ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                               : date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            ForEach(rows, id: \.0) { t, v in
                HStack(spacing: 6) {
                    AgentLogo(kind: t, size: 12)
                    Text(t.label).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 14)
                    Text(fmt(v)).monospacedDigit().foregroundStyle(Theme.primary)
                }
            }
            if rows.count > 1 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack {
                    Text("Total").foregroundStyle(Theme.secondary)
                    Spacer(minLength: 14)
                    Text(fmt(total)).monospacedDigit().foregroundStyle(Theme.primary)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 150)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .fixedSize()
    }

    private func toolRow(_ t: UsageHistory.ToolTotal, _ s: UsageHistory.Summary) -> some View {
        let share = showCost ? (s.cost > 0 ? t.cost / s.cost : 0) : (s.totals.total > 0 ? Double(t.tokens) / Double(s.totals.total) : 0)
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(t.tool.chartColor).frame(width: 7, height: 7).padding(.top, 6)
            AgentLogo(kind: t.tool, size: 15).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(t.tool.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                    Text("\(t.sessions) sessions").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                Text("\(percent(share)) of \(showCost ? "cost" : "tokens") · " + (showCost ? "\(formatTokens(t.tokens)) tokens" : money(t.cost)))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text(showCost ? (t.cost > 0 || t.unpricedTokens == 0 ? money(t.cost) : "Unpriced") : formatTokens(t.tokens))
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Theme.primary)
        }
    }

    private func modelRow(_ m: UsageHistory.ModelTotal, _ s: UsageHistory.Summary) -> some View {
        let share = showCost ? (s.cost > 0 ? (m.cost ?? 0) / s.cost : 0) : (s.totals.total > 0 ? Double(m.tokens) / Double(s.totals.total) : 0)
        return HStack(spacing: 8) {
            AgentLogo(kind: m.tool, size: 13)
            Text(m.model).font(.system(size: 12.5)).foregroundStyle(Theme.primary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(showCost ? (m.cost.map { money($0) } ?? "Unpriced") : formatTokens(m.tokens))
                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(m.cost == nil && showCost ? Theme.tertiary : Theme.primary)
            Text(m.cost == nil && showCost ? "—" : percent(share))
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Theme.primary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ v: Double, compact: Bool = false) -> String {
        if compact { return v >= 1000 ? String(format: "$%.0fk", v / 1000) : String(format: "$%.0f", v) }
        return v.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func percent(_ v: Double) -> String {
        v > 0 && v < 0.001 ? "<0.1%" : String(format: "%.1f%%", v * 100)
    }
}

/// Its content at natural height, scrolling only when that would exceed `maxHeight`.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height > 0 ? min(height, cap) : nil)
        // A soft bottom edge hints there's more to scroll.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: height > cap ? 0.92 : 1),
                                     .init(color: height > cap ? .clear : .black, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var cap: CGFloat { max(maxHeight, 200) }


}

/// A small pill-style segmented control that matches the rest of Lintel.
struct Segmented: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button { selection = i } label: {
                    Text(o).font(.system(size: 11.5, weight: selection == i ? .semibold : .regular))
                        .foregroundStyle(selection == i ? Theme.primary : Theme.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(selection == i ? Theme.raised : .clear)
                            .shadow(color: selection == i ? .black.opacity(0.08) : .clear, radius: 2, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
    }
}

extension AgentKind: CaseIterable {
    static var allCases: [AgentKind] { [.claude, .cursor, .codex] }

    /// Chart colours: Claude's orange, Cursor's graphite, Codex's blue.
    var chartColor: Color {
        switch self {
        case .claude: Color(hex: 0xD97757)
        case .cursor: Theme.dynamic(light: NSColor(white: 0.35, alpha: 1), dark: NSColor(white: 0.7, alpha: 1))
        case .codex: Color(hex: 0x4F8EF7)
        }
    }
}
