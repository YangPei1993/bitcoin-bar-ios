import SwiftUI

// MARK: - 数值与时间格式化

nonisolated enum MarketFormatter {
    private static let lock = NSLock()
    private static var formatters: [Int: NumberFormatter] = [:]

    /// 按价格量级自动选择合适的小数位，兼顾比特币与小币种可读性
    static func price(_ value: Double, includeSymbol: Bool = true) -> String {
        guard value.isFinite else { return includeSymbol ? "$--" : "--" }

        let absValue = abs(value)
        let fractionDigits: Int
        if absValue >= 1_000 {
            fractionDigits = 2
        } else if absValue >= 1 {
            fractionDigits = 2
        } else if absValue >= 0.01 {
            fractionDigits = 4
        } else if absValue >= 0.0001 {
            fractionDigits = 6
        } else if absValue > 0 {
            fractionDigits = 8
        } else {
            fractionDigits = 2
        }

        let formatted = decimalString(value, minDigits: min(fractionDigits, 2), maxDigits: fractionDigits)
        return includeSymbol ? "$\(formatted)" : formatted
    }

    /// 菜单栏价格格式化：支持完整精确格式与紧凑 K/M 格式
    static func menuBarPrice(_ value: Double, compact: Bool) -> String {
        guard value.isFinite else { return "--" }

        let absValue = abs(value)
        if compact && absValue >= 10_000 {
            return "$\(decimalString(value / 1_000, minDigits: 1, maxDigits: 1))K"
        }
        if absValue >= 10_000 {
            return "$\(decimalString(value, minDigits: 0, maxDigits: 0))"
        }
        if absValue >= 100 {
            return "$\(decimalString(value, minDigits: 1, maxDigits: 1))"
        }
        return price(value, includeSymbol: true)
    }

    /// 涨跌幅格式化（含正负号）
    static func changePercent(_ value: Double, digits: Int = 2) -> String {
        guard value.isFinite else { return "--" }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.\(digits)f", value))%"
    }

    /// 涨跌额格式化
    static func changeAmount(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let sign = value > 0 ? "+" : (value < 0 ? "-" : "")
        return "\(sign)\(price(abs(value), includeSymbol: true))"
    }

    /// 紧凑大数格式（成交量 / 成交额）
    static func compactVolume(_ value: Double, isCurrency: Bool = false) -> String {
        guard value.isFinite else { return "--" }
        let prefix = isCurrency ? "$" : ""
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""

        if absValue >= 1_000_000_000 {
            return "\(sign)\(prefix)\(String(format: "%.2fB", absValue / 1_000_000_000))"
        }
        if absValue >= 1_000_000 {
            return "\(sign)\(prefix)\(String(format: "%.2fM", absValue / 1_000_000))"
        }
        if absValue >= 1_000 {
            return "\(sign)\(prefix)\(String(format: "%.2fK", absValue / 1_000))"
        }
        return "\(sign)\(prefix)\(String(format: "%.2f", absValue))"
    }

    /// 简短时间戳 HH:mm:ss
    static func clockTime(_ date: Date) -> String {
        lock.withLock {
            clockFormatter.string(from: date)
        }
    }

    /// K 线十字光标时间
    static func chartTimestamp(_ date: Date, interval: KlineInterval) -> String {
        lock.withLock {
            switch interval {
            case .oneDay, .oneWeek:
                return dateOnlyFormatter.string(from: date)
            default:
                return dateTimeFormatter.string(from: date)
            }
        }
    }

    private static func decimalString(_ value: Double, minDigits: Int, maxDigits: Int) -> String {
        let key = minDigits * 16 + maxDigits
        return lock.withLock {
            let formatter: NumberFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                let created = NumberFormatter()
                created.locale = Locale(identifier: "en_US_POSIX")
                created.numberStyle = .decimal
                created.usesGroupingSeparator = true
                created.groupingSeparator = ","
                created.minimumFractionDigits = minDigits
                created.maximumFractionDigits = maxDigits
                formatters[key] = created
                formatter = created
            }
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(maxDigits)f", value)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - 视觉设计系统与币种徽章

enum MarketColors {
    static let green = Color(red: 0.13, green: 0.74, blue: 0.45)
    static let red = Color(red: 0.93, green: 0.30, blue: 0.34)
    static let neutral = Color.secondary
}

/// 精致的币种圆形图标，常见主流币使用品牌色，其余基于代码哈希生成稳定渐变
struct CoinAvatar: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        let palette = Self.palette(for: symbol)
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [palette.0, palette.1],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)

            Text(monogram)
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .shadow(color: palette.1.opacity(0.22), radius: 2, y: 1)
    }

    private var monogram: String {
        switch symbol.uppercased() {
        case "BTC": return "₿"
        case "ETH": return "Ξ"
        default:
            return String(symbol.uppercased().prefix(symbol.count <= 3 ? 3 : 2))
        }
    }

    private var fontSize: CGFloat {
        switch monogram.count {
        case 1: return size * 0.54
        case 2: return size * 0.39
        default: return size * 0.30
        }
    }

    private static func palette(for symbol: String) -> (Color, Color) {
        switch symbol.uppercased() {
        case "BTC":
            return (Color(red: 0.99, green: 0.64, blue: 0.16), Color(red: 0.91, green: 0.44, blue: 0.05))
        case "ETH":
            return (Color(red: 0.44, green: 0.52, blue: 0.96), Color(red: 0.30, green: 0.36, blue: 0.82))
        case "SOL":
            return (Color(red: 0.56, green: 0.34, blue: 0.96), Color(red: 0.11, green: 0.78, blue: 0.68))
        case "BNB":
            return (Color(red: 0.96, green: 0.78, blue: 0.18), Color(red: 0.84, green: 0.60, blue: 0.05))
        case "XRP":
            return (Color(red: 0.24, green: 0.31, blue: 0.42), Color(red: 0.13, green: 0.17, blue: 0.24))
        case "DOGE":
            return (Color(red: 0.86, green: 0.70, blue: 0.26), Color(red: 0.72, green: 0.54, blue: 0.14))
        case "ADA":
            return (Color(red: 0.16, green: 0.45, blue: 0.88), Color(red: 0.08, green: 0.27, blue: 0.66))
        case "TRX":
            return (Color(red: 0.93, green: 0.26, blue: 0.28), Color(red: 0.72, green: 0.12, blue: 0.18))
        case "TON":
            return (Color(red: 0.14, green: 0.67, blue: 0.96), Color(red: 0.05, green: 0.48, blue: 0.84))
        case "AVAX":
            return (Color(red: 0.93, green: 0.28, blue: 0.29), Color(red: 0.76, green: 0.14, blue: 0.19))
        case "SUI":
            return (Color(red: 0.31, green: 0.66, blue: 0.98), Color(red: 0.16, green: 0.44, blue: 0.86))
        case "LINK":
            return (Color(red: 0.24, green: 0.46, blue: 0.94), Color(red: 0.14, green: 0.28, blue: 0.72))
        case "PEPE":
            return (Color(red: 0.28, green: 0.72, blue: 0.31), Color(red: 0.15, green: 0.52, blue: 0.20))
        case "UNI":
            return (Color(red: 0.98, green: 0.28, blue: 0.58), Color(red: 0.78, green: 0.12, blue: 0.42))
        case "OKB":
            return (Color(red: 0.22, green: 0.24, blue: 0.28), Color(red: 0.10, green: 0.11, blue: 0.14))
        default:
            var hash: UInt64 = 5381
            for byte in symbol.uppercased().utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            let hue = Double(hash % 360) / 360.0
            let secondaryHue = (hue + 0.07).truncatingRemainder(dividingBy: 1.0)
            return (
                Color(hue: hue, saturation: 0.62, brightness: 0.82),
                Color(hue: secondaryHue, saturation: 0.70, brightness: 0.62)
            )
        }
    }
}
