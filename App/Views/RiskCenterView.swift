import SwiftUI

struct RiskCenterView: View {
    @Bindable var riskEngine: RiskMonitorEngine
    let alertStore: PriceAlertStore
    let portfolioStore: PortfolioStore
    @Bindable var dispatcher: NotificationDispatcher
    let settings: AppSettings
    let onOpenChannels: () -> Void

    var body: some View {
        Form {
            // 1. 系统通知与静音总控
            Section {
                Toggle("全局静音（暂停外部推送与告警音）", isOn: $dispatcher.isMuted)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已启用 \(dispatcher.enabledChannelCount) 个外部推送通道")
                            .font(.subheadline)
                        Text("微信 / 企业微信 / Bark / 飞书 / TG / 短信")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("管理通道", action: onOpenChannels)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Button("发送本机测试通知") {
                    Task {
                        await alertStore.requestAuthorizationIfNeeded()
                        alertStore.sendTestNotification()
                    }
                }
            } header: {
                Text("通知总控")
            }

            // 2. 主动风控预警规则
            Section("主动风控预警") {
                Toggle("合约强平距离预警（P0 / P1）", isOn: $riskEngine.config.liquidationEnabled)
                if riskEngine.config.liquidationEnabled {
                    Stepper("预警线：距强平 ≤ \(Int(riskEngine.config.liquidationWarningPercent))%", value: $riskEngine.config.liquidationWarningPercent, in: 3...40, step: 1)
                    Stepper("极危线：距强平 ≤ \(Int(riskEngine.config.liquidationCriticalPercent))%", value: $riskEngine.config.liquidationCriticalPercent, in: 1...25, step: 1)
                }

                Toggle("单仓浮亏 / ROE 预警（P1）", isOn: $riskEngine.config.positionLossEnabled)
                if riskEngine.config.positionLossEnabled {
                    Stepper("单仓亏损 ROE ≥ \(Int(riskEngine.config.positionLossROEPercent))%", value: $riskEngine.config.positionLossROEPercent, in: 5...95, step: 5)
                    HStack {
                        Text("或单仓浮亏金额 ≥ $")
                        TextField("0=关闭", value: $riskEngine.config.positionLossUSD, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Toggle("账户当日净值回撤预警（P0）", isOn: $riskEngine.config.drawdownEnabled)
                if riskEngine.config.drawdownEnabled {
                    Stepper("回撤阈值 ≥ \(Int(riskEngine.config.drawdownThresholdPercent))%", value: $riskEngine.config.drawdownThresholdPercent, in: 2...50, step: 1)
                    if riskEngine.dailyPeakEquityUSD > 0 {
                        HStack {
                            Text("今日净值峰值：\(MarketFormatter.price(riskEngine.dailyPeakEquityUSD))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("重置峰值") { riskEngine.resetDailyPeak() }
                                .font(.caption)
                        }
                    }
                }

                Toggle("自选与持仓短时剧烈异动（P1）", isOn: $riskEngine.config.volatilityEnabled)
                if riskEngine.config.volatilityEnabled {
                    Picker("监控时间窗口", selection: $riskEngine.config.volatilityWindowMinutes) {
                        Text("3 分钟").tag(3)
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                    }
                    Stepper("异动涨跌幅 ≥ \(String(format: "%.1f", riskEngine.config.volatilityThresholdPercent))%", value: $riskEngine.config.volatilityThresholdPercent, in: 1...20, step: 0.5)
                }

                Picker("持续风险提醒频率", selection: $riskEngine.config.repeatPolicy) {
                    ForEach(RiskRepeatPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }

            // 3. 余额提醒列表
            Section("账户余额提醒（\(portfolioStore.balanceAlerts.count)）") {
                if portfolioStore.balanceAlerts.isEmpty {
                    Text("在「资产」页点击“余额提醒”或币种右侧铃铛添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(portfolioStore.balanceAlerts) { alert in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.scope.title).font(.subheadline.weight(.semibold))
                                Text("\(alert.direction.label) \(alert.formattedThreshold)")
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(alert.direction == .above ? settings.upColor : settings.downColor)
                                if let t = alert.lastTriggeredAt {
                                    Text("上次触发：\(MarketFormatter.clockTime(t))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { alert.isEnabled },
                                set: { _ in portfolioStore.toggleBalanceAlert(id: alert.id) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            portfolioStore.deleteBalanceAlert(id: portfolioStore.balanceAlerts[idx].id)
                        }
                    }
                }
            }

            // 4. 价格提醒列表
            Section("币种价格提醒（\(alertStore.alerts.count)）") {
                if alertStore.alerts.isEmpty {
                    Text("在行情列表左滑或详情页点击“添加提醒”创建。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(alertStore.alerts) { alert in
                        HStack(spacing: 10) {
                            CoinAvatar(symbol: alert.asset.symbol, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.asset.pairLabel).font(.subheadline.weight(.semibold))
                                Text("\(alert.direction.label) \(MarketFormatter.price(alert.targetPrice))")
                                    .font(.caption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(alert.direction == .above ? settings.upColor : settings.downColor)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { alert.isEnabled },
                                set: { _ in alertStore.toggleAlert(id: alert.id) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            alertStore.deleteAlert(id: alertStore.alerts[idx].id)
                        }
                    }
                }
            }

            // 5. 最近告警记录
            Section("最近触发记录（\(dispatcher.recentEvents.count)）") {
                if dispatcher.recentEvents.isEmpty {
                    Text("暂无告警触发记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(dispatcher.recentEvents.prefix(15)) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.severity.badge)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(record.severity == .critical ? MarketColors.red : (record.severity == .warning ? .orange : Color.accentColor), in: RoundedRectangle(cornerRadius: 4))
                                Text(record.title).font(.caption.weight(.semibold))
                                Spacer()
                                Text(MarketFormatter.clockTime(record.timestamp)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            }
                            Text(record.deliverySummary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button("清空历史记录", role: .destructive) {
                        dispatcher.clearHistory()
                    }
                }
            }
        }
        .navigationTitle("风控与提醒")
        .navigationBarTitleDisplayMode(.inline)
    }
}
