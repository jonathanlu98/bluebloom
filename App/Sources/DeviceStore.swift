// Paired Bluetooth audio devices: connection state, per-headphone preferences (connection mode, preferred codec), last discovered codec capabilities; nearby device scanning and pairing.
import BlueBloomEngine
import Foundation
import IOBluetooth
import Observation

// Who connects these headphones
enum DeviceMode: String, CaseIterable, Identifiable {
    case automatic = "auto"  // Blue Bloom takes over when the headphones support a better codec than macOS (LDAC, aptX family), otherwise left to macOS
    case always              // Always taken over by Blue Bloom (allows SBC XQ, a chosen AAC bitrate, etc.)
    case system              // Never taken over; macOS always connects them itself
    var id: String { rawValue }
}

struct BluetoothDevice: Identifiable, Equatable {
    let address: String
    var name: String
    var isConnected: Bool
    var minorClass: UInt32
    // Battery level recorded by the system (bluetoothd); only available while the headphones are connected to macOS's HFP
    var battery: BatteryLevels?
    var id: String { address }

    // Pick an icon by device class and name
    var symbol: String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        if lowered.contains("beats") { return "beats.headphones" }
        switch minorClass {
        case UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker), UInt32(kBluetoothDeviceClassMinorAudioHiFi): return "hifispeaker"
        case UInt32(kBluetoothDeviceClassMinorAudioCar): return "car"
        case UInt32(kBluetoothDeviceClassMinorAudioPortable): return "speaker.wave.2"
        default: return "headphones"
        }
    }
}

// What is stored for each pair of headphones
struct DeviceRecord {
    var mode: DeviceMode = .automatic
    var preferredCodec: CodecID?
    var codecs: [RemoteCodec] = []
    // Highest bitrate per codec discovered at runtime (kbps, keyed by CodecID): the headphones can't take more (see A2DPEncoder mediaStalled)
    var maxKbps: [String: Double] = [:]
    var lastSeen: Date?
}

