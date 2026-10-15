// User settings: stored in UserDefaults; changes take effect immediately and notify the UI.
import BlueBloomEngine
import Foundation
import Observation

enum SettingsKey {
    static let enabled = "Enabled"
    static let activeDevice = "ActiveDevice"
    static let sampleRateMode = "SampleRateMode"
    static let maxSampleRate = "MaxSampleRate"
    static let codecPriority = "CodecPriority"
    static let disabledCodecs = "DisabledCodecs"
    static let codecPresets = "CodecPresets"
    static let aacBitrate = "AACBitrate"
    static let aacVBR = "AACVBR"
    static let sbcXQ = "SBCXQ"
    static let sbcAdaptive = "SBCAdaptive"
    static let aacAdaptive = "AACAdaptive"
    static let autoSwitchOutput = "AutoSwitchOutput"
    static let awdlSuppress = "AwdlSuppress"
    static let volumeSync = "VolumeSync"
    static let menuBarStyle = "MenuBarStyle"
    static let language = "Language"
    static let acceptedNotice = "AcceptedNotice"
    static let untestedSystemAllowed = "UntestedSystemAllowed"
}

// Sample rate: follow Apple Music's current track, the highest the codec supports, or a fixed value
enum SampleRateMode: String, CaseIterable, Identifiable {
    case followSource = "auto"
    case highest = "max"
    case fixed44100 = "44100"
    case fixed48000 = "48000"
    case fixed88200 = "88200"
    case fixed96000 = "96000"
    var id: String { rawValue }
}

