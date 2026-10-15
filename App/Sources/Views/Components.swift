// Visual components: brand mark, codec badge, card, status dot, bitrate graph; display text for codecs and status.
import BlueBloomEngine
import SwiftUI

// MARK: - Codec display info

// Name, vendor, badge colors and "bit depth/sample rate · bitrate" all come from the codec's own declaration (A2DPCodec, pluggable); no codec is hard-coded here
struct CodecInfo {
    let id: CodecID
    let name: String
    let colors: [Color]
    let detail: String
    let vendor: String

    static func of(_ id: CodecID) -> CodecInfo {
        guard let codec = A2DPCodec.codec(id: id) else {
            return CodecInfo(id: id, name: id.rawValue, colors: [.gray, .gray], detail: "", vendor: "")
        }
        let declaration = declaration(of: codec)
        let detail = role(of: id).map { String(localized: "\(declaration) · \($0)") } ?? declaration
        return CodecInfo(id: id, name: codec.displayName, colors: codec.badgeColors.map { Color(rgb: $0.uint32Value) },
                         detail: detail, vendor: codec.vendorName)
    }

    // Highest sample rate and bit depth from the full-capability element; the bitrate is the range of the tiers (the nominal bitrate at 48k for codecs without tiers)
    private static func declaration(of codec: A2DPCodec) -> String {
        let element = codec.fullCapabilityElement
        let rates = codec.sampleRates(inCapability: element).map(\.doubleValue)
        guard let top = rates.max() else { return "" }
        let configuration = codec.configuration(forCapability: element, sampleRate: rates.contains(48000) ? 48000 : top, options: CodecOptions())
        let low = codec.presets.map(\.minimumKbps).min(), high = codec.presets.map(\.kbps).max()
        let kbps: String
        if let low, let high, low < high {
            kbps = "\(Int(low.rounded()).formatted())–" + Format.kbps(high)
        } else {
            kbps = Format.kbps(high ?? configuration?.nominalKbps ?? 0)
        }
        let rate = Format.kHz(top)
        let bits = configuration?.bitsPerSample ?? 0
        return bits > 0 ? String(localized: "\(String(bits))-bit/\(rate) · \(kbps)") : String(localized: "\(rate) · \(kbps)")
    }

    // The codec's role on macOS (the app's description, not the codec's declaration)
    private static func role(of id: CodecID) -> String? {
        switch id {
        case .aac: return String(localized: "What macOS uses by default")
        case .sbc: return String(localized: "Universal fallback every headphone supports")
        default: return nil
        }
    }

    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
}

extension Color {
    // 0xRRGGBB
    init(rgb: UInt32) {
        self.init(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Text

enum Format {
    static func kHz(_ rate: Double) -> String {
        let value = (rate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "\(value) kHz")
    }

    // Only strings are interpolated into localized text (keys always use %@); numbers are formatted for the locale first
    static func kbps(_ value: Double) -> String {
        let number = Int(value.rounded()).formatted()
        return String(localized: "\(number) kbps")
    }

    // For laying out number and unit separately: split the unit out of the localized "%@ kbps" (Korean "990kbps", German "990 kbit/s")
    static func kbpsParts(_ value: Double) -> (number: String, unit: String) {
        let number = Int(value.rounded()).formatted()
        let unit = kbps(value).replacingOccurrences(of: number, with: "").trimmingCharacters(in: .whitespaces)
        return (number, unit)
    }

    static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func milliseconds(_ value: Double) -> String {
        let number = Int(value.rounded()).formatted()
        return String(localized: "\(number) ms")
    }

    static func audioFormat(rate: Double, bits: Int) -> String {
        let rateText = kHz(rate)
        let bitsText = String(bits)
        return bits > 0 ? String(localized: "\(rateText) · \(bitsText)-bit") : rateText
    }

    // Device sample format: "48 kHz · 32-bit float", "48 kHz · 24-bit"
    static func deviceFormat(rate: Double, bits: Int, isFloat: Bool) -> String {
        guard isFloat, bits > 0 else { return audioFormat(rate: rate, bits: bits) }
        let rateText = kHz(rate)
        let bitsText = String(bits)
        return String(localized: "\(rateText) · \(bitsText)-bit float")
    }

    static func codecName(_ id: CodecID?) -> String {
        id.map { CodecInfo.of($0).name } ?? "—"
    }
}

extension CodecFallbackReason {
    func text(codec: String) -> String {
        switch self {
        case .unsupportedRate: return String(localized: "\(codec) doesn't support this sample rate")
        case .encoderUnavailable: return String(localized: "\(codec) encoder couldn't start")
        case .rejected: return String(localized: "The headphones declined \(codec)")
        case .encoderFailed: return String(localized: "\(codec) stopped after an encoder error")
        case .endpointBusy: return String(localized: "\(codec) is in use by another device")
        default: return ""
        }
    }
}

// MARK: - Components

// Brand mark: the app icon itself (App/AppIcon.icon, rendered by macOS). The icon artwork fills 824 of its 1024-point
// canvas, so it is drawn larger than the frame to make the visible rounded square `size` wide; the margin is transparent
struct BloomMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
    }
}

struct CodecBadge: View {
    let codec: CodecID
    var compact = false
    var dimmed = false

