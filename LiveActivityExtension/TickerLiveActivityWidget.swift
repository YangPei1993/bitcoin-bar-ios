import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 灵动岛与锁屏实时活动小组件

struct TickerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TickerActivityAttributes.self) { context in
            LockScreenLiveView(state: context.state)
                .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.13))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // 展开态左上：账户总余额与未实现盈亏
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "wallet.bifold.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.65))
                            Text("总资产")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        if let equity = state.totalEquityUSD {
                            Text(state.hideAmounts ? "****" : LiveActivityFormatter.fullBalance(equity))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        } else {
                            Text("未绑定账户")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(.leading, 4)
                }

                // 展开态右上：合约未实现盈亏 / 风险告警 + 原地刷新按钮
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let risk = state.criticalRiskLabel {
                                Text(risk)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red, in: Capsule())
                                    .lineLimit(1)
                            } else if let pnl = state.unrealizedPnL {
                                Text("未实现盈亏")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.55))
                                Text(state.hideAmounts ? "****" : LiveActivityFormatter.signedUSD(pnl))
                                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(state.hideAmounts ? .white.opacity(0.7) : changeColor(pnl, isGreenUp: state.isGreenUp))
                            } else {
                                Text(state.updatedAt, style: .time)
                                    .font(.system(size: 10, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }

                        Button(intent: RefreshLiveActivityIntent()) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.82))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 4)
                }

                // 展开态底部：最多 3 个观测标的现价并排卡片
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        ForEach(state.watchedItems.prefix(3)) { item in
                            ExpandedTickerTile(item: item, isGreenUp: state.isGreenUp)
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                // 收起态药丸左侧：主观测标的 + 实时现价
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.criticalRiskLabel != nil ? Color.red : changeColor(state.primaryChange24h, isGreenUp: state.isGreenUp))
                        .frame(width: 6, height: 6)
                    Text(state.primarySymbol)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(state.primaryPrice > 0 ? LiveActivityFormatter.price(state.primaryPrice) : "--")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } compactTrailing: {
                // 收起态药丸右侧：优先显示账户总余额，未绑定或隐私隐藏时显示涨跌幅
                if state.showBalanceInCompact, let equity = state.totalEquityUSD, state.hideAmounts == false {
                    HStack(spacing: 3) {
                        Image(systemName: "wallet.bifold.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(LiveActivityFormatter.compactBalance(equity))
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                } else {
                    Text(LiveActivityFormatter.changePercent(state.primaryChange24h, digits: 1))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(changeColor(state.primaryChange24h, isGreenUp: state.isGreenUp))
                        .lineLimit(1)
                }
            } minimal: {
                if state.criticalRiskLabel != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else {
                    Text(state.primarySymbol.prefix(3))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(changeColor(state.primaryChange24h, isGreenUp: state.isGreenUp))
                }
            }
            .widgetURL(URL(string: "bitcoinbar://open"))
            .keylineTint(changeColor(state.primaryChange24h, isGreenUp: state.isGreenUp))
        }
    }
}

// MARK: - 锁屏 / StandBy 卡片视图

private struct LockScreenLiveView: View {
    let state: TickerActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Text("₿")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("bitcoin-bar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                if let equity = state.totalEquityUSD {
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: "wallet.bifold.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(state.hideAmounts ? "****" : LiveActivityFormatter.fullBalance(equity))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }

                        if let pnl = state.unrealizedPnL, state.hideAmounts == false {
                            Text(LiveActivityFormatter.signedUSD(pnl))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(changeColor(pnl, isGreenUp: state.isGreenUp))
                        }
                    }
                } else {
                    Text(state.updatedAt, style: .time)
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                }

                Button(intent: RefreshLiveActivityIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if let risk = state.criticalRiskLabel {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 11))
                    Text(risk)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 8) {
                ForEach(state.watchedItems.prefix(3)) { item in
                    ExpandedTickerTile(item: item, isGreenUp: state.isGreenUp)
                }
            }
        }
        .padding(14)
    }
}

private struct ExpandedTickerTile: View {
    let item: LiveTickerItem
    let isGreenUp: Bool

    var body: some View {
        let color = changeColor(item.changePercentage24h, isGreenUp: isGreenUp)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(item.symbol)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if item.isContract {
                    Text("永续")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
            }

            Text(item.price > 0 ? LiveActivityFormatter.price(item.price) : "--")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(LiveActivityFormatter.changePercent(item.changePercentage24h, digits: 2))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private func changeColor(_ value: Double, isGreenUp: Bool) -> Color {
    let green = Color(red: 0.16, green: 0.80, blue: 0.50)
    let red = Color(red: 0.96, green: 0.34, blue: 0.38)
    if value > 0 { return isGreenUp ? green : red }
    if value < 0 { return isGreenUp ? red : green }
    return .white.opacity(0.6)
}
