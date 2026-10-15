// Menu bar popover panel: title and master switch, items needing attention, now-playing card, device list, sound output, footer actions.
import BlueBloomEngine
import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var showsCard: Bool { model.settings.enabled && model.activeDevice != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SetupCard()
            if showsCard {
                NowPlayingCard()
            }
            DeviceList()
            OutputRow()
            Divider().padding(.horizontal, 4)
            footer
        }
        .padding(12)
        .frame(width: 348)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BloomMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Blue Bloom").font(.system(size: 14, weight: .semibold))
                // When the card is shown it already states the headphones, status and codec; only without the card (off, not authorized, no headphones chosen, etc.) is it explained here
                if !showsCard {
                    // French and German don't fit on one line ("Schließe die Einrichtung ab, um zu starten"); allow two lines
                    Text(model.headline).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle(isOn: Binding(get: { model.settings.enabled }, set: { model.setEnabled($0) })) {
                Text("Enable Blue Bloom")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(Text("Turn Blue Bloom on or off. When off, macOS handles your headphones."))
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRowButton(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            MenuRowButton(title: "Quit Blue Bloom", symbol: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

extension AppModel {
    // The line below the title
    var headline: String {
        guard settings.enabled else { return String(localized: "Off — macOS handles your headphones") }
        if bluetoothDenied { return String(localized: "Bluetooth access is off for Blue Bloom") }
        if !bluetoothReady { return String(localized: "Waiting for Bluetooth permission…") }
        guard devices.bluetoothOn else { return String(localized: "Bluetooth is off") }
        if driverState != .current { return String(localized: "Finish setup to start") }
        guard let device = activeDevice else { return String(localized: "Choose your headphones below") }
        let name = device.name
        switch status {
        case .streaming:
            let codec = Format.codecName(configuration?.codec)
            return String(localized: "Streaming \(codec) to \(name)")
        case .idle: return String(localized: "\(name) · paused while silent")
        case .connecting: return String(localized: "Connecting to \(name)…")
        case .waitingHeadset: return String(localized: "Waiting for \(name)…")
        case .retrying: return String(localized: "Reconnecting to \(name)…")
        case .busy: return String(localized: "\(name) is in use by another device")
        case .system: return String(localized: "\(name) is using macOS Bluetooth audio")
        default:
            return String(localized: "Ready")
        }
    }
}

// MARK: - Items needing user action (driver, Bluetooth, headphones, sound output)

struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = steps
        if !items.isEmpty {
            Card {
                Label {
                    Text("Finish setting up").font(.system(size: 12, weight: .semibold))
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.blue)
                }
                .labelStyle(.compact)
                ForEach(items, id: \.id) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.symbol).foregroundStyle(step.tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(step.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if let action = step.action {
                            Button(step.button, action: action)
                                .controlSize(.small)
                                .disabled(model.installingDriver && step.id == "driver")
                        }
                    }
                }
            }
        }
    }

    private struct Step {
        let id: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let symbol: String
        let tint: Color
        var button: LocalizedStringKey = ""
        var action: (() -> Void)?
    }

    private var steps: [Step] {
        var steps: [Step] = []
        // The headphones aren't taken over until these two are resolved (AppModel startController)
        if model.noticePending {
            steps.append(Step(id: "notice", title: "Read before you start",
                              detail: "Blue Bloom takes your headphones over from macOS while it streams. See what that means.",
                              symbol: "info.circle", tint: .blue, button: "Read…", action: model.openWelcome))
        }
        if model.systemUntested {
            steps.append(Step(id: "system", title: "Not tested on macOS \(Compatibility.versionText)",
                              detail: "Blue Bloom relies on private macOS interfaces that can change between versions. Until you try it, macOS keeps your headphones.",
                              symbol: "exclamationmark.triangle", tint: .orange, button: "Try Anyway", action: model.allowUntestedSystem))
        }
        if model.bluetoothDenied {
            steps.append(Step(id: "permission", title: "Allow Bluetooth access",
                              detail: "Turn on Blue Bloom in Privacy & Security › Bluetooth, then reopen it.",
                              symbol: "hand.raised", tint: .red, button: "Open…", action: model.openBluetoothPrivacy))
        } else if !model.bluetoothReady {
            steps.append(Step(id: "permission", title: "Allow Bluetooth access",
                              detail: "Click Allow in the system prompt so Blue Bloom can reach your headphones.",
                              symbol: "hand.raised", tint: .orange))
        }
        if model.bluetoothReady && !model.devices.bluetoothOn {
            steps.append(Step(id: "bluetooth", title: "Turn on Bluetooth", detail: "Blue Bloom needs Bluetooth to reach your headphones.",
                              symbol: "antenna.radiowaves.left.and.right.slash", tint: .orange, button: "Open…",
                              action: model.openBluetoothSettings))
        }
        switch model.driverState {
        case .missing:
            steps.append(Step(id: "driver", title: "Install the Blue Bloom audio device",
                              detail: "Apps play into it and Blue Bloom streams it to your headphones. Requires an administrator password.",
                              symbol: "hifispeaker.badge.plus", tint: .blue, button: "Install", action: model.installDriver))
        case .outdated:
            steps.append(Step(id: "driver", title: "Update the Blue Bloom audio device",
                              detail: "A newer version comes with this app. Requires an administrator password.",
                              symbol: "arrow.down.circle", tint: .blue, button: "Update", action: model.installDriver))
        case .current:
            break
        }
        if model.settings.enabled, model.activeDevice == nil {
            steps.append(Step(id: "device", title: "Pick your headphones", detail: "Click a device below, or add new headphones.",
                              symbol: "headphones", tint: .purple))
        }
        if model.driverState == .current, model.isConnected, !model.blueBloomIsOutput, !model.settings.autoSwitchOutput {
            steps.append(Step(id: "output", title: "Send sound to Blue Bloom", detail: "Select Blue Bloom as the sound output.",
                              symbol: "speaker.wave.2", tint: .green, button: "Use", action: model.useBlueBloomOutput))
        }
        return steps
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.07))
                    Image(systemName: model.activeDevice?.symbol ?? "headphones").font(.system(size: 15))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    // Long names may take two lines and are truncated in the middle beyond that: names like "Someone's AirPods Pro #2 - Find My" differ only at the end and can't be told apart if the tail is cut
                    Text(model.activeDevice?.name ?? "").font(.system(size: 13, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                        .help(Text(verbatim: model.activeDevice?.name ?? ""))
                    HStack(spacing: 5) {
                        StatusDot(color: statusColor, pulsing: model.status == .connecting || model.status == .waitingHeadset)
                        Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(Text(verbatim: statusHelp))
                }
                Spacer()
                if let levels = model.activeBattery, levels.partCount == 1 {
                    BatteryView(levels: levels)
                }
            }
            // Separately reported left earbud, right earbud and charging case go on their own line so they don't crowd out the name and status
            if let levels = model.activeBattery, levels.partCount > 1 {
                BatteryView(levels: levels).padding(.leading, 44)
            }
            if let hint = connectionHint {
                Label {
                    Text(hint).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .labelStyle(.compact)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if model.canRetryNow {
                RetryRow()
            }
            if let configuration = model.configuration, model.isConnected {
                streamDetails(configuration)
            } else {
                CodecPicker()
            }
        }
    }

    // Stream details: spaced a bit from the headphone info above; the codec and format row (the whole row is a menu), notices, the bitrate figure, and the bitrate graph filling the card's bottom edge and sides as its base
    @ViewBuilder
    private func streamDetails(_ configuration: CodecConfiguration) -> some View {
        let info = CodecInfo.of(configuration.codec)
        let showsFallback = model.fallbackCodec != nil && model.fallbackReason != .none
        let showsVolume = model.isStreaming && model.remoteControlBlocked && model.settings.volumeSync
        VStack(alignment: .leading, spacing: 12) {
            StreamFormatMenu(configuration: configuration)
            // Notices are grouped, with tighter spacing inside the group
            if showsFallback || showsVolume {
                VStack(alignment: .leading, spacing: 6) {
                    if showsFallback, let fallback = model.fallbackCodec {
                        Label {
                            Text(model.fallbackReason.text(codec: Format.codecName(fallback)))
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .labelStyle(.compact)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if showsVolume {
                    Label("Headphone volume isn't synced with the Mac", systemImage: "speaker.badge.exclamationmark")
                        .labelStyle(.compact)
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .help(Text("macOS is holding the headphones' remote control channel, so the Mac volume is applied in software on top of the headphones' own volume. If it sounds too quiet, turn up the headphones. Blue Bloom keeps retrying and this goes away once it gets the channel."))
                }
                }
            }
            // Right of the bitrate figure: the virtual device's format (apps hand their audio to Blue Bloom in this format; the codec row above is the format streamed to the headphones).
            // It doesn't fit after the status under the name, where "32-bit float" gets cut off
            HStack(alignment: .firstTextBaseline) {
                BitrateFigure(kbps: model.isStreaming ? model.liveKbps : nil)
                Spacer()
                if let deviceFormat {
                    Text(verbatim: String(localized: "Device \(deviceFormat)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .help(Text(verbatim: formatHelp.joined(separator: "\n")))
                }
            }
        }
        .padding(.top, 6)
        Sparkline(values: model.bitrateHistory, colors: info.colors)
            .frame(height: 40)
            .opacity(model.isStreaming ? 1 : 0.35)
            .padding(.horizontal, -Card<EmptyView>.padding)
            .padding(.bottom, -Card<EmptyView>.padding)
    }

    private var deviceFormat: String? {
        guard model.isStreaming, model.deviceRate > 0 else { return nil }
        return Format.deviceFormat(rate: model.deviceRate, bits: model.deviceBitDepth, isFloat: model.deviceFloat)
    }

    // Format chain: source (when following the source and Apple Music is playing) → virtual output device, and why the two differ
    private var formatHelp: [String] {
        var lines: [String] = []
        if model.settings.sampleRateMode == .followSource, model.sourceRate > 0, model.isStreaming {
            let source = Format.audioFormat(rate: model.sourceRate, bits: model.sourceBitDepth)
            lines.append(String(localized: "Source: \(source) (Apple Music)"))
        }
        if let deviceFormat { lines.append(String(localized: "Virtual output device: \(deviceFormat)")) }
        if let note = model.resampleNote, model.isStreaming {
            let codec = Format.codecName(model.configuration?.codec)
            let source = Format.kHz(note.source)
            let rate = Format.kHz(note.rate)
            if model.settings.maxSampleRate > 0, note.source > model.settings.maxSampleRate {
                lines.append(String(localized: "Limited by Maximum sample rate, so macOS resamples to \(rate)."))
            } else {
                lines.append(String(localized: "\(codec) doesn't support \(source), so macOS resamples to \(rate)."))
            }
        }
        return lines
    }

    // Status tooltip: format chain and the playback delay reported by the headphones
    private var statusHelp: String {
        var lines = formatHelp
        if model.isStreaming, model.headsetDelay > 0 {
            lines.append(String(localized: "Playback delay reported by the headphones: \(Format.milliseconds(model.headsetDelay))"))
        }
        return lines.joined(separator: "\n")
    }

    private var statusText: String {
        switch model.status {
        case .streaming: return String(localized: "Streaming")
        case .idle: return String(localized: "Connected · paused while silent")
        case .connecting: return String(localized: "Connecting…")
        case .waitingHeadset: return String(localized: "Waiting for the headphones")
        case .retrying: return String(localized: "Reconnecting…")
        case .busy: return String(localized: "In use by another device")
        case .system: return String(localized: "Connected through macOS")
        default: return String(localized: "Not connected")
        }
    }

    // When it can't connect, explain why and what to do
    private var connectionHint: LocalizedStringKey? {
        switch model.status {
        // No answer to paging: powered off, or single-connection headphones currently connected to a phone (same when multipoint is full)
        case .waitingHeadset:
            return "The headphones aren't answering. They may be off, or connected only to another device such as your phone — disconnect them there."
        // Connected, but the headphones refuse to set up a stream: multipoint headphones are giving their audio to another device
        case .busy:
            return "The headphones are playing from another device, such as your phone. Pause or disconnect it there, then retry."
        default:
            return nil
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .streaming: return .green
        case .idle: return .mint
        case .connecting, .waitingHeadset, .retrying, .busy: return .orange
        case .system: return .blue
        default: return .gray
        }
    }
}

// Bitrate figure: large number, small dimmed unit; nil means paused
struct BitrateFigure: View {
    let kbps: Double?

    var body: some View {
        if let kbps {
            let parts = Format.kbpsParts(kbps)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: parts.number)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(verbatim: parts.unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        } else {
            Text("Paused").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

// Countdown to the next automatic reconnect + Retry Now
struct RetryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let next = model.nextAttempt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                    Text("Retrying in \(String(seconds)) s")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button("Retry Now") { model.retryNow() }
                .controlSize(.small)
        }
    }
}

// Which codec the current headphones use: automatic (best by priority) or a chosen one
// The "Codec" row when not streaming: choose a codec for these headphones (while streaming, the codec badge menu replaces it)
struct CodecPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let address = model.settings.activeDevice {
            let record = model.devices.record(address)
            HStack(spacing: 6) {
                Text("Codec").font(.system(size: 11)).foregroundStyle(.secondary)
                Menu {
                    CodecChoices(address: address)
                } label: {
                    Text(record.preferredCodec.map { CodecInfo.of($0).name } ?? String(localized: "Automatic"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .font(.system(size: 11))
        }
    }
}

// The codec and format row while streaming: "[codec badge] 48 kHz · 24-bit · Adaptive ⌄"; the second half is one menu with "Codec" and "Bitrate" groups,
// instead of separate pop-ups next to the badge and next to the bitrate
struct StreamFormatMenu: View {
    @Environment(AppModel.self) private var model
    let configuration: CodecConfiguration

    var body: some View {
        let codec = configuration.codec
        let format = Format.audioFormat(rate: configuration.sampleRate, bits: Int(configuration.bitsPerSample))
        let summary = [format, bitrateSummary].compactMap { $0 }.joined(separator: " · ")
        // The colored badge is display only; the menu uses the system borderless style (the system draws the arrow, same as the tier menu that worked before).
        // On 2026-10-14 the badge was put into the menu label with .menuStyle(.button) + .buttonStyle(.plain) to keep its colors, and clicking options had no effect
        // (no option change at all in the log); presumably the plain style propagated to the menu's items
        HStack(spacing: 8) {
            CodecBadge(codec: codec)
            Menu {
                if let address = model.settings.activeDevice {
                    CodecChoices(address: address)
                }
                BitrateChoices(codec: codec)
            } label: {
                Text(verbatim: summary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // Short name of the bitrate tier ("Adaptive", "990 kbps", "XQ"); none for fixed-bitrate codecs
    private var bitrateSummary: String? {
        let settings = model.settings
        let context = QualityContext(rate: configuration.sampleRate, maxKbps: model.activeRecord?.maxKbps[configuration.codec.rawValue] ?? 0)
        if let codec = A2DPCodec.codec(id: configuration.codec), let preset = settings.preset(for: codec) {
            return preset.shortTitle(context)
        }
        switch configuration.codec {
        case .aac:
            return settings.aacAdaptive ? String(localized: "Adaptive") : Format.kbps(Double(settings.aacBitrate > 0 ? settings.aacBitrate / 1000 : 320))
        case .sbc: return settings.sbcAdaptive ? String(localized: "Adaptive") : settings.sbcXQ ? "XQ" : String(localized: "Standard")
        default: return nil
        }
    }
}

// Codec choice: automatic or a chosen one. Uses a system single choice (inline Picker) so the system draws the checkmark; with "button + checkmark icon" the checkmark didn't show in a grouped menu (2026-10-14)
struct CodecChoices: View {
    @Environment(AppModel.self) private var model
    let address: String

    var body: some View {
        let record = model.devices.record(address)
        let available = model.availableCodecs
        Picker(selection: Binding(get: { record.preferredCodec }, set: { model.setPreferredCodec($0, for: address) })) {
            Text("Automatic (best available)").tag(CodecID?.none)
            ForEach(available, id: \.self) { codec in
                Text(verbatim: CodecInfo.of(codec).name).tag(CodecID?.some(codec))
            }
        } label: {
            Text("Codec")
        }
        .pickerStyle(.inline)
        if available.isEmpty {
            Text("Codecs appear after the first connection")
        }
    }
}

// Bitrate options for the current codec (inside StreamFormatMenu): codecs that declare bitrate tiers list them by tier; AAC and SBC have their own settings; none for fixed-bitrate codecs
struct BitrateChoices: View {
    @Environment(AppModel.self) private var model
    let codec: CodecID

    var body: some View {
        let context = QualityContext(rate: model.configuration?.sampleRate ?? 0, maxKbps: model.activeRecord?.maxKbps[codec.rawValue] ?? 0)
        if let declared = A2DPCodec.codec(id: codec), !declared.presets.isEmpty {
            QualityChoices(codec: declared, context: context)
        } else if codec == .aac {
            AACChoices()
        } else if codec == .sbc {
            SBCChoices()
        }
    }
}

// Codec-declared bitrate tiers: shows the bitrate this stream would actually use (the codec's declared rate for the sample-rate family, capped at the limit recorded for these headphones;
// Settings is global and shows nominal values)
struct QualityChoices: View {
    @Environment(AppModel.self) private var model
    let codec: A2DPCodec
    var context = QualityContext()

    var body: some View {
        let settings = model.settings
        let presets = codec.presets
        Picker(selection: Binding(get: { settings.preset(for: codec)?.identifier ?? codec.defaultPresetID },
                                  set: { settings.codecPresets[codec.identifier] = $0; model.codecSettingsChanged() })) {
            ForEach(presets, id: \.identifier) { preset in
                Text(verbatim: preset.title(in: presets, context: context)).tag(preset.identifier)
            }
        } label: {
            Text("\(codec.displayName) quality")
        }
        .pickerStyle(.inline)
    }
}

// Context for displaying bitrate tiers: sample rate (0 means unspecified) and the limit recorded for these headphones (0 means none)
struct QualityContext {
    var rate: Double = 0
    var maxKbps: Double = 0
}

// AAC and SBC bitrate has two layers: the adaptive switch plus a bitrate tier (a cap while adaptive is on, with the subtitle changing to "Maximum bitrate"),
// the same settings as the options of the same name under Settings "Codecs". AAC's 320 tier is "automatic" in Settings: the lowest of 320k, the headphones' declared bitrate and what fits the MTU
struct AACChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        Toggle("Adaptive bitrate", isOn: Binding(get: { settings.aacAdaptive }, set: { settings.aacAdaptive = $0; model.codecSettingsChanged() }))
        Picker(selection: Binding(get: { settings.aacBitrate }, set: { settings.aacBitrate = $0; model.codecSettingsChanged() })) {
            Text(verbatim: Format.kbps(320)).tag(0)
            Text(verbatim: Format.kbps(256)).tag(256_000)
            Text(verbatim: Format.kbps(192)).tag(192_000)
            Text(verbatim: Format.kbps(128)).tag(128_000)
        } label: {
            Text(settings.aacAdaptive ? "Maximum bitrate" : "Bitrate")
        }
        .pickerStyle(.inline)
    }
}

struct SBCChoices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        Toggle("Adaptive bitrate", isOn: Binding(get: { settings.sbcAdaptive }, set: { settings.sbcAdaptive = $0; model.codecSettingsChanged() }))
        Picker(selection: Binding(get: { settings.sbcXQ }, set: { settings.sbcXQ = $0; model.codecSettingsChanged() })) {
            Text("Standard (about 330 kbps)").tag(false)
            Text("SBC XQ (dual channel, about 500 kbps)").tag(true)
        } label: {
            Text(settings.sbcAdaptive ? "Maximum bitrate" : "Bitrate")
        }
        .pickerStyle(.inline)
    }
}

extension CodecPreset {
    // Bitrate this stream would actually use: by sample-rate family, capped at the limit recorded for these headphones (nominal value when the context is empty); nil for the adaptive tier
    func effectiveKbps(_ context: QualityContext) -> Double? {
        guard !isAdaptive else { return nil }
        let nominal = kbps(atSampleRate: context.rate)
        return context.maxKbps > 0 ? min(nominal, context.maxKbps) : nominal
    }

    // Tiers in the codec's declared order: adaptive, highest, middle…, lowest
    func title(in presets: [CodecPreset], context: QualityContext = QualityContext()) -> String {
        guard let kbps = effectiveKbps(context) else { return String(localized: "Adaptive (best effort)") }
        let value = Format.kbps(kbps)
        let fixed = presets.filter { !$0.isAdaptive }.map(\.identifier)
        if fixed.first == identifier { return String(localized: "Quality · \(value)") }
        if fixed.last == identifier { return String(localized: "Connection · \(value)") }
        return String(localized: "Balanced · \(value)")
    }

    func shortTitle(_ context: QualityContext = QualityContext()) -> String {
        effectiveKbps(context).map(Format.kbps) ?? String(localized: "Adaptive")
    }
}

// MARK: - Device list

struct DeviceList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Headphones") {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "pairing")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(Text("Add headphones"))
            }
            if model.devices.devices.isEmpty {
                Text("No paired Bluetooth headphones yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 6)
            }
            ForEach(model.devices.devices) { device in
                DeviceRow(device: device)
            }
        }
    }
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: BluetoothDevice
    @State private var hovering = false

    var body: some View {
        let record = model.devices.record(device.address)
        let active = device.address == model.settings.activeDevice
        Button {
            model.activate(device)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(active ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.06))))
                    .foregroundStyle(active ? Color.accentColor : .primary)
                // The name gets width first, so the Spacer doesn't take half of it and truncate it to "WH-10…"
                VStack(alignment: .leading, spacing: 3) {
                    // Truncate in the middle (keeping distinguishing tails like "#2 - Find My"); hovering shows the full name
                    Text(device.name).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                        .help(Text(verbatim: device.name))
                    if record.codecs.isEmpty {
                        Text(subtitle(record: record, active: active)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } else {
                        // Codec badges can't shrink; when they don't fit, show fewer from the low-priority end, otherwise the row widens the panel and shifts all content left
                        let codecs = chips(record)
                        ViewThatFits(in: .horizontal) {
                            ForEach((0...codecs.count).reversed(), id: \.self) { count in
                                badges(Array(codecs.prefix(count)), record: record, active: active)
                            }
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if device.isConnected, let levels = model.battery(for: device) {
                    BatteryView(levels: levels, compact: true)
                }
                if active {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { DeviceMenu(address: device.address) }
    }

    private func badges(_ codecs: [CodecID], record: DeviceRecord, active: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(codecs, id: \.self) { codec in
                CodecBadge(codec: codec, compact: true, dimmed: !(active && model.configuration?.codec == codec))
            }
            if record.mode == .system {
                Label("macOS", systemImage: "apple.logo")
                    .labelStyle(.compact)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                    .help(Text("Handled by macOS"))
            }
        }
    }

    private func chips(_ record: DeviceRecord) -> [CodecID] {
        let supported = Set(record.codecs.compactMap(\.codec))
        return model.settings.codecPriority.filter(supported.contains)
    }

    private func subtitle(record: DeviceRecord, active: Bool) -> String {
        if record.mode == .system { return String(localized: "Handled by macOS") }
        return device.isConnected ? String(localized: "Connected") : String(localized: "Not connected")
    }
}

// Device context menu: connection mode, preferred codec, clear cache
struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    let address: String

    var body: some View {
        let record = model.devices.record(address)
        Picker(selection: Binding(get: { record.mode }, set: { model.setMode($0, for: address) })) {
            Text("Automatic").tag(DeviceMode.automatic)
            Text("Always use Blue Bloom").tag(DeviceMode.always)
            Text("Leave to macOS").tag(DeviceMode.system)
        } label: {
            Text("Connection")
        }
        let supported = model.settings.codecPriority.filter(Set(record.codecs.compactMap(\.codec)).contains)
        Picker(selection: Binding(get: { record.preferredCodec }, set: { model.setPreferredCodec($0, for: address) })) {
            Text("Automatic").tag(CodecID?.none)
            ForEach(supported, id: \.self) { codec in
                Text(verbatim: CodecInfo.of(codec).name).tag(CodecID?.some(codec))
            }
        } label: {
            Text("Preferred codec")
        }
        Divider()
        Button("Forget Detected Codecs") { model.devices.forgetCodecs(for: address) }
        Button("Bluetooth Settings…") { model.openBluetoothSettings() }
    }
}

// MARK: - Sound output

struct OutputRow: View {
    @Environment(AppModel.self) private var model

    // Nothing to say when the output is already Blue Bloom; only shown when it isn't, as a reminder with a switch button
    var body: some View {
        if model.driverState == .current, !model.blueBloomIsOutput {
            HStack(spacing: 8) {
                Image(systemName: model.blueBloomIsOutput ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .foregroundStyle(model.blueBloomIsOutput ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sound Output").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.outputName ?? "—").font(.system(size: 12)).lineLimit(1)
                }
                Spacer()
                if !model.blueBloomIsOutput {
                    Button("Use Blue Bloom") { model.useBlueBloomOutput() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
