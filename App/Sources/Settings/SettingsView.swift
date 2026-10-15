// Settings window: General, Codecs, Audio, Devices, Advanced, About.
import BlueBloomEngine
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            CodecsPane().tabItem { Label("Codecs", systemImage: "waveform") }
            AudioPane().tabItem { Label("Audio", systemImage: "hifispeaker") }
            DevicesPane().tabItem { Label("Devices", systemImage: "headphones") }
            AdvancedPane().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutPane().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.enabled }, set: { model.setEnabled($0) })) {
                    Text("Enable Blue Bloom")
                    Text("When off, macOS connects your headphones with its own AAC/SBC.")
                }
                Toggle(isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) })) {
                    Text("Open at login")
                }
            }
            Section {
                Toggle(isOn: $settings.autoSwitchOutput) {
                    Text("Switch sound output automatically")
                    Text("Use Blue Bloom while streaming, and go back to the previous output when the headphones disconnect.")
                }
                Picker(selection: $settings.menuBarStyle) {
                    Text("Icon only").tag(MenuBarStyle.icon)
                    Text("Icon and codec").tag(MenuBarStyle.codec)
                    Text("Icon and bitrate").tag(MenuBarStyle.bitrate)
                } label: {
                    Text("Menu bar")
                }
            }
            Section {
                Picker(selection: $settings.language) {
                    Text("System default").tag("")
                    ForEach(Self.languages, id: \.code) { language in
                        Text(verbatim: language.name).tag(language.code)
                    }
                } label: {
                    Text("Language")
                    Text("Takes effect the next time Blue Bloom opens.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }

    // Language names are written in the language itself
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"),
        ("ko", "한국어"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
    ]
}

// MARK: - Codecs

struct CodecsPane: View {
    @Environment(AppModel.self) private var model

    // Bitrate tier footer: list the 44.1k-family rates when they differ, otherwise say they are nominal
    private static func presetFooter(_ presets: [CodecPreset]) -> String {
        let fixed = presets.filter { !$0.isAdaptive }
        if fixed.contains(where: { $0.kbps44 != $0.kbps }) {
            let rates = fixed.map { Format.kbps($0.kbps44) }.formatted(.list(type: .and))
            return String(localized: "These are the rates at 48 kHz; at 44.1 kHz they are \(rates). The menu bar panel shows the rate for the current stream.")
        }
        return String(localized: "These are the nominal rates. Some headphones can't take the highest one; Blue Bloom then remembers their limit, and the menu bar panel shows the rate they actually use.")
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                List {
                    ForEach(settings.codecPriority, id: \.self) { codec in
                        CodecPriorityRow(codec: codec, enabled: Binding(
                            get: { !settings.disabledCodecs.contains(codec) },
                            set: { on in
                                if on { settings.disabledCodecs.remove(codec) } else { settings.disabledCodecs.insert(codec) }
                                model.codecSettingsChanged()
                            }))
                    }
                    .onMove { from, to in
                        settings.codecPriority.move(fromOffsets: from, toOffset: to)
                        model.codecSettingsChanged()
                    }
                }
                .frame(height: CGFloat(settings.codecPriority.count) * 52)
                .scrollDisabled(true)
            } header: {
                Text("Priority")
            } footer: {
                Text("Blue Bloom uses the highest codec your headphones support. Drag to reorder; turn off codecs you never want. A codec chosen for a specific device always comes first.")
                    .foregroundStyle(.secondary)
            }
            // One section per codec that declares bitrate tiers (LDAC and codec plugins); tiers and descriptions are generated from the codec's own declaration
            ForEach(A2DPCodec.allCodecs().filter { !$0.presets.isEmpty }, id: \.identifier) { codec in
                let presets = codec.presets
                Section {
                    Picker(selection: Binding(get: { settings.preset(for: codec)?.identifier ?? codec.defaultPresetID },
                                              set: { settings.codecPresets[codec.identifier] = $0; model.codecSettingsChanged() })) {
                        ForEach(presets, id: \.identifier) { preset in
                            Text(verbatim: preset.title(in: presets)).tag(preset.identifier)
                        }
                    } label: {
                        Text("\(codec.displayName) quality")
                        if presets.contains(where: \.isAdaptive) {
                            Text("Adaptive lowers the bitrate when the link gets congested, then climbs back.")
                        }
                    }
                } header: {
                    Text(verbatim: codec.displayName)
                } footer: {
                    Text(verbatim: Self.presetFooter(presets))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                // The 320 tier is "automatic": the lowest of 320k, the headphones' declared bitrate and what fits the media channel MTU; with adaptive bitrate on, this is the cap
                Picker(selection: Binding(get: { settings.aacBitrate }, set: { settings.aacBitrate = $0; model.codecSettingsChanged() })) {
                    Text(verbatim: Format.kbps(320)).tag(0)
                    Text(verbatim: Format.kbps(256)).tag(256_000)
                    Text(verbatim: Format.kbps(192)).tag(192_000)
                    Text(verbatim: Format.kbps(128)).tag(128_000)
                } label: {
                    Text(settings.aacAdaptive ? "Maximum bitrate" : "AAC bitrate")
                }
                Toggle(isOn: Binding(get: { settings.aacVBR }, set: { settings.aacVBR = $0; model.codecSettingsChanged() })) {
                    Text("Variable bitrate")
                    Text("Spends bits where the music needs them, never above the limit.")
                }
                Toggle(isOn: Binding(get: { settings.aacAdaptive }, set: { settings.aacAdaptive = $0; model.codecSettingsChanged() })) {
                    Text("Adaptive bitrate")
                    Text("Lowers the bitrate when the link gets congested, then climbs back, never above the setting above.")
                }
            } header: {
                Text(verbatim: "AAC")
            }
            Section {
                Toggle(isOn: Binding(get: { settings.sbcXQ }, set: { settings.sbcXQ = $0; model.codecSettingsChanged() })) {
                    Text("SBC XQ (dual channel, about 500 kbps)")
                    Text("Much better than standard SBC. Some headphones may not accept it.")
                }
                Toggle(isOn: Binding(get: { settings.sbcAdaptive }, set: { settings.sbcAdaptive = $0; model.codecSettingsChanged() })) {
                    Text("Adaptive bitrate")
                    Text("Lowers the bitrate when the link gets congested, then climbs back, never above the setting above.")
                }
            } header: {
                Text(verbatim: "SBC")
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }
}

struct CodecPriorityRow: View {
    let codec: CodecID
    @Binding var enabled: Bool

    var body: some View {
        let info = CodecInfo.of(codec)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            CodecBadge(codec: codec, dimmed: !enabled)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: info.detail).font(.callout)
                Text(verbatim: info.vendor).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $enabled) { Text(verbatim: info.name) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.6)
    }
}

// MARK: - Audio

struct AudioPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker(selection: Binding(get: { settings.sampleRateMode }, set: { settings.sampleRateMode = $0; model.applySampleRateMode() })) {
                    Text("Match the source").tag(SampleRateMode.followSource)
                    Text("Highest the codec supports").tag(SampleRateMode.highest)
                    Divider()
                    Text(verbatim: Format.kHz(44_100)).tag(SampleRateMode.fixed44100)
                    Text(verbatim: Format.kHz(48_000)).tag(SampleRateMode.fixed48000)
                    Text(verbatim: Format.kHz(88_200)).tag(SampleRateMode.fixed88200)
                    Text(verbatim: Format.kHz(96_000)).tag(SampleRateMode.fixed96000)
                } label: {
                    Text("Sample rate")
                    if settings.sampleRateMode == .followSource {
                        Text("Aims for the Apple Music track's sample rate while it plays, otherwise the output device's, so players that change the sample rate themselves are followed too. If the headphones' codec doesn't support it, the closest rate the codec supports is used; some codecs only have 48 kHz.")
                    } else {
                        Text("Blue Bloom picks the closest rate the codec supports, staying in the same family (44.1 or 48 kHz) to avoid resampling.")
                    }
                }
                Picker(selection: Binding(get: { settings.maxSampleRate }, set: { settings.maxSampleRate = $0; model.codecSettingsChanged() })) {
                    Text("No limit").tag(0.0)
                    Text(verbatim: Format.kHz(48_000)).tag(48_000.0)
                    Text(verbatim: Format.kHz(96_000)).tag(96_000.0)
                } label: {
                    Text("Maximum sample rate")
                }
                // What follow source is following right now: the Apple Music track while it plays, otherwise the virtual device's current sample rate
                if settings.sampleRateMode == .followSource, model.sourceRate > 0 || model.deviceRate > 0 {
                    LabeledContent {
                        if model.sourceRate > 0 {
                            Text(Format.audioFormat(rate: model.sourceRate, bits: model.sourceBitDepth))
                        } else {
                            Text(verbatim: Format.kHz(model.deviceRate))
                        }
                    } label: {
                        Text("Current source")
                        if model.sourceRate > 0 {
                            Text("Apple Music track")
                        } else {
                            Text("Output device. Apps that don't change the sample rate, such as Spotify, are resampled to it by macOS.")
                        }
                    }
                    // When the actual stream differs from the source, explain why, so it doesn't look as if "Match the source" isn't working
                    if let note = model.resampleNote {
                        LabeledContent {
                            Text(verbatim: Format.kHz(note.rate))
                        } label: {
                            Text("Streaming at")
                            Text(verbatim: note.reason)
                        }
                    }
                }
            } header: {
                Text("Format")
            }
            Section {
                Toggle(isOn: $settings.volumeSync) {
                    Text("Sync volume with the headphones")
                    Text("The Mac volume controls the headphone amplifier (absolute volume) instead of attenuating the signal.")
                }
                Toggle(isOn: Binding(get: { settings.awdlSuppress }, set: { settings.awdlSuppress = $0 })) {
                    Text("Pause AirDrop and AirPlay discovery while streaming")
                    AwdlGuard.helperInstalled ? Text("Wi-Fi peer-to-peer scans cause dropouts on Macs that share one radio for Wi-Fi and Bluetooth.")
                                              : Text("Needs the separate AWDL guard helper, which isn't installed.")
                }
                .disabled(!AwdlGuard.helperInstalled)
            } header: {
                Text("Playback")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}

