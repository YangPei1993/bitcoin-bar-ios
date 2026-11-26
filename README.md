<div align="center">

# ₿ bitcoin-bar for iOS

**原生、开源的 iOS 加密实时行情、OKX/币安只读仓位、强平风控与「灵动岛」实时盯盘助手**

[![Platform](https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/ios/)
[![Dynamic Island](https://img.shields.io/badge/Dynamic%20Island-ActivityKit-F59E0B)](https://developer.apple.com/documentation/activitykit)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20Charts-F05138?logo=swift&logoColor=white)](https://swift.org/)
[![Zero Backend](https://img.shields.io/badge/Architecture-Zero%20Backend%20%7C%20Keychain-22C55E)](./SECURITY.md)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

*源自 macOS 开源项目 [bitcoin-bar](https://github.com/YangPei1993/bitcoin-bar)，完整移植核心能力，并深度融合 iPhone **灵动岛（Dynamic Island）** 与 **锁屏实时活动**。*  
*抬眼看灵动岛账户余额与观测标的现价 · 零后端服务器 · 密钥全量加密存本机钥匙串*

</div>

---

## 灵动岛与锁屏实时盯盘（核心特色）

借助原生 **ActivityKit + WidgetKit**，把最关心的价格与净值直接钉在 iPhone 顶部：

| 形态 | 实时展示内容 |
| --- | --- |
| **灵动岛收起态（左药丸）** | 主观测标的实时现价（如 `● BTC $96,429`），等宽数字防跳动 |
| **灵动岛收起态（右药丸）** | **账户总余额**（如 `💼 $62.6K`）；未绑定账户或开启防窥时自动显示主标的 24h 涨跌幅 |
| **灵动岛长按展开态** | 顶部显示**总资产净值 + 合约未实现盈亏**（及 P0 强平极危红色徽章）；底部并排展示**最多 3 个自定义观测标的**的实时现价与涨跌幅 |
| **锁屏 / StandBy 待机卡片** | 深色精致金融卡片，一眼掌握账户总净值、风险告警与多币种实时行情 |

> 支持在「行情」页一键**右滑任意币种设为灵动岛主标的**，或在「设置 → 灵动岛」自由挑选最多 3 个观测标的并切换是否展示余额。防窥隐私模式同步生效。

---

## 完整功能全景（与 macOS 版 100% 对齐）

### 1. 高可用实时行情与全市场榜单
- **单连接行情中枢**：合并去重所有页面、灵动岛与风控订阅，仅维持单条 WebSocket（300ms 批量节流省电）；OKX 主源不可达自动降级 Gate.io，支持断网/切后台回前台秒级恢复。
- **全市场分组与排序**：`自选 / 热门 / 涨幅 / 跌幅 / 现货 / 合约` + 持久化自定义分组；支持全市场搜索、自选拖拽排序、左右滑动快捷操作、红涨绿跌 / 绿涨红跌自由切换。

### 2. 触屏交互式 K 线与 AI 深度解读
- **专业交互图表**：支持 **K 线蜡烛图 / 分时面积图** 切换、7 个周期、`MA7 / MA25` 均线、成交量副图、**手指按住拖动十字光标查 OHLCV** 与 24h 价格区间条。
- **AI 行情深度解读（BYOK）**：基于 24h 行情、均线量能摘要与最近 60 根 K 线，生成不限字数的结构化中文分析；内置 OpenAI、DeepSeek、通义千问、Kimi、本地 Ollama 与自定义兼容预设。

### 3. OKX & 币安只读账户：余额与合约仓位
- **多账户汇总**：同时接入多个 **OKX V5（实盘/模拟盘）** 与 **币安 Binance（现货 + U 本位永续）** 只读 API，汇总总资产（USD）与合约未实现总盈亏。
- **仓位风险高亮**：展示多/空、杠杆、逐/全仓、开仓均价、标记价、预估强平价、ROE 收益率与**强平距离警示徽章**；点击仓位卡片直达合约 K 线页，支持一键防窥隐藏（`****`）。

### 4. 主动风控预警 + 9 大强触达推送通道
- **主动风控引擎**：强平距离预警（P0 极危 / P1 预警）、单仓浮亏/ROE 预警、账户当日净值回撤预警、自选与持仓短时剧烈异动提醒，以及自定义价格提醒与余额提醒；内置**“仅首次 + 显著恶化再报”防刷屏策略**与全局静音开关。
- **9 大推送通道 + 语音告警**：支持企业微信机器人、Server酱（Turbo & Server3）、PushPlus、Bark（P0 极危突破静音强响）、飞书、钉钉、Telegram Bot、Twilio 短信、自定义 Webhook，以及 iOS 中文语音播报（`AVSpeechSynthesizer`）与触感反馈。

---

## 快速开始（Xcode 运行至真机 / 模拟器）

### 环境要求
- **Xcode 16+**（iOS 17.0+ SDK）
- 支持灵动岛的 iPhone 真机（iPhone 14 Pro 及以上，或 iOS Simulator）

### 编译与安装步骤
```bash
git clone https://github.com/YangPei1993/bitcoin-bar-ios.git
cd bitcoin-bar-ios

# 可选：若修改了 project.yml，重新生成 Xcode 工程
# brew install xcodegen && xcodegen generate

open BitcoinBarIOS.xcodeproj
```

1. 在 Xcode 中分别选中 **`BitcoinBarIOS`** 与 **`BitcoinBarLiveActivity`** 两个 Target → **Signing & Capabilities** 选择你的 Apple ID / Team（免费个人 Apple ID 即可安装到自己 iPhone 上运行 7 天）。
2. 选择你的 iPhone 真机或模拟器，按下 **`⌘R`** 即可运行。
3. 进入 App 后，点击「行情」页顶部的**“上岛”**按钮即可立即激活灵动岛实时显示！

> **关于 iOS 后台更新说明**：App 位于前台时，灵动岛以 1.5 秒节流实时同步最新价与余额；退到后台后通过 `BGAppRefreshTask` 按系统调度周期更新。受限于 iOS 沙箱策略，退后台挂起后无法保持本地长连接，如需 24 小时后台秒级推送灵动岛，可在开源基础上扩展 APNs Live Activity Push Token 服务端推送。

---

## 关联项目

- **macOS 桌面版**：[YangPei1993/bitcoin-bar](https://github.com/YangPei1993/bitcoin-bar)（菜单栏 + 毛玻璃主面板 + 桌面悬浮窗）

## 免责声明

本项目仅供行情浏览、个人资产看板与技术学习使用，所有数据与 AI 分析内容均**不构成任何投资建议**。请仅使用交易所**只读 API Key**，严禁授予交易与提币权限。

## 开源协议

基于 [MIT License](./LICENSE) 开源。