// What to show next to the menu bar icon
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon
    case codec
    case bitrate
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppSettings {
    // Snapshot mode uses a separate domain so the user's settings are not changed
    private let defaults = Snapshot.isActive ? UserDefaults(suiteName: "app.bluebloom.snapshot")! : UserDefaults.standard

    var enabled: Bool { didSet { defaults.set(enabled, forKey: SettingsKey.enabled) } }
    var activeDevice: String? { didSet { defaults.set(activeDevice, forKey: SettingsKey.activeDevice) } }
    var sampleRateMode: SampleRateMode { didSet { defaults.set(sampleRateMode.rawValue, forKey: SettingsKey.sampleRateMode) } }
    var maxSampleRate: Double { didSet { defaults.set(maxSampleRate, forKey: SettingsKey.maxSampleRate) } }
    // Only codecs compiled into this build; codecs not compiled in (codec plugins) keep their place in storedPriority,
    // so the priority is unchanged when switching back to a build with the plugins
    var codecPriority: [CodecID] {
        didSet {
            storedPriority = Self.merge(codecPriority, into: storedPriority)
            defaults.set(storedPriority.map(\.rawValue), forKey: SettingsKey.codecPriority)
        }
    }
    @ObservationIgnored private var storedPriority: [CodecID]
    var disabledCodecs: Set<CodecID> { didSet { defaults.set(disabledCodecs.map(\.rawValue).sorted(), forKey: SettingsKey.disabledCodecs) } }
    // Bitrate tier chosen for each codec (CodecPreset identifier); tiers are declared by the codec itself; codecs never chosen use the codec's default tier
    var codecPresets: [CodecID: Int] {
        didSet { defaults.set(Dictionary(uniqueKeysWithValues: codecPresets.map { ($0.key.rawValue, $0.value) }), forKey: SettingsKey.codecPresets) }
    }
    var aacBitrate: Int { didSet { defaults.set(aacBitrate, forKey: SettingsKey.aacBitrate) } }
    var aacVBR: Bool { didSet { defaults.set(aacVBR, forKey: SettingsKey.aacVBR) } }
    var sbcXQ: Bool { didSet { defaults.set(sbcXQ, forKey: SettingsKey.sbcXQ) } }
    var sbcAdaptive: Bool { didSet { defaults.set(sbcAdaptive, forKey: SettingsKey.sbcAdaptive) } }
    var aacAdaptive: Bool { didSet { defaults.set(aacAdaptive, forKey: SettingsKey.aacAdaptive) } }
    var autoSwitchOutput: Bool { didSet { defaults.set(autoSwitchOutput, forKey: SettingsKey.autoSwitchOutput) } }
    var awdlSuppress: Bool { didSet { defaults.set(awdlSuppress, forKey: SettingsKey.awdlSuppress) } }
    var volumeSync: Bool { didSet { defaults.set(volumeSync, forKey: SettingsKey.volumeSync) } }
    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: SettingsKey.menuBarStyle) } }
    // Version of the first-run notice the user has seen and accepted (WelcomeView.noticeVersion); headphones are not taken over until the latest one is accepted
    var acceptedNotice: Int { didSet { defaults.set(acceptedNotice, forKey: SettingsKey.acceptedNotice) } }
    // macOS major version on which the user agreed to try an untested system (Compatibility); 0 means never agreed
    var untestedSystemAllowed: Int { didSet { defaults.set(untestedSystemAllowed, forKey: SettingsKey.untestedSystemAllowed) } }
    // UI language: "" follows the system, otherwise a language code; written to this app's AppleLanguages, takes effect after relaunch
    var language: String {
        didSet {
            defaults.set(language, forKey: SettingsKey.language)
            if language.isEmpty { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([language], forKey: "AppleLanguages") }
        }
    }

    init() {
        defaults.register(defaults: [
            SettingsKey.enabled: true,
            SettingsKey.sampleRateMode: SampleRateMode.followSource.rawValue,
            SettingsKey.aacVBR: true,
            SettingsKey.sbcAdaptive: true,
            SettingsKey.aacAdaptive: true,
            SettingsKey.autoSwitchOutput: true,
            SettingsKey.awdlSuppress: true,
            SettingsKey.volumeSync: true,
            SettingsKey.menuBarStyle: MenuBarStyle.icon.rawValue,
        ])
        enabled = defaults.bool(forKey: SettingsKey.enabled)
        activeDevice = defaults.string(forKey: SettingsKey.activeDevice)
        sampleRateMode = SampleRateMode(rawValue: defaults.string(forKey: SettingsKey.sampleRateMode) ?? "") ?? .followSource
        maxSampleRate = defaults.double(forKey: SettingsKey.maxSampleRate)
        // Add newly compiled-in codecs (e.g. a newly added codec plugin) to the stored order: by its declared rank, insert it after the last existing codec ranked ahead of it
        // (or first if none), so automatic mode can pick it as soon as it is compiled in without jumping ahead of codecs the user dragged to the front;
        // codecs not compiled into this build (plugins) stay in storage; the UI and engine only see the compiled-in ones
        var priority = (defaults.stringArray(forKey: SettingsKey.codecPriority) ?? []).map { CodecID(rawValue: $0) }
        for codec in A2DPCodec.allCodecs() where !priority.contains(codec.identifier) {
            let before = priority.lastIndex { A2DPCodec.codec(id: $0).map { $0.rank < codec.rank } ?? false }
            priority.insert(codec.identifier, at: before.map { $0 + 1 } ?? 0)
        }
        storedPriority = priority
        codecPriority = priority.filter { A2DPCodec.codec(id: $0) != nil }
        disabledCodecs = Set((defaults.stringArray(forKey: SettingsKey.disabledCodecs) ?? []).map { CodecID(rawValue: $0) })
        let presets = defaults.dictionary(forKey: SettingsKey.codecPresets) as? [String: Int] ?? [:]
        codecPresets = Dictionary(uniqueKeysWithValues: presets.map { (CodecID(rawValue: $0.key), $0.value) })
        aacBitrate = defaults.integer(forKey: SettingsKey.aacBitrate)
        aacVBR = defaults.bool(forKey: SettingsKey.aacVBR)
        sbcXQ = defaults.bool(forKey: SettingsKey.sbcXQ)
        sbcAdaptive = defaults.bool(forKey: SettingsKey.sbcAdaptive)
        aacAdaptive = defaults.bool(forKey: SettingsKey.aacAdaptive)
        autoSwitchOutput = defaults.bool(forKey: SettingsKey.autoSwitchOutput)
        awdlSuppress = defaults.bool(forKey: SettingsKey.awdlSuppress)
        volumeSync = defaults.bool(forKey: SettingsKey.volumeSync)
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: SettingsKey.menuBarStyle) ?? "") ?? .icon
        acceptedNotice = defaults.integer(forKey: SettingsKey.acceptedNotice)
        untestedSystemAllowed = defaults.integer(forKey: SettingsKey.untestedSystemAllowed)
        language = defaults.string(forKey: SettingsKey.language) ?? ""
    }

    var enabledPriority: [CodecID] { codecPriority.filter { !disabledCodecs.contains($0) } }

    // A codec's currently chosen bitrate tier (the codec's default tier if never chosen or no longer present); nil for codecs without tiers
    func preset(for codec: A2DPCodec) -> CodecPreset? {
        codecPresets[codec.identifier].flatMap { codec.preset(withID: $0) } ?? codec.preset(withID: codec.defaultPresetID) ?? codec.presets.first
    }

    // Write the reordered list back into the full order: codecs not compiled in stay in place, compiled-in ones fill their positions in the new order
    private static func merge(_ visible: [CodecID], into stored: [CodecID]) -> [CodecID] {
        var queue = visible[...]
        var merged = stored.compactMap { codec in visible.contains(codec) ? queue.popFirst() : codec }
        merged += queue
        return merged
    }

    func codecOptions(preferred: CodecID?) -> CodecOptions {
        let options = CodecOptions()
        options.priority = enabledPriority
        options.preferredCodec = preferred
        options.presets = codecPresets.mapValues { NSNumber(value: $0) }
        options.aacBitrate = aacBitrate
        options.aacVBR = aacVBR
        options.sbcXQ = sbcXQ
        options.sbcAdaptive = sbcAdaptive
        options.aacAdaptive = aacAdaptive
        options.maxSampleRate = maxSampleRate
        return options
    }

    func resetAll() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        defaults.removePersistentDomain(forName: domain)
    }
}