// MARK: - Devices

struct DevicesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.devices.devices.isEmpty {
                Section {
                    Text("No paired Bluetooth headphones yet.").foregroundStyle(.secondary)
                }
            }
            ForEach(model.devices.devices) { device in
                DeviceSettingsSection(device: device)
            }
            Section {
                Button("Open Bluetooth Settings…") { model.openBluetoothSettings() }
            } footer: {
                Text("Automatic: Blue Bloom takes over when the headphones support a better codec than macOS (LDAC or aptX). Otherwise macOS keeps them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

struct DeviceSettingsSection: View {
    @Environment(AppModel.self) private var model
    let device: BluetoothDevice

    var body: some View {
        let record = model.devices.record(device.address)
        let supported = model.settings.codecPriority.filter(Set(record.codecs.compactMap(\.codec)).contains)
        Section {
            Picker(selection: Binding(get: { record.mode }, set: { model.setMode($0, for: device.address) })) {
                Text("Automatic").tag(DeviceMode.automatic)
                Text("Always use Blue Bloom").tag(DeviceMode.always)
                Text("Leave to macOS").tag(DeviceMode.system)
            } label: {
                Text("Connection")
            }
            Picker(selection: Binding(get: { record.preferredCodec }, set: { model.setPreferredCodec($0, for: device.address) })) {
                Text("Automatic (best available)").tag(CodecID?.none)
                ForEach(supported, id: \.self) { codec in
                    Text(verbatim: CodecInfo.of(codec).name).tag(CodecID?.some(codec))
                }
            } label: {
                Text("Preferred codec")
            }
            .disabled(supported.isEmpty)
            // Records are re-identified against the current registry when read (RemoteCodec): implemented codecs show a badge, the rest show the codec ID (e.g. D7/AD)
            let unsupported = record.codecs.filter { $0.codec == nil }.map(\.name)
            LabeledContent {
                if record.codecs.isEmpty {
                    Text("Detected on first connection").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(record.codecs.compactMap(\.codec), id: \.self) { codec in
                            CodecBadge(codec: codec, compact: true)
                        }
                        ForEach(unsupported, id: \.self) { name in
                            Text(verbatim: name).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                Text("Headphone codecs")
                if !unsupported.isEmpty {
                    Text("Includes codecs Blue Bloom doesn't support yet")
                }
            }
            if !record.codecs.isEmpty {
                Button("Forget Detected Codecs") { model.devices.forgetCodecs(for: device.address) }
            }
        } header: {
            HStack {
                Image(systemName: device.symbol)
                Text(verbatim: device.name)
                if device.address == model.settings.activeDevice {
                    Text("Current").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
                Text(verbatim: device.address).font(.caption).foregroundStyle(.tertiary).monospaced()
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    switch model.driverState {
                    case .current: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .outdated: Label("Update available", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
                    case .missing: Label("Not installed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                } label: {
                    Text("Blue Bloom audio device")
                    Text("A virtual output that apps play into. Installing needs an administrator password and briefly restarts Core Audio.")
                }
                HStack {
                    Spacer()
                    Button(model.driverState == .current ? "Reinstall…" : "Install…") { model.installDriver() }
                        .disabled(model.installingDriver)
                    Button("Sound Settings…") { model.openSoundSettings() }
                }
            } header: {
                Text("Audio Device")
            }
            Section {
                HStack {
                    Text("Diagnostic log")
                    Spacer()
                    Button("Open Log") { model.openLog() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LogFile.url]) }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text(verbatim: LogFile.url.path).font(.caption).foregroundStyle(.tertiary)
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                    .disabled(Snapshot.isActive)
                Button("Uninstall Blue Bloom…", role: .destructive) { confirmUninstall = true }
                    .disabled(Snapshot.isActive || model.uninstalling)
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .confirmationDialog(Text("Uninstall Blue Bloom?"), isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
        } message: {
            Text("Removes the Blue Bloom audio device (needs an administrator password), the login item, settings and log, then moves the app to the Trash and quits. Your headphones go back to macOS.")
        }
        .alert(Text("Couldn't uninstall Blue Bloom"), isPresented: Binding(get: { model.uninstallError != nil }, set: { if !$0 { model.uninstallError = nil } })) {
        } message: {
            Text(verbatim: model.uninstallError ?? "")
        }
        .alert(Text("Couldn't install the Blue Bloom audio device"), isPresented: Binding(get: { model.driverError != nil }, set: { if !$0 { model.driverError = nil } })) {
        } message: {
            Text(verbatim: model.driverError ?? "")
        }
        .confirmationDialog(Text("Reset all Blue Bloom settings?"), isPresented: $confirmReset) {
            Button("Reset and Quit", role: .destructive) {
                guard !Snapshot.isActive else { return }
                model.settings.resetAll()
                NSApp.terminate(nil)
            }
        } message: {
            Text("Codec priority, device choices and detected codecs will be cleared.")
        }
    }
}

// MARK: - About

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotices = false
    @State private var copied = false

    // Public repository URL: fill it in here once decided, and the About pane shows the project link
    static let projectURL: URL? = nil
    // Width of the body text (intro, acknowledgements, footer notices), a bit narrower than the window and centered
    static let textWidth: CGFloat = 460

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                BloomMark(size: 64)
                Text(verbatim: "Blue Bloom").font(.title2.weight(.semibold)).padding(.top, 4)
                Text("Version \(AppModel.appVersion) (\(AppModel.appBuild))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Codecs aren't listed: more and more get compiled in, and the acknowledgements already list each one
                Text("High-quality Bluetooth audio for your Mac.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.textWidth)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Acknowledgements").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                creditList
                    .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
            .frame(maxWidth: Self.textWidth)
            // The button row uses the full window width: German and other translations are longer and would be truncated at the body width
            HStack(spacing: 10) {
                Button("Third-Party Notices…") { showingNotices = true }
                Button("Welcome Notes…") { model.openWelcome() }
                Button(copied ? "Copied" : "Copy Diagnostics") { copyDiagnostics() }
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: "© 2026 Blue Bloom contributors · MIT License")
                    if let url = Self.projectURL {
                        Link("Project Page", destination: url)
                    }
                }
                Text("Blue Bloom doesn't connect to the internet or collect any data. Its log stays on this Mac.")
                Text(verbatim: Self.trademarks).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.textWidth)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingNotices) { NoticesSheet() }
    }

    // Acknowledgements list: the Settings window grows to fit its content, so with many codecs (plugins) it would overflow small screens; beyond maxCreditRows rows it becomes fixed-height and scrollable
    @ViewBuilder private var creditList: some View {
        let rows = Self.creditRows
        let list = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.credit) { index, row in
                if index > 0 { Divider().padding(.leading, 12) }
                CreditRowView(row: row)
            }
        }
        if rows.count > Self.maxCreditRows {
            ScrollView { list }.frame(height: CGFloat(Self.maxCreditRows) * 50)
        } else {
            list
        }
    }

    static let maxCreditRows = 6

    // Attached to bug reports (no personal data such as device addresses), see AppModel diagnostics
    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnostics, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    // One acknowledgements row: codecs with the same origin are merged into one row (e.g. aptX HD and aptX share libfreeaptx)
    struct CreditRow {
        var codecs: [String]
        let credit: String
        let url: URL?
    }

    // Generated from each codec's own declaration (A2DPCodec credit, creditURL); when a codec plugin is compiled in, its row appears here too
    static var creditRows: [CreditRow] {
        var rows: [CreditRow] = []
        for codec in A2DPCodec.allCodecs() {
            guard let credit = codec.credit else { continue }
            if let index = rows.firstIndex(where: { $0.credit == credit }) {
                rows[index].codecs.append(codec.displayName)
            } else {
                rows.append(CreditRow(codecs: [codec.displayName], credit: credit, url: codec.creditURL))
            }
        }
        return rows
    }

    // Trademark and non-affiliation notice at the bottom: each codec's declared trademark (A2DPCodec trademark, each sentence listed once) plus a general sentence
    static var trademarks: String {
        var lines: [String] = []
        for trademark in A2DPCodec.allCodecs().compactMap(\.trademark) where !lines.contains(trademark) { lines.append(trademark) }
        lines.append("Bluetooth is a registered trademark of Bluetooth SIG, Inc. Other names are trademarks of their respective owners. "
                     + "Blue Bloom is not affiliated with, endorsed by or certified by any of them.")
        return lines.joined(separator: " ")
    }
}

struct CreditRowView: View {
    let row: AboutPane.CreditRow

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.codecs.joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: row.credit)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let url = row.url {
                Link(destination: url) {
                    HStack(spacing: 2) {
                        Text("Source Code")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// Full third-party notices: ThirdPartyNotices.txt shipped with the app (generated at build time by App/BUILD.bazel). Shown inside the app,
// not opened in a text editor: editing and saving there would modify the app bundle and break the signature
struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private static let text = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(verbatim: Self.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 680, height: 520)
    }
}
