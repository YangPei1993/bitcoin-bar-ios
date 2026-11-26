import Charts
import SwiftUI

// MARK: - 图表样式

nonisolated enum DetailChartStyle: String, CaseIterable, Identifiable, Sendable {
    case candle
    case area

    var id: String { rawValue }

    var label: String {
        switch self {
        case .candle: return "K线"
        case .area: return "分时"
        }
    }
}

// MARK: - 24h 价格区间进度条

struct DayRangeBar: View {
    let low: Double
    let high: Double
    let current: Double
    let accent: Color

    var body: some View {
        let span = max(high - low, 0.00000001)
        let ratio = min(max((current - low) / span, 0), 1)

        VStack(spacing: 5) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let knobX = max(5, min(width - 5, width * ratio))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 5)

                    Capsule()
                        .fill(accent.opacity(0.78))
                        .frame(width: max(5, knobX), height: 5)

                    Circle()
                        .fill(accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.8))
                        .offset(x: knobX - 5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)

            HStack {
                Text("24h 低 \(MarketFormatter.price(low))")
                Spacer()
                Text("24h 高 \(MarketFormatter.price(high))")
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - iOS 触控交互式行情图表（K 线 / 分时 / MA7 & MA25 / 手指查价十字光标）

struct InteractiveMarketChart: View {
    let klines: [KlinePoint]
    let interval: KlineInterval
    let isLoading: Bool
    let errorMessage: String?
    let settings: AppSettings
    let onRetry: () -> Void

    @State private var chartStyle: DetailChartStyle = .candle
    @State private var showMA = true
    @State private var visibleCount = 52
    @State private var selectedPoint: KlinePoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chartToolbar
            crosshairHUD

            if isLoading && klines.isEmpty {
                loadingPlaceholder
            } else if let errorMessage, klines.isEmpty {
                errorPlaceholder(errorMessage)
            } else if visibleKlines.isEmpty {
                loadingPlaceholder
            } else {
                VStack(spacing: 4) {
                    mainPriceChart
                    volumeSubChart
                }
            }
        }
        .onChange(of: interval) { _, _ in
            selectedPoint = nil
            visibleCount = 52
        }
    }

    private var chartToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(DetailChartStyle.allCases) { style in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            chartStyle = style
                        }
                    } label: {
                        Text(style.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(chartStyle == style ? Color.accentColor.opacity(0.18) : Color.clear)
                            )
                            .foregroundStyle(chartStyle == style ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))

            if chartStyle == .candle {
                Button {
                    showMA.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("MA")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(showMA ? Color.orange.opacity(0.18) : Color(.tertiarySystemFill))
                    )
                    .foregroundStyle(showMA ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    visibleCount = max(20, Int(Double(visibleCount) * 0.75))
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    visibleCount = min(max(klines.count, 20), min(160, Int(Double(visibleCount) * 1.3)))
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var crosshairHUD: some View {
        Group {
            if let point = selectedPoint ?? visibleKlines.last {
                let change = point.open == 0 ? 0 : ((point.close - point.open) / point.open) * 100
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(MarketFormatter.chartTimestamp(point.openTime, interval: interval))
                            .foregroundStyle(selectedPoint != nil ? .primary : .secondary)
                        Spacer()
                        Text("涨跌 \(MarketFormatter.changePercent(change))")
                            .foregroundStyle(settings.changeColor(for: change))
                    }
                    HStack(spacing: 10) {
                        hudItem("开", MarketFormatter.price(point.open, includeSymbol: false))
                        hudItem("高", MarketFormatter.price(point.high, includeSymbol: false))
                        hudItem("低", MarketFormatter.price(point.low, includeSymbol: false))
                        hudItem("收", MarketFormatter.price(point.close, includeSymbol: false))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else {
                Text("在图表上滑动手指可查看单根 K 线详情")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func hudItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }

    private var mainPriceChart: some View {
        let series = visibleKlines
        let ma7Series = showMA && chartStyle == .candle ? movingAveragePoints(period: 7) : []
        let ma25Series = showMA && chartStyle == .candle ? movingAveragePoints(period: 25) : []
        let areaTrendColor: Color = {
            guard let first = series.first, let last = series.last else { return settings.upColor }
            return last.close >= first.close ? settings.upColor : settings.downColor
        }()

        return Chart {
            if chartStyle == .candle {
                ForEach(series) { point in
                    RuleMark(
                        x: .value("时间", point.openTime),
                        yStart: .value("低", point.low),
                        yEnd: .value("高", point.high)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(settings.candleColor(for: point))

                    RectangleMark(
                        x: .value("时间", point.openTime),
                        yStart: .value("下", bodyLower(for: point)),
                        yEnd: .value("上", bodyUpper(for: point)),
                        width: .fixed(candleWidth)
                    )
                    .foregroundStyle(settings.candleColor(for: point))
                    .cornerRadius(0.8)
                }

                ForEach(ma7Series) { item in
                    LineMark(x: .value("时间", item.time), y: .value("MA7", item.value), series: .value("均线", "MA7"))
                        .foregroundStyle(Color.orange.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }

                ForEach(ma25Series) { item in
                    LineMark(x: .value("时间", item.time), y: .value("MA25", item.value), series: .value("均线", "MA25"))
                        .foregroundStyle(Color.purple.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            } else {
                ForEach(series) { point in
                    AreaMark(
                        x: .value("时间", point.openTime),
                        yStart: .value("底", yDomain.lowerBound),
                        yEnd: .value("收", point.close)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [areaTrendColor.opacity(0.28), areaTrendColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(x: .value("时间", point.openTime), y: .value("收", point.close))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(areaTrendColor)
                }
            }

            if let last = series.last {
                RuleMark(y: .value("最新价", last.close))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }

            if let selectedPoint {
                RuleMark(x: .value("选中时间", selectedPoint.openTime))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 0.9, dash: [2, 2]))

                RuleMark(y: .value("选中价", selectedPoint.close))
                    .foregroundStyle(Color.primary.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 0.9, dash: [2, 2]))

                PointMark(x: .value("选中时间", selectedPoint.openTime), y: .value("选中价", selectedPoint.close))
                    .symbolSize(34)
                    .foregroundStyle(settings.candleColor(for: selectedPoint))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(MarketFormatter.price(price, includeSymbol: false))
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let originX = geometry[plotFrame].origin.x
                                let xInPlot = value.location.x - originX
                                if let date: Date = proxy.value(atX: xInPlot) {
                                    selectedPoint = nearestPoint(to: date, in: series)
                                }
                            }
                            .onEnded { _ in
                                selectedPoint = nil
                            }
                    )
            }
        }
        .frame(height: 210)
    }

    private var volumeSubChart: some View {
        Chart(visibleKlines) { point in
            BarMark(
                x: .value("时间", point.openTime),
                y: .value("量", point.volume),
                width: .fixed(max(candleWidth - 0.8, 1.8))
            )
            .foregroundStyle(settings.candleColor(for: point).opacity(0.45))
        }
        .chartXScale(domain: xDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(MarketFormatter.chartTimestamp(date, interval: interval))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: 48)
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(height: 250)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("加载 K 线行情...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func errorPlaceholder(_ message: String) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(height: 250)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新加载", action: onRetry)
                        .buttonStyle(.bordered)
                }
            }
    }

    private var visibleRange: Range<Int> {
        guard klines.isEmpty == false else { return 0..<0 }
        let count = min(max(visibleCount, 16), klines.count)
        let start = max(klines.count - count, 0)
        return start..<klines.count
    }

    private var visibleKlines: [KlinePoint] {
        let range = visibleRange
        guard range.lowerBound < range.upperBound else { return [] }
        return Array(klines[range])
    }

    private var candleWidth: CGFloat {
        let count = max(visibleKlines.count, 1)
        return min(max(240.0 / CGFloat(count), 2.2), 8.5)
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = visibleKlines.first, let last = visibleKlines.last else {
            let now = Date()
            return now...now.addingTimeInterval(Double(interval.rawValue))
        }
        let step = Double(interval.rawValue)
        return first.openTime.addingTimeInterval(-step * 0.6)...last.openTime.addingTimeInterval(step * 0.8)
    }

    private var yDomain: ClosedRange<Double> {
        guard let minVal = visibleKlines.map(\.low).min(),
              let maxVal = visibleKlines.map(\.high).max() else {
            return 0...1
        }
        let span = max(maxVal - minVal, maxVal * 0.0005, 0.00000001)
        let padding = span * 0.10
        return (minVal - padding)...(maxVal + padding)
    }

    private var minBodyHeight: Double {
        (yDomain.upperBound - yDomain.lowerBound) * 0.005
    }

    private func bodyLower(for point: KlinePoint) -> Double {
        let low = min(point.open, point.close)
        let high = max(point.open, point.close)
        guard high - low < minBodyHeight else { return low }
        return (low + high) / 2 - minBodyHeight / 2
    }

    private func bodyUpper(for point: KlinePoint) -> Double {
        let low = min(point.open, point.close)
        let high = max(point.open, point.close)
        guard high - low < minBodyHeight else { return high }
        return (low + high) / 2 + minBodyHeight / 2
    }

    private struct MAPoint: Identifiable {
        let time: Date
        let value: Double
        var id: Date { time }
    }

    private func movingAveragePoints(period: Int) -> [MAPoint] {
        guard klines.count >= period else { return [] }
        let range = visibleRange
        var points: [MAPoint] = []
        var sum = 0.0
        for idx in 0..<klines.count {
            sum += klines[idx].close
            if idx >= period { sum -= klines[idx - period].close }
            if idx >= period - 1 && range.contains(idx) {
                points.append(MAPoint(time: klines[idx].openTime, value: sum / Double(period)))
            }
        }
        return points
    }

    private func nearestPoint(to date: Date, in points: [KlinePoint]) -> KlinePoint? {
        points.min { abs($0.openTime.timeIntervalSince(date)) < abs($1.openTime.timeIntervalSince(date)) }
    }
}