    var body: some View {
        let info = CodecInfo.of(codec)
        Text(info.name)
            .font(.system(size: compact ? 9.5 : 11, weight: .semibold, design: .rounded))
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1.5 : 3)
            .background {
                Capsule().fill(dimmed ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(info.gradient))
            }
            .fixedSize()
    }
}

// Content is clipped to the rounded corners: content that should fill to the edges (the bitrate graph at the bottom of the streaming card) uses negative padding to reach them
struct Card<Content: View>: View {
    static var padding: CGFloat { 12 }
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(phase ? 2.2 : 1)
                        .opacity(phase ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: phase)
                        .onAppear { phase = true }
                }
            }
    }
}

// Headphone battery: one item for the whole unit; AirPods and the like show left earbud, right earbud and charging case separately (matching Control Center). compact shows only the lowest one
// Icon plus text: the icon sits right next to the text, aligned to the text baseline (the first line when multiline). The system Label spaces them too widely in the menu panel, so icon and value look like two separate things
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

// Battery: in the card, an icon and percentage per item; compact (device list) shows only a battery icon drawn for the lowest level, with the values in the tooltip
struct BatteryView: View {
    let levels: BatteryLevels
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if compact {
                if let lowest = levels.lowest {
                    Image(systemName: Self.symbol(lowest))
                        .foregroundStyle(lowest <= 20 ? .red : .secondary)
                        .help(Text(verbatim: details))
                        .accessibilityLabel(Text(verbatim: details))
                }
            } else {
                if let main = levels.main { item(main, symbol: Self.symbol(main), help: "Battery") }
                if let left = levels.left { item(left, symbol: "airpod.left", help: "Left earbud") }
                if let right = levels.right { item(right, symbol: "airpod.right", help: "Right earbud") }
                if let level = levels.caseLevel { item(level, symbol: "airpods.chargingcase", help: "Charging case") }
            }
        }
        .font(.system(size: compact ? 10.5 : 11, weight: .medium))
        .fixedSize()
    }

    // "Battery 80%" or "Left earbud 80% · Right earbud 75% · Charging case 40%"
    private var details: String {
        var parts: [String] = []
        if let main = levels.main { parts.append(String(localized: "Battery") + " " + Format.percent(main)) }
        if let left = levels.left { parts.append(String(localized: "Left earbud") + " " + Format.percent(left)) }
        if let right = levels.right { parts.append(String(localized: "Right earbud") + " " + Format.percent(right)) }
        if let level = levels.caseLevel { parts.append(String(localized: "Charging case") + " " + Format.percent(level)) }
        return parts.joined(separator: " · ")
    }

    private func item(_ percent: Int, symbol: String, help: LocalizedStringKey) -> some View {
        Label(Format.percent(percent), systemImage: symbol)
            .labelStyle(.compact)
            .monospacedDigit()
            .foregroundStyle(percent <= 20 ? .red : .secondary)
            .help(Text(help))
    }

    static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// Bitrate graph: the last 60 seconds
struct Sparkline: View {
    let values: [Double]
    let colors: [Color]

    var body: some View {
        GeometryReader { geometry in
            // Scale the vertical axis to this data's range so fluctuations are visible; all zeros (paused) sit at the bottom
            let high = max(values.max() ?? 0, 1)
            let low = min(values.min() ?? 0, high) * 0.8
            let span = max(high * 1.08 - low, 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: geometry.size.width * CGFloat(index) / CGFloat(max(AppModel.historyLength - 1, 1)),
                        y: geometry.size.height * (1 - CGFloat((value - low) / span)))
            }
            let offset = geometry.size.width - (points.last?.x ?? geometry.size.width)
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x + offset, y: geometry.size.height))
                    for point in points { path.addLine(to: CGPoint(x: point.x + offset, y: point.y)) }
                    path.addLine(to: CGPoint(x: (points.last?.x ?? 0) + offset, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: colors.map { $0.opacity(0.28) } + [.clear], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x + offset, y: first.y))
                    for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x + offset, y: point.y)) }
                }
                .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.title = title
        self.trailing = EmptyView()
    }
}

// A button row in the menu: icon + text, highlighted on hover
struct MenuRowButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).font(.system(size: 11)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
