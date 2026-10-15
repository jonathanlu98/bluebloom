// Headphone battery level, from the same sources as macOS Control Center:
// - When macOS holds the headphones' hands-free (HFP) link, bluetoothd receives the battery level (Apple's AT+IPHONEACCEV, the standard HF indicator AT+BIEV, AirPods' left/right buds and case),
//   publishes it as a powerd accessory power source (visible in pmset -g accps; AirPods get one entry each for left bud, right bud and case),
//   and also records it in IOBluetoothDevice's private batteryPercent* properties (forwarded to CoreBluetooth's CBClassicPeer; 0 means unknown).
//   When reading, look up the accessory power source by name first, then fall back to IOBluetoothDevice.
// - While Blue Bloom holds HFP, macOS does not receive it; the engine's hands-free gateway receives it (supporting both report types) and publishes it as a system accessory power source,
//   so places that read accessory power sources, such as pmset -g accps and the battery widget, show it as usual.
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps

struct BatteryLevels: Equatable {
    var main: Int?          // single battery for the whole device (over-ear headphones, speakers, etc.)
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }
    var partCount: Int { [main, left, right, caseLevel].compactMap { $0 }.count }
    // Lowest level among the headphones themselves (used when the list shows a single number)
    var lowest: Int? { [main, left, right].compactMap { $0 }.min() ?? caseLevel }

    static func single(_ percent: Int) -> BatteryLevels? {
        percent >= 0 ? BatteryLevels(main: min(percent, 100)) : nil
    }

    // Battery level recorded by macOS; nil when the headphones are not connected or have not reported
    static func system(_ device: IOBluetoothDevice, accessories: [String: BatteryLevels]) -> BatteryLevels? {
        if let name = device.name, let levels = accessories[name] { return levels }
        return bluetooth(device)
    }

    // powerd's accessory power sources, grouped by name. IOPSCopyPowerSourcesByType is exported by IOKit but not declared in the SDK headers; 4 = accessories only (IOKitUser's kIOPSSourceForAccessories)
    private typealias CopySourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let copySourcesByType = dlsym(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW), "IOPSCopyPowerSourcesByType")
        .map { unsafeBitCast($0, to: CopySourcesByType.self) }

    static func accessories() -> [String: BatteryLevels] {
        guard let info = copySourcesByType?(4)?.takeRetainedValue() else { return [:] }
        var result: [String: BatteryLevels] = [:]
        for source in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == "Accessory Source", details[kIOPSIsPresentKey] as? Bool != false,
                  let name = details[kIOPSNameKey] as? String, let current = details[kIOPSCurrentCapacityKey] as? Int else { continue }
            let maximum = details[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? min(100, max(0, current * 100 / maximum)) : current
            var levels = result[name] ?? BatteryLevels()
            switch details["Part Identifier"] as? String {
            case "Left": levels.left = percent
            case "Right": levels.right = percent
            case "Case": levels.caseLevel = percent
            default: levels.main = percent
            }
            result[name] = levels
        }
        return result
    }

    static func bluetooth(_ device: IOBluetoothDevice) -> BatteryLevels? {
        func read(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)), let value = device.value(forKey: key) as? Int, value > 0 else { return nil }
            return min(value, 100)
        }
        let levels = BatteryLevels(main: read("batteryPercentSingle"), left: read("batteryPercentLeft"),
                                   right: read("batteryPercentRight"), caseLevel: read("batteryPercentCase"))
        return levels.isEmpty ? nil : levels
    }
}

// Publish the battery level received by Blue Bloom's hands-free gateway as a system accessory power source, with fields written the way bluetoothd publishes them (visible in pmset -g accps and IOPSCopyPowerSourcesByType).
// The IOPSCreatePowerSource family is exported by IOKit but not declared in the SDK headers, so it is looked up by symbol; powerd reclaims it when the process exits
@MainActor
final class BatteryPublisher {
    private typealias Create = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> IOReturn
    private typealias SetDetails = @convention(c) (OpaquePointer, CFDictionary) -> IOReturn
    private typealias Release = @convention(c) (OpaquePointer) -> IOReturn

    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create = dlsym(library, "IOPSCreatePowerSource").map { unsafeBitCast($0, to: Create.self) }
    private static let setDetails = dlsym(library, "IOPSSetPowerSourceDetails").map { unsafeBitCast($0, to: SetDetails.self) }
    private static let release = dlsym(library, "IOPSReleasePowerSource").map { unsafeBitCast($0, to: Release.self) }

    private var source: OpaquePointer?
    private var published: NSDictionary?

    func update(name: String?, identifier: UUID?, percent: Int) {
        guard let name, percent >= 0, let create = Self.create, let setDetails = Self.setDetails else {
            remove()
            return
        }
        var details: [String: Any] = [
            "Name": name,
            "Type": "Accessory Source",
            "Transport Type": "Bluetooth",
            "Accessory Category": "Headphone",
            "Part Identifier": "Single",
            "Is Present": true,
            "Current Capacity": min(percent, 100),
            "Max Capacity": 100,
            "Low Warn Level": 20,
            "Power Source State": "Battery Power",
            "Is Charging": false,
        ]
        if let identifier { details["Accessory Identifier"] = identifier.uuidString }
        let dictionary = details as NSDictionary
        if dictionary == published { return }
        if source == nil {
            var created: OpaquePointer?
            guard create(&created) == kIOReturnSuccess, let created else { return }
            source = created
        }
        if let source, setDetails(source, dictionary) == kIOReturnSuccess {
            if published == nil { BBLogMessage("Published headphone battery level to macOS: \(name) \(percent)%") }
            published = dictionary
        }
    }

    func remove() {
        guard let source else { return }
        _ = Self.release?(source)
        self.source = nil
        published = nil
    }
}
