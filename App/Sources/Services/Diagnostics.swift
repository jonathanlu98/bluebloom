// Diagnostics for bug reports, from the About pane:
//   - "Copy Diagnostics": a text summary (build, system, settings, audio, connection, remembered headphones with their
//     Device ID record and the codec capability bytes they declared). It has no device names or addresses, so it can be
//     pasted into a public issue as is.
//   - "Export Diagnostics…": a zip on the Desktop with that summary, Blue Bloom's logs (current and previous), the
//     Bluetooth section of System Information and the last two hours of the macOS Bluetooth daemon's connection log. The
//     daemon's log shows what the headphones themselves answered (connection refusals, macOS's own connection attempts),
//     which is often the only way to understand headphones the developer doesn't have.
// In everything exported, Bluetooth addresses keep only their first three bytes (the vendor prefix) and the home folder
// becomes "~". Device names stay in the logs because they tell which headphone model it is.
import AppKit
import BlueBloomEngine
import IOBluetooth

@MainActor
enum Diagnostics {
    // MARK: Summary

    static func summary(_ model: AppModel) -> String {
        let settings = model.settings
        var lines = [
            "Blue Bloom \(AppModel.versionDescription)",
            "Codecs compiled in: \(A2DPCodec.allCodecs().map(\.identifier.rawValue).joined(separator: ", "))",
            "macOS \(AppModel.osVersion) (\(AppModel.osBuild))\(Compatibility.isTested ? "" : ", untested"), \(AppModel.macModel)",
            "Language: \(Locale.preferredLanguages.first ?? "?")",
        ]
        func section(_ title: String) { lines += ["", "[\(title)]"] }

        section("Settings")
        lines.append("enabled: \(settings.enabled), open at login: \(model.loginItemEnabled)")
        lines.append("sample rate: \(settings.sampleRateMode.rawValue), maximum \(settings.maxSampleRate > 0 ? "\(Int(settings.maxSampleRate)) Hz" : "no limit")")
        lines.append("codec priority: \(settings.codecPriority.map(\.rawValue).joined(separator: ", "))")
        lines.append("disabled codecs: \(settings.disabledCodecs.isEmpty ? "none" : settings.disabledCodecs.map(\.rawValue).sorted().joined(separator: ", "))")
        let tiers = settings.codecPresets.map { codec, id -> String in
            guard let preset = A2DPCodec.codec(id: codec)?.preset(withID: id) else { return "\(codec.rawValue)=\(id)" }
            return "\(codec.rawValue)=\(preset.isAdaptive ? "adaptive" : "\(Int(preset.kbps)) kbps")"
        }
        lines.append("bitrate tiers: \(tiers.isEmpty ? "defaults" : tiers.sorted().joined(separator: ", "))")
        lines.append("AAC: \(settings.aacBitrate > 0 ? "\(settings.aacBitrate) bps" : "default bitrate") \(settings.aacVBR ? "VBR" : "CBR"), adaptive \(settings.aacAdaptive); SBC: XQ \(settings.sbcXQ), adaptive \(settings.sbcAdaptive)")
        lines.append("volume sync: \(settings.volumeSync), switch output automatically: \(settings.autoSwitchOutput), menu bar: \(settings.menuBarStyle.rawValue)")

        section("Audio")
        let driver: String
        switch model.driverState {
        case .current: driver = "installed (\(DriverManager.version(at: DriverManager.installedPath) ?? "?"))"
        case .outdated: driver = "outdated (\(DriverManager.version(at: DriverManager.installedPath) ?? "?"), app has \(DriverManager.version(at: DriverManager.bundledPath) ?? "?"))"
        case .missing: driver = "not installed"
        }
        lines.append("audio device: \(driver), ready: \(model.virtualDeviceReady), is the output: \(model.blueBloomIsOutput)")
        if model.deviceRate > 0 {
            lines.append("device format: \(Int(model.deviceRate)) Hz, \(model.deviceBitDepth)-bit\(model.deviceFloat ? " float" : "")")
        }
        if model.sourceRate > 0 {
            lines.append("source: \(Int(model.sourceRate)) Hz\(model.sourceBitDepth > 0 ? ", \(model.sourceBitDepth)-bit" : "")")
        }

        section("Connection")
        lines.append("status: \(AppModel.statusName(model.status))")
        if let configuration = model.configuration {
            lines.append("stream: \(configuration.codec.rawValue), \(Int(configuration.sampleRate)) Hz, \(configuration.bitsPerSample)-bit, nominal \(Int(configuration.nominalKbps)) kbps, recent \(Int(model.liveKbps)) kbps")
        }
        if model.headsetDelay > 0 { lines.append("headphone delay: \(Int(model.headsetDelay)) ms") }
        if let fallback = model.fallbackCodec { lines.append("fell back from \(fallback.rawValue): reason \(model.fallbackReason.rawValue)") }
        let avrcp = model.remoteVolume >= 0 ? "connected, volume \(model.remoteVolume)/127" : model.remoteControlBlocked ? "refused (software volume)" : "not connected"
        lines.append("AVRCP: \(avrcp)")
        if model.battery >= 0 { lines.append("battery: \(model.battery)%") }

        section("Headphones")
        let records = model.devices.records.sorted { ($0.value.lastSeen ?? .distantPast) > ($1.value.lastSeen ?? .distantPast) }
        if records.isEmpty { lines.append("none remembered") }
        for (index, (address, record)) in records.enumerated() {
            let device = model.devices.device(address)
            var state = [address == settings.activeDevice ? "selected" : nil, device?.isConnected == true ? "connected" : "not connected"].compactMap { $0 }
            state.append("mode \(record.mode.rawValue)")
            if let preferred = record.preferredCodec { state.append("preferred \(preferred.rawValue)") }
            if let seen = record.lastSeen { state.append("last seen \(seen.formatted(.iso8601.year().month().day()))") }
            lines.append("#\(index + 1): \(state.joined(separator: ", "))")
            if let bluetooth = IOBluetoothDevice(addressString: address) {
                lines.append("    \(A2DPDeviceIdentity(bluetooth))")
            }
            for codec in record.codecs {
                let rates = codec.sampleRates.map { "\($0.intValue)" }.joined(separator: "/")
                lines.append("    \(codec.name)\(rates.isEmpty ? "" : " (\(rates) Hz)"): \(hex(codec.element))")
            }
            if !record.maxKbps.isEmpty {
                lines.append("    bitrate limits: \(record.maxKbps.map { "\($0.key) \(Int($0.value)) kbps" }.sorted().joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: Export

    // How far back the Bluetooth daemon's log goes in the bundle
    nonisolated private static let systemLogWindow = "2h"
    // The daemon's connection-related categories, without the per-request noise of Blue Bloom's own connection attempts
    // (dozens of refused requests per second while it grabs a channel)
    nonisolated private static let systemLogPredicate = """
        process == "bluetoothd" AND category IN {"Server.XPC", "Server.L2CAPChannel", "Stack.L2CAP", "Stack.AVDTP", "Server.Core", \
        "Server.Remote", "Server.A2DP", "CBStackDeviceMonitor", "Server.App", "Server.RFCOMMChannel", "Stack.RFCOMM", "Stack.DEVMGR", \
        "Server.FastConnect", "Server.Handsfree", "Stack.HCI"} AND NOT (eventMessage CONTAINS "could not connect to device" \
        OR eventMessage CONTAINS "trying to connect to device" OR eventMessage CONTAINS "handleOpenL2CAPChannel" \
        OR eventMessage CONTAINS "handleOpenRFCOMMChannel" OR eventMessage CONTAINS "CBClassicMsgIdOpenL2CAPChannel" \
        OR eventMessage CONTAINS "CBMsgIdPeerOpenRFCOMM" OR eventMessage CONTAINS "result: 0x70b" OR eventMessage CONTAINS "result: 0x70c" \
        OR eventMessage CONTAINS "result: 0x76d" OR eventMessage CONTAINS "CBMsgIdRetrieve" OR eventMessage CONTAINS "PairingAgentRetrieve" \
        OR eventMessage CONTAINS "sending sdp data" OR eventMessage CONTAINS "GetPeerState" OR eventMessage CONTAINS "Spatial Mode" \
        OR eventMessage CONTAINS "BundleID does not exist")
        """

    // Writes BlueBloom-Diagnostics-<date>.zip to the Desktop; the work runs off the main thread (System Information and
    // the system log take a few seconds). Completion on the main thread with the zip's location or an error message.
    static func export(_ model: AppModel, completion: @escaping @MainActor (Result<URL, ExportError>) -> Void) {
        let summary = summary(model)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "BlueBloom-Diagnostics-\(formatter.string(from: Date()))"
        BBLogMessage("Exporting diagnostics: \(name).zip")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try write(name: name, summary: summary) }.mapError { ExportError(message: "\($0)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .failure(let error) = result { BBLogMessage("Exporting diagnostics failed: \(error.message)") }
                    completion(result)
                }
            }
        }
    }

    struct ExportError: Error {
        let message: String
    }

    nonisolated private static func write(name: String, summary: String) throws -> URL {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(name)
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        var masker = Masker()
        func save(_ text: String, _ file: String) throws {
            try masker.mask(text).write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try save(summary + "\n", "diagnostics.txt")
        for (url, file) in [(LogFile.url, "BlueBloom.log"), (LogFile.previousURL, "BlueBloom.1.log")] {
            if let data = manager.contents(atPath: url.path) { try save(String(decoding: data, as: UTF8.self), file) }
        }
        try save(run("/usr/sbin/system_profiler", ["SPBluetoothDataType"]), "bluetooth-system-information.txt")
        try save(run("/usr/bin/log", ["show", "--last", systemLogWindow, "--style", "compact", "--predicate", systemLogPredicate]),
                 "bluetoothd.log")
        let desktop = manager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? manager.homeDirectoryForCurrentUser
        let zip = desktop.appendingPathComponent(name + ".zip")
        try? manager.removeItem(at: zip)
        _ = try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path])
        return zip
    }

    // Runs a tool and returns its output; the output goes through a temporary file, so large output can't fill a pipe
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = process.standardOutput
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self)
        if process.terminationStatus != 0 {
            throw ExportError(message: "\(tool) exited with status \(process.terminationStatus): \(text.suffix(300))")
        }
        return text
    }

    // Masks Bluetooth addresses (keeping the vendor prefix and numbering the rest, so the same device keeps the same
    // number in every file) and the home folder path
    private struct Masker {
        private var numbers: [String: Int] = [:]
        private static let address = try! NSRegularExpression(
            pattern: "\\b([0-9A-Fa-f]{2})([:-])([0-9A-Fa-f]{2})\\2([0-9A-Fa-f]{2})\\2[0-9A-Fa-f]{2}\\2[0-9A-Fa-f]{2}\\2[0-9A-Fa-f]{2}\\b")
        private static let home = FileManager.default.homeDirectoryForCurrentUser.path

        mutating func mask(_ text: String) -> String {
            let source = text.replacingOccurrences(of: Self.home, with: "~")
            let ns = source as NSString
            var result = ""
            var last = 0
            for match in Self.address.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let full = ns.substring(with: match.range)
                let key = full.lowercased().replacingOccurrences(of: "-", with: ":")
                let number = numbers[key] ?? (numbers.count + 1)
                numbers[key] = number
                let separator = ns.substring(with: match.range(at: 2))
                let prefix = [1, 3, 4].map { ns.substring(with: match.range(at: $0)) }.joined(separator: separator)
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                result += "\(prefix)\(separator)xx\(separator)xx\(separator)#\(number)"
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            return result
        }
    }
}