@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [BluetoothDevice] = []
    private(set) var records: [String: DeviceRecord] = [:]
    private(set) var bluetoothOn = true
    @ObservationIgnored private let watcher = BluetoothWatcher()
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let recordsKey = "DeviceRecords"

    @ObservationIgnored private var active = false

    init() {
        guard !Snapshot.isActive else { return }
        loadRecords()
    }

    // Only touch IOBluetooth after Bluetooth authorization (see AppModel.waitForBluetooth)
    func activate() {
        guard !active, !Snapshot.isActive else { return }
        active = true
        watcher.onChange = { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        watcher.start()
        refresh()
    }

    // Snapshot mode: don't touch Bluetooth, use the given data
    func loadPreview(devices: [BluetoothDevice], records: [String: DeviceRecord]) {
        self.devices = devices
        self.records = records
    }

    func refresh() {
        guard active, !Snapshot.isActive else { return }
        bluetoothOn = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let accessories = BatteryLevels.accessories()
        devices = paired.filter(Self.isAudioSink).map { device in
            let connected = device.isConnected()
            return BluetoothDevice(address: device.addressString ?? "", name: device.name ?? device.addressString ?? "?",
                                   isConnected: connected, minorClass: device.deviceClassMinor,
                                   battery: connected ? BatteryLevels.system(device, accessories: accessories) : nil)
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
        watcher.watchDisconnects(paired.filter { $0.isConnected() })
    }

    // Audio-class devices, or devices with an A2DP Sink (0x110B) in SDP
    static func isAudioSink(_ device: IOBluetoothDevice) -> Bool {
        if device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) { return true }
        let sink = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassAudioSink.rawValue))
        let services = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        return services.contains { $0.matchesUUIDArray([sink as Any]) }
    }

    func device(_ address: String?) -> BluetoothDevice? {
        devices.first { $0.address == address }
    }

    func record(_ address: String) -> DeviceRecord {
        records[address] ?? DeviceRecord()
    }

    func setMode(_ mode: DeviceMode, for address: String) {
        records[address, default: DeviceRecord()].mode = mode
        saveRecords()
    }

    func setPreferredCodec(_ codec: CodecID?, for address: String) {
        records[address, default: DeviceRecord()].preferredCodec = codec
        saveRecords()
    }

    func setCodecs(_ codecs: [RemoteCodec], for address: String) {
        records[address, default: DeviceRecord()].codecs = codecs
        records[address, default: DeviceRecord()].lastSeen = Date()
        saveRecords()
    }

    func setMaxKbps(_ kbps: Double, codec: CodecID, for address: String) {
        records[address, default: DeviceRecord()].maxKbps[codec.rawValue] = kbps
        saveRecords()
    }

    // Also clears the bitrate limits discovered at runtime; they are detected again next time
    func forgetCodecs(for address: String) {
        records[address]?.codecs = []
        records[address]?.maxKbps = [:]
        saveRecords()
    }

    private func loadRecords() {
        guard let stored = defaults.dictionary(forKey: Self.recordsKey) as? [String: [String: Any]] else { return }
        for (address, values) in stored {
            var record = DeviceRecord()
            record.mode = DeviceMode(rawValue: values["mode"] as? String ?? "") ?? .automatic
            record.preferredCodec = (values["preferredCodec"] as? String).map { CodecID(rawValue: $0) }
            if let data = values["codecs"] as? Data {
                // Older versions recorded every endpoint of the same codec (two per codec on the XM4); deduplicate when reading
                var seen = Set<String>()
                record.codecs = ((try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: RemoteCodec.self, from: data)) ?? [])
                    .filter { seen.insert($0.name).inserted }
            }
            record.maxKbps = values["maxKbps"] as? [String: Double] ?? [:]
            record.lastSeen = values["lastSeen"] as? Date
            records[address] = record
        }
    }

    // Snapshot and demo modes use mock data, which must never be written to the real settings (same app identifier as the release build)
    private func saveRecords() {
        guard !Snapshot.isActive else { return }
        var stored: [String: [String: Any]] = [:]
        for (address, record) in records {
            var values: [String: Any] = ["mode": record.mode.rawValue]
            if let codec = record.preferredCodec { values["preferredCodec"] = codec.rawValue }
            if !record.codecs.isEmpty, let data = try? NSKeyedArchiver.archivedData(withRootObject: record.codecs, requiringSecureCoding: true) {
                values["codecs"] = data
            }
            if !record.maxKbps.isEmpty { values["maxKbps"] = record.maxKbps }
            if let seen = record.lastSeen { values["lastSeen"] = seen }
            stored[address] = values
        }
        defaults.set(stored, forKey: Self.recordsKey)
    }
}

// IOBluetooth connect/disconnect notifications need Objective-C target-action
final class BluetoothWatcher: NSObject {
    var onChange: (() -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var powerTimer: Timer?
    private var lastPower: Bool?

    func start() {
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        // There is no public notification for the Bluetooth power switch; poll at a low rate
        powerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            let on = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
            if on != self?.lastPower {
                self?.lastPower = on
                self?.onChange?()
            }
        }
    }

    func watchDisconnects(_ devices: [IOBluetoothDevice]) {
        for device in devices {
            guard let address = device.addressString, disconnectNotifications[address] == nil else { continue }
            disconnectNotifications[address] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
    }

    // On macOS 27 connect notifications sometimes arrive from IOBluetooth's internal coordinatorQueue (observed 2026-10-13 20:08:08,
    // crashing on a main-thread assertion there); always hop back to the main thread before handling
    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainThread { self.onChange?() }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMainThread {
            notification.unregister()
            if let address = device.addressString { self.disconnectNotifications[address] = nil }
            self.onChange?()
        }
    }
}

