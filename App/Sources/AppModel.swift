// UI model: ties the engine (StreamController), devices, settings, driver and audio output together for the views to read and act on.
import AppKit
import BlueBloomEngine
import BlueBloomSupport
import CoreBluetooth
import IOBluetooth
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let devices = DeviceStore()

    private(set) var status: LinkStatus = .stopped
    private(set) var sampleRate: Double = 0
    private(set) var battery: Int = -1
    private(set) var configuration: CodecConfiguration?
    private(set) var fallbackCodec: CodecID?
    private(set) var fallbackReason: CodecFallbackReason = .none
    private(set) var liveKbps: Double = 0
    private(set) var bitrateHistory: [Double] = []
    private(set) var headsetDelay: Double = 0
    // Time of the next automatic reconnect (while waiting to reconnect, or while the headphones are busy)
    private(set) var nextAttempt: Date?
    private(set) var remoteVolume: Int = -1
    // The AVRCP channel is held by macOS, so volume can't be handed to the headphone amp (software volume stacks on the headphone amp and may be too quiet)
    private(set) var remoteControlBlocked = false
    private(set) var sourceRate: Double = 0
    // Current sample rate and sample format of the virtual device: apps hand their audio to Blue Bloom in this format; when following the source and Apple Music isn't playing, the stream follows this sample rate
    private(set) var deviceRate: Double = 0
    private(set) var deviceBitDepth = 0
    private(set) var deviceFloat = false
    private(set) var sourceBitDepth: Int = 0
    private(set) var driverState: DriverState = .missing
    private(set) var virtualDeviceReady = false
    private(set) var blueBloomIsOutput = false
    private(set) var outputName: String?
    private(set) var installingDriver = false
    // Why the uninstall didn't finish (usually the administrator password prompt was cancelled); Settings shows an alert from it
    var uninstallError: String?
    // Uninstall in progress: Settings disables the uninstall button meanwhile
    private(set) var uninstalling = false
    // Why the driver install didn't finish; shown separately from uninstall
    var driverError: String?
    // Opens the first-run notice window (provided by AppDelegate)
    @ObservationIgnored var openWelcome: () -> Void = {}

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    // "Copy Diagnostics" on the About pane: attached to bug reports to tell which build, which system and which codecs are compiled in; contains no device names or addresses
    var diagnostics: String {
        let driver: String
        switch driverState {
        case .current: driver = "installed (\(DriverManager.version(at: DriverManager.installedPath) ?? "?"))"
        case .outdated: driver = "outdated (\(DriverManager.version(at: DriverManager.installedPath) ?? "?"), app has \(DriverManager.version(at: DriverManager.bundledPath) ?? "?"))"
        case .missing: driver = "not installed"
        }
        var lines = [
            "Blue Bloom \(Self.appVersion) (\(Self.appBuild))",
            "macOS \(Self.osVersion) (\(Self.osBuild))\(Compatibility.isTested ? "" : ", untested")",
            "Codecs: \(A2DPCodec.allCodecs().map(\.identifier.rawValue).joined(separator: ", "))",
            "Audio device: \(driver)",
            "Status: \(Self.statusName(status))",
        ]
        if let configuration {
            lines.append("Stream: \(configuration.codec.rawValue), \(Int(configuration.sampleRate)) Hz, \(Int(configuration.nominalKbps)) kbps")
        }
        return lines.joined(separator: "\n")
    }

    // Diagnostics use a fixed English format (operatingSystemVersionString is localized)
    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }

    private static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    private static func statusName(_ status: LinkStatus) -> String {
        switch status {
        case .connecting: return "connecting"
        case .waitingHeadset: return "waiting for headphones"
        case .streaming: return "streaming"
        case .idle: return "idle"
        case .retrying: return "retrying"
        case .stopped: return "stopped"
        case .system: return "handed to macOS"
        case .busy: return "headphones busy"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    // The latest first-run notice hasn't been accepted yet: don't take over the headphones yet
    var noticePending: Bool { settings.acceptedNotice < WelcomeView.noticeVersion }
    // The macOS version is untested and the user hasn't agreed to try it: don't take over the headphones yet (leave them to macOS)
    var systemUntested: Bool { !Compatibility.isTested && settings.untestedSystemAllowed != Compatibility.majorVersion }
    private(set) var loginItemEnabled = LoginItem.enabled
    // Bluetooth authorization: on first run the system shows a prompt, and IOBluetooth calls block until the user clicks "Allow"
    private(set) var bluetoothReady = false
    var bluetoothDenied: Bool { !Snapshot.isActive && [.denied, .restricted].contains(CBManager.authorization) }

    @ObservationIgnored private var controller: StreamController?
    @ObservationIgnored private let volumeSync = VolumeSync()
    @ObservationIgnored private var rateMonitor: SourceRateMonitor?
    @ObservationIgnored private var musicWatcher: MusicPlaybackWatcher?
    @ObservationIgnored private var musicScript: MusicSampleRateReader?
    // Sample rate of the current Apple Music track: the value read through the scripting interface wins (scriptRate); without permission, the one PlaybackEvents reports in the log (musicRate);
    // the scripting interface has no bit depth, so it is matched by sample rate and time from the lossless decoder's log (decoderFormats). sourceRate only takes these values while it plays
    @ObservationIgnored private var scriptRate: Double = 0
    @ObservationIgnored private var musicRate: Double = 0
    @ObservationIgnored private var musicBitDepth = 0
    @ObservationIgnored private var trackStartedAt = Date.distantPast
    @ObservationIgnored private var decoderFormats: [(date: Date, rate: Double, bits: Int)] = []
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let batteryPublisher = BatteryPublisher()
    @ObservationIgnored private var linkDownSince: Date?
    @ObservationIgnored private var switchedOutput = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var startAfterStop = false
    static let historyLength = 60

    init() {
        if Snapshot.isActive { return }
        LogFile.start()
        BBLogMessage("Blue Bloom \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") started")
        refreshSystemState()
        applySampleRateMode()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        AwdlGuard.update(suppress: false)
        waitForBluetooth()
    }

    // The first IOBluetooth call waits for the user to answer the authorization prompt: wait on a background thread so the UI comes up normally; start the device list and connection after authorization
    private func waitForBluetooth() {
        if CBManager.authorization == .allowedAlways {
            bluetoothDidBecomeReady()
            return
        }
        BBLogMessage("Waiting for Bluetooth authorization (\(CBManager.authorization.rawValue))")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = IOBluetoothHostController.default()?.powerState
            _ = IOBluetoothDevice.pairedDevices()
            DispatchQueue.main.async { [weak self] in self?.bluetoothDidBecomeReady() }
        }
    }

    private func bluetoothDidBecomeReady() {
        guard !bluetoothReady else { return }
        bluetoothReady = true
        BBLogMessage("Bluetooth available (authorization status \(CBManager.authorization.rawValue))")
        devices.activate()
        guard virtualDeviceReady, settings.enabled else { return }
        startController()
    }

    // MARK: Current device and status

    var activeDevice: BluetoothDevice? { devices.device(settings.activeDevice) }

    var activeRecord: DeviceRecord? { settings.activeDevice.map(devices.record) }

    var isStreaming: Bool { status == .streaming }

    var isConnected: Bool { status == .streaming || status == .idle }

    // Battery: for the current headphones the value received by Blue Bloom's HFP gateway wins, otherwise the one recorded by the system (bluetoothd), matching Control Center
    func battery(for device: BluetoothDevice) -> BatteryLevels? {
        if device.address == settings.activeDevice, let levels = BatteryLevels.single(battery) { return levels }
        return device.battery
    }

    var activeBattery: BatteryLevels? { activeDevice.flatMap(battery(for:)) }

    var activeCodec: A2DPCodec? { configuration.flatMap { A2DPCodec.codec(id: $0.codec) } }

    // Codecs available on the current device (implemented here and supported by the headphones), in priority order
    var availableCodecs: [CodecID] {
        guard let record = activeRecord else { return [] }
        let supported = Set(record.codecs.compactMap(\.codec))
        return settings.codecPriority.filter(supported.contains)
    }

    // MARK: Controller

    func startController() {
        // Demo/snapshot mode never touches real Bluetooth
        guard !Snapshot.isActive else { return }
        if stopping {
            startAfterStop = true
            return
        }
        // Don't take over the headphones until the first-run notice is accepted, or on an untested macOS until the user agrees; the setup checklist shows matching items
        guard !noticePending, !systemUntested else { return }
        guard bluetoothReady, controller == nil, settings.enabled, let address = settings.activeDevice,
              let device = IOBluetoothDevice(addressString: address) else { return }
        guard devices.record(address).mode != .system else {
            status = .system
            return
        }
        guard virtualDeviceReady else {
            BBLogMessage("Virtual device missing, not enabling yet")
            return
        }
        let controller = StreamController(device: device, virtualDevice: true)
        controller.optionsProvider = { [weak self] in
            MainActor.assumeIsolated { self?.codecOptions(for: address) ?? CodecOptions() }
        }
        controller.desiredSampleRate = desiredSampleRate
        controller.capabilitiesHandler = { [weak self] codecs in
            MainActor.assumeIsolated { self?.capabilitiesFound(codecs, address: address) ?? true }
        }
        controller.remoteControlBlockedHandler = { [weak self] blocked in
            MainActor.assumeIsolated { self?.remoteControlBlocked = blocked }
        }
        controller.codecLimitHandler = { [weak self] codec, kbps in
            MainActor.assumeIsolated { self?.devices.setMaxKbps(kbps, codec: codec, for: address) }
        }
        controller.statusHandler = { [weak self] status, rate, battery in
            MainActor.assumeIsolated { self?.statusChanged(status, rate: rate, battery: Int(battery)) }
        }
        controller.remoteVolumeHandler = { [weak self] volume in
            MainActor.assumeIsolated {
                self?.remoteVolume = Int(volume)
                if self?.settings.volumeSync == true || volume < 0 { self?.volumeSync.remoteVolumeChanged(volume) }
            }
        }
        controller.remoteOperationHandler = { [weak self] operation in
            MainActor.assumeIsolated { MediaKeys.handle(operation, volume: self?.volumeSync) }
        }
        volumeSync.sendVolumeHandler = { [weak self, weak controller] volume in
            MainActor.assumeIsolated {
                guard self?.settings.volumeSync == true else { return false }
                return controller?.setRemoteVolume(volume) ?? false
            }
        }
        self.controller = controller
        BBLogMessage("Enabling: \(device.name ?? address) [\(address)]")
        controller.start()
    }

    // Stopping is asynchronous (closes the stream and releases the headphones; 5–10 s when handing back to macOS): a start requested while stopping waits until the stop finishes;
    // the callback only clears the controller it stopped, so a controller created during the stop isn't dropped
    func stopController(then next: (() -> Void)? = nil) {
        guard let controller else {
            next?()
            return
        }
        BBLogMessage("Disabling")
        stopping = true
        controller.stop { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.controller === controller {
                    self.controller = nil
                    self.remoteControlBlocked = false
                    self.volumeSync.remoteVolumeChanged(-1)
                    self.statusChanged(.stopped, rate: 0, battery: -1)
                }
                self.stopping = false
                next?()
                if self.startAfterStop {
                    self.startAfterStop = false
                    self.startController()
                }
            }
        }
    }

    func restartController() {
        stopController { [weak self] in self?.startController() }
    }

    private func codecOptions(for address: String) -> CodecOptions {
        let record = devices.record(address)
        let options = settings.codecOptions(preferred: record.preferredCodec)
        options.maxKbps = Dictionary(uniqueKeysWithValues: record.maxKbps.map { (CodecID(rawValue: $0.key), NSNumber(value: $0.value)) })
        return options
    }

    // Automatic mode: Blue Bloom streams only if the headphones support a better codec than macOS, or the user chose a codec for them
    private func capabilitiesFound(_ codecs: [RemoteCodec], address: String) -> Bool {
        devices.setCodecs(codecs, for: address)
        let record = devices.record(address)
        switch record.mode {
        case .always: return true
        case .system: return false
        case .automatic:
            let supported = Set(codecs.filter { !$0.sampleRates.isEmpty }.compactMap(\.codec)).subtracting(settings.disabledCodecs)
            if let preferred = record.preferredCodec, supported.contains(preferred) { return true }
            // Each codec declares whether it is clearly better than macOS's built-in AAC (A2DPCodec isPremium)
            if supported.contains(where: { A2DPCodec.codec(id: $0)?.isPremium == true }) { return true }
            // For SBC-only headphones, SBC XQ is still better than the system's SBC
            if settings.sbcXQ && supported == [.sbc] { return true }
            BBLogMessage("Automatic mode: headphones only support \(codecs.map(\.name).joined(separator: ", ")), handing to macOS")
            return false
        }
    }

    private func statusChanged(_ status: LinkStatus, rate: Double, battery: Int) {
        let previous = self.status
        self.status = status
        sampleRate = rate
        // -1 when the engine has no battery level (HFP not held by Blue Bloom, session reconnecting); the UI then uses the one recorded by the system
        self.battery = battery
        refreshSessionInfo()
        AwdlGuard.update(suppress: settings.awdlSuppress && status == .streaming)
        updateOutputRouting(previous: previous)
        publishBattery()
    }

    // While Blue Bloom holds HFP the system gets no battery level: publish what the gateway received to the system; while macOS holds HFP the gateway has no value and the system publishes it itself
    private func publishBattery() {
        let owned = status == .streaming || status == .idle || status == .connecting
        batteryPublisher.update(name: activeDevice?.name, identifier: controller?.deviceIdentifier, percent: owned ? battery : -1)
    }

    private func refreshSessionInfo() {
        configuration = controller?.configuration
        fallbackCodec = controller?.fallbackCodec
        fallbackReason = controller?.fallbackReason ?? .none
        headsetDelay = controller?.headsetDelayMs ?? 0
        nextAttempt = controller?.nextAttempt
    }

    // Manual retry while waiting for the headphones or a reconnect: reconnect immediately and clear the "headphones busy" backoff
    func retryNow() {
        controller?.retryNow()
        refreshSessionInfo()
    }

    var canRetryNow: Bool { [.waitingHeadset, .busy, .retrying].contains(status) }

    // Every second: bitrate graph, session info, system state
    private func tick() {
        liveKbps = isStreaming ? controller?.recentKbps ?? 0 : 0
        bitrateHistory.append(liveKbps)
        if bitrateHistory.count > Self.historyLength { bitrateHistory.removeFirst(bitrateHistory.count - Self.historyLength) }
        refreshSessionInfo()
        refreshSystemState()
        updateOutputRouting()
        publishBattery()
    }

    func refreshSystemState() {
        guard !Snapshot.isActive else { return }
        driverState = DriverManager.state
        virtualDeviceReady = AudioOutput.virtualDevice != nil
        let virtual = AudioOutput.virtualDevice
        deviceRate = virtual.flatMap(AudioOutput.nominalSampleRate(of:)) ?? 0
        let sampleFormat = virtual.flatMap(AudioOutput.outputSampleFormat(of:))
        deviceBitDepth = sampleFormat?.bits ?? 0
        deviceFloat = sampleFormat?.isFloat ?? false
        blueBloomIsOutput = AudioOutput.isBlueBloomDefault
        outputName = AudioOutput.defaultOutputName
        devices.refresh()
    }

    // MARK: Sound output follows the connection state

    // On connecting (streaming starts or idle suspend) switch the output to Blue Bloom, only this once; if the user changes it manually afterwards, don't take it back;
    // when disconnected for more than 3 s (headphones off, out of range) or handed to macOS, restore the previous output so there is still sound
    private func updateOutputRouting(previous: LinkStatus? = nil) {
        guard settings.autoSwitchOutput else { return }
        let connected = status == .streaming || status == .idle
        if connected {
            linkDownSince = nil
            let wasConnected = previous == .streaming || previous == .idle
            if let previous, !wasConnected, previous != status, !AudioOutput.isBlueBloomDefault {
                AudioOutput.switchToBlueBloom()
                switchedOutput = true
            }
            return
        }
        guard switchedOutput else { return }
        if status == .system || status == .stopped {
            restoreOutput()
            return
        }
        let since = linkDownSince ?? Date()
        linkDownSince = since
        if Date().timeIntervalSince(since) > 3 { restoreOutput() }
    }

    // Only restore an output Blue Bloom switched itself; leave one the user picked manually alone
    private func restoreOutput() {
        guard switchedOutput else { return }
        AudioOutput.restorePrevious()
        switchedOutput = false
        linkDownSince = nil
    }

    func useBlueBloomOutput() {
        AudioOutput.switchToBlueBloom()
        switchedOutput = true
        refreshSystemState()
    }

    // MARK: User actions

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        if enabled { startController() } else { stopController { [weak self] in self?.restoreOutput() } }
    }

    func activate(_ device: BluetoothDevice) {
        guard device.address != settings.activeDevice || controller == nil else { return }
        settings.activeDevice = device.address
        if devices.record(device.address).mode == .system { devices.setMode(.automatic, for: device.address) }
        if !settings.enabled { settings.enabled = true }
        restartController()
    }

    func setMode(_ mode: DeviceMode, for address: String) {
        devices.setMode(mode, for: address)
        if address == settings.activeDevice { restartController() }
    }

    // Preferred codec: while streaming, don't disconnect the headphones; close the stream and reconfigure with the new codec
    func setPreferredCodec(_ codec: CodecID?, for address: String) {
        devices.setPreferredCodec(codec, for: address)
        guard address == settings.activeDevice else { return }
        if status == .system { restartController() } else { controller?.updateOptions(codecOptions(for: address)) }
    }

    // Codec settings changed: the streaming session reselects with the new options
    func codecSettingsChanged() {
        guard let address = settings.activeDevice else { return }
        // No session after handing back to macOS: decide again with the new settings whether to take over
        if status == .system { restartController() } else { controller?.updateOptions(codecOptions(for: address)) }
    }

    func acceptNotice() {
        settings.acceptedNotice = WelcomeView.noticeVersion
        BBLogMessage("First-run notice accepted (version \(WelcomeView.noticeVersion))")
        startController()
    }

    func allowUntestedSystem() {
        guard !Snapshot.isActive else { return }
        settings.untestedSystemAllowed = Compatibility.majorVersion
        BBLogMessage("User agreed to try untested macOS \(Compatibility.versionText)")
        startController()
    }

    // Uninstall: close the stream and release the headphones first, then delete the driver (needs the administrator password; cancelling aborts it all and resumes streaming), then remove the login item, the AirDrop suppression flag,
    // settings and log, move the app to the Trash and quit
    func uninstall() {
        guard !Snapshot.isActive, !uninstalling else { return }
        uninstalling = true
        BBLogMessage("Starting uninstall")
        stopController { [weak self] in
            guard let self else { return }
            if let error = DriverManager.uninstall() {
                self.uninstalling = false
                self.uninstallError = self.userFacingError(error)
                self.startController()
                return
            }
            LoginItem.set(false)
            AwdlGuard.update(suppress: false)
            try? FileManager.default.removeItem(at: LogFile.url)
            // The callback isn't guaranteed to run on the main thread
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        // Moving to the Trash failed: the driver is already deleted; stay here and report the error, the user removes the app manually
                        self.uninstalling = false
                        self.uninstallError = self.userFacingError(error.localizedDescription)
                        return
                    }
                    self.settings.resetAll()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func installDriver() {
        guard !Snapshot.isActive else { return }
        installingDriver = true
        driverError = nil
        stopController { [weak self] in
            guard let self else { return }
            if let error = DriverManager.install() {
                self.driverError = self.userFacingError(error)
                self.installingDriver = false
                self.startController()
                return
            }
            self.waitForVirtualDevice(attempts: 20)
        }
    }

    // Map the raw English errors returned by AppleScript / shell to UI text (the raw error is already in the log)
    private func userFacingError(_ raw: String) -> String {
        if raw.contains("signature") || raw.contains("code object") || raw.contains("subcomponent") {
            return String(localized: "The audio device failed its signature check. The app may be damaged or modified — download Blue Bloom again from a trusted source.")
        }
        if raw.contains("-128") || raw.localizedCaseInsensitiveContains("cancel") {
            return String(localized: "The administrator password prompt was cancelled.")
        }
        return String(localized: "The operation couldn't be completed. The log has the details.")
    }

    private func waitForVirtualDevice(attempts: Int) {
        refreshSystemState()
        if virtualDeviceReady || attempts <= 0 {
            installingDriver = false
            startController()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.waitForVirtualDevice(attempts: attempts - 1) }
    }

    func setLoginItem(_ enabled: Bool) {
        LoginItem.set(enabled)
        loginItemEnabled = LoginItem.enabled
    }

    func openLog() {
        NSWorkspace.shared.open(LogFile.url)
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }

    func openBluetoothPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") { NSWorkspace.shared.open(url) }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // Before quitting, close the stream and hand back the headphones and sound output
    func prepareForQuit(_ done: @escaping () -> Void) {
        AwdlGuard.update(suppress: false)
        batteryPublisher.remove()
        stopController { [weak self] in
            self?.restoreOutput()
            done()
        }
    }

    // UI state in snapshot mode
    func loadPreview(status: LinkStatus, configuration: CodecConfiguration?, battery: Int, history: [Double], driver: DriverState,
                     fallback: (CodecID, CodecFallbackReason)? = nil, output: String = "Blue Bloom", retryIn: TimeInterval? = nil,
                     remoteControlBlocked: Bool = false) {
        nextAttempt = retryIn.map { Date(timeIntervalSinceNow: $0) }
        self.remoteControlBlocked = remoteControlBlocked
        deviceRate = configuration?.sampleRate ?? 0
        deviceBitDepth = 32
        deviceFloat = true
        bluetoothReady = true
        self.status = status
        self.configuration = configuration
        sampleRate = configuration?.sampleRate ?? 0
        self.battery = battery
        bitrateHistory = history
        liveKbps = history.last ?? 0
        driverState = driver
        virtualDeviceReady = driver == .current
        blueBloomIsOutput = output == "Blue Bloom"
        outputName = output
        headsetDelay = status == .streaming ? 200 : 0
        fallbackCodec = fallback?.0
        fallbackReason = fallback?.1 ?? .none
        sourceRate = 96_000
        sourceBitDepth = 24
    }

    // MARK: Sample rate

    // When following the source but the streamed sample rate differs from the source: the stream rate and the reason (for the UI). The codec is chosen first, then the sample rate within the codec,
    // so they differ when the headphones' codec doesn't support the source rate (e.g. a 48 kHz-only codec) or "Maximum sample rate" caps it; nil when not following the source or when equal
    var resampleNote: (rate: Double, source: Double, reason: String)? {
        guard settings.sampleRateMode == .followSource, sourceRate > 0, isConnected, let configuration,
              configuration.sampleRate > 0, configuration.sampleRate != sourceRate else { return nil }
        let reason: String
        if settings.maxSampleRate > 0, sourceRate > settings.maxSampleRate {
            reason = String(localized: "Limited by Maximum sample rate; macOS resamples the source to this rate.")
        } else {
            let codec = Format.codecName(configuration.codec)
            let source = Format.kHz(sourceRate)
            reason = String(localized: "\(codec) doesn't support \(source); macOS resamples the source to this rate.")
        }
        return (configuration.sampleRate, sourceRate, reason)
    }

    // Follow source: the current Apple Music track's sample rate while it plays, otherwise 0; highest: the highest the codec supports; fixed: the user's choice.
    // 0 means unspecified, use the virtual device's current value (when a player that changes the output sample rate itself changes it, the engine reconfigures to follow)
    var desiredSampleRate: Double {
        switch settings.sampleRateMode {
        case .followSource: return sourceRate
        case .highest: return 192_000
        case .fixed44100: return 44_100
        case .fixed48000: return 48_000
        case .fixed88200: return 88_200
        case .fixed96000: return 96_000
        }
    }

    func applySampleRateMode() {
        if settings.sampleRateMode == .followSource {
            if rateMonitor == nil {
                let monitor = SourceRateMonitor()
                monitor.formatHandler = { [weak self] rate, bits in
                    MainActor.assumeIsolated { self?.musicFormatChanged(rate, bits: Int(bits)) }
                }
                monitor.decoderHandler = { [weak self] rate, bits, date in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.decoderFormats.append((date, rate, Int(bits)))
                        if self.decoderFormats.count > 40 { self.decoderFormats.removeFirst(self.decoderFormats.count - 40) }
                        self.updateSourceRate()
                    }
                }
                monitor.start()
                rateMonitor = monitor
            }
            if musicWatcher == nil {
                musicScript = MusicSampleRateReader()
                let watcher = MusicPlaybackWatcher()
                watcher.onChange = { [weak self] playing in
                    BBLogMessage(playing ? "Apple Music started playing" : "Apple Music stopped or quit: following the device's current sample rate")
                    self?.updateSourceRate()
                }
                watcher.onPlaying = { [weak self] in
                    self?.trackStartedAt = Date()
                    self?.readTrackSampleRate()
                }
                watcher.start()
                musicWatcher = watcher
                if watcher.isPlaying {
                    trackStartedAt = Date()
                    readTrackSampleRate()
                }
            }
        } else {
            rateMonitor?.stop()
            rateMonitor = nil
            musicWatcher?.stop()
            musicWatcher = nil
            musicScript = nil
        }
        updateSourceRate()
        controller?.desiredSampleRate = desiredSampleRate
    }

    private func musicFormatChanged(_ rate: Double, bits: Int) {
        guard rate != musicRate || bits != musicBitDepth else { return }
        musicRate = rate
        musicBitDepth = bits
        updateSourceRate()
    }

    // Ask the scripting interface once on track change or playback start; right after a track change it may not be readable yet, so retry after 1 s, up to 3 times
    private func readTrackSampleRate(attempt: Int = 0) {
        musicScript?.read { [weak self] rate in
            guard let self else { return }
            if let rate {
                if rate != self.scriptRate { BBLogMessage("Music scripting interface: current track \(rate / 1000) kHz") }
                self.scriptRate = rate
                self.updateSourceRate()
            } else if attempt < 2, !(self.musicScript?.denied ?? true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.readTrackSampleRate(attempt: attempt + 1) }
            } else {
                self.updateSourceRate()
            }
        }
    }

    // Bit depth: the last lossless-decoder log entry with the same sample rate logged before this track started playing (the preloaded next track creates its decoder only after playback starts;
    // observed: playback started 04:20:58, the next track's 44.1k/16 decoder was created at 04:21:00.9); if none matches use what PlaybackEvents reports, failing that show no bit depth
    private func trackBitDepth(for rate: Double) -> Int {
        let cutoff = trackStartedAt.addingTimeInterval(1.5)
        if let entry = decoderFormats.last(where: { $0.rate == rate && $0.date <= cutoff }) { return entry.bits }
        return musicRate == rate ? musicBitDepth : 0
    }

    // Use Apple Music's track format only while it plays; 0 once it stops or quits, falling back to the device's current sample rate
    private func updateSourceRate() {
        let playing = musicWatcher?.isPlaying ?? false
        let useScript = scriptRate > 0 && !(musicScript?.denied ?? true)
        let rate = playing ? (useScript ? scriptRate : musicRate) : 0
        let bits = rate > 0 ? trackBitDepth(for: rate) : 0
        guard rate != sourceRate || bits != sourceBitDepth else { return }
        sourceRate = rate
        sourceBitDepth = bits
        if rate > 0 {
            BBLogMessage("Apple Music current track: \(rate / 1000) kHz\(bits > 0 ? "/\(bits)-bit" : "") (\(useScript ? "scripting interface" : "log"))")
        }
        if settings.sampleRateMode == .followSource { controller?.desiredSampleRate = rate }
    }
}