// IOBluetooth notifications and delegate callbacks aren't guaranteed to be on the main thread (see BluetoothWatcher)
func onMainThread(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}

// Nearby device scanning (Classic Bluetooth inquiry) and pairing
@MainActor
@Observable
final class PairingModel {
    struct Found: Identifiable, Equatable {
        let address: String
        var name: String
        var isAudio: Bool
        var isPaired: Bool
        var id: String { address }
    }

    enum PairState: Equatable {
        case idle
        case pairing(String)
        case paired(String)
        case failed(String)
    }

    private(set) var found: [Found] = []
    private(set) var scanning = false
    private(set) var state: PairState = .idle
    @ObservationIgnored private let bridge = InquiryBridge()

    init() {
        bridge.onFound = { [weak self] device in MainActor.assumeIsolated { self?.add(device) } }
        bridge.onComplete = { [weak self] in MainActor.assumeIsolated { self?.scanning = false } }
        bridge.onPairFinished = { [weak self] address, ok in
            MainActor.assumeIsolated {
                self?.state = ok ? .paired(address) : .failed(address)
                if let index = self?.found.firstIndex(where: { $0.address == address }), ok { self?.found[index].isPaired = true }
            }
        }
    }

    // Snapshot mode: given scan results and pairing state
    func loadPreview(found: [Found], state: PairState) {
        self.found = found
        self.state = state
    }

    func startScan() {
        guard !Snapshot.isActive else { return }
        found = []
        state = .idle
        scanning = bridge.startInquiry()
    }

    func stopScan() {
        bridge.stopInquiry()
        scanning = false
    }

    func pair(_ address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else { return }
        stopScan()
        state = .pairing(address)
        if !bridge.pair(device) { state = .failed(address) }
    }

    private func add(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let entry = Found(address: address, name: device.name ?? address,
                          isAudio: device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio), isPaired: device.isPaired())
        if let index = found.firstIndex(where: { $0.address == address }) {
            found[index] = entry
        } else {
            found.append(entry)
        }
        found.sort { ($0.isAudio ? 0 : 1, $0.name) < ($1.isAudio ? 0 : 1, $1.name) }
    }
}

final class InquiryBridge: NSObject, IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate {
    var onFound: ((IOBluetoothDevice) -> Void)?
    var onComplete: (() -> Void)?
    var onPairFinished: ((String, Bool) -> Void)?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var pairing: IOBluetoothDevicePair?

    func startInquiry() -> Bool {
        inquiry?.stop()
        let inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry?.updateNewDeviceNames = true
        inquiry?.inquiryLength = 12
        self.inquiry = inquiry
        let result = inquiry?.start() ?? kIOReturnError
        BBLogMessage("Started scanning for nearby Bluetooth devices: IOReturn \(result)")
        return result == kIOReturnSuccess
    }

    func stopInquiry() {
        inquiry?.stop()
    }

    func pair(_ device: IOBluetoothDevice) -> Bool {
        let pairing = IOBluetoothDevicePair(device: device)
        pairing?.delegate = self
        self.pairing = pairing
        let result = pairing?.start() ?? kIOReturnError
        BBLogMessage("Started pairing \(device.name ?? "?"): IOReturn \(result)")
        return result == kIOReturnSuccess
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        if let device { onMainThread { self.onFound?(device) } }
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        if let device { onMainThread { self.onFound?(device) } }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        onMainThread { self.onComplete?() }
    }

    // Headphones usually pair with a "just confirm" method; confirm automatically
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        pin.data.0 = 0x30; pin.data.1 = 0x30; pin.data.2 = 0x30; pin.data.3 = 0x30
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let address = (sender as? IOBluetoothDevicePair)?.device()?.addressString ?? ""
        BBLogMessage("Pairing finished: \(address), IOReturn \(error)")
        onMainThread {
            self.onPairFinished?(address, error == kIOReturnSuccess)
            self.pairing = nil
        }
    }
}
