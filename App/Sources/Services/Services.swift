// Miscellaneous services: log file, virtual device driver installation, headphone buttons to media commands, login item, AirDrop suppression.
import AppKit
import BlueBloomEngine
import BlueBloomSupport
import Foundation
import ServiceManagement

// MARK: - Log

enum LogFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BlueBloom.log")
    // Cleared at launch when larger than this, so it doesn't grow without bound
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    static func start() {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        if size == nil || size! > maxBytes { manager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        let queue = DispatchQueue(label: "bluebloom.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        BBLogSetSink { line in
            let stamped = "\(formatter.string(from: Date())) \(line)\n"
            queue.async { handle.write(Data(stamped.utf8)) }
        }
    }
}

// MARK: - Virtual device driver

enum DriverState: Equatable {
    case missing
    case outdated
    case current
}

enum DriverManager {
    static let installDirectory = "/Library/Audio/Plug-Ins/HAL"
    static let driverName = "BlueBloom.driver"

    static var bundledPath: String { (Bundle.main.resourcePath ?? "") + "/" + driverName }
    static var installedPath: String { installDirectory + "/" + driverName }

    static func version(at path: String) -> String? {
        NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleVersion"] as? String
    }

    // Decided by the driver's CFBundleVersion (bump it in Driver/Info.plist whenever the driver changes)
    static var state: DriverState {
        let manager = FileManager.default
        if manager.fileExists(atPath: installedPath) {
            return version(at: installedPath) == version(at: bundledPath) ? .current : .outdated
        }
        return .missing
    }

    // Needs the administrator password; restarts coreaudiod (playing audio drops out for a second or two).
    // The app bundle usually sits in a user-writable location, so the driver inside could be swapped before the password is entered: after copying as root, verify the installed copy
    // against the signing requirement recorded at build time (driverDesignatedRequirement, see App/BUILD.bazel); on mismatch delete it and don't restart coreaudiod
    static func install() -> String? {
        guard FileManager.default.fileExists(atPath: bundledPath) else { return "Driver not found in app bundle" }
        let arguments = [bundledPath, installDirectory, installedPath, driverDesignatedRequirement]
        if let error = callAppleScriptHandler("installdriver", in: installScript, arguments: arguments) {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            BBLogMessage("Virtual device install did not complete: \(message)")
            return message
        }
        BBLogMessage("Virtual device installed, waiting for the system audio service to reload")
        return nil
    }

    // The script source is constant: paths and the signing requirement are passed as handler parameters, not spliced into the source, and escaped with quoted form of before reaching the shell.
    // As root, in order: reject symlinks in the source tree (so cp -R doesn't copy links into HAL and verification doesn't follow them) → copy to a temp folder in the same directory →
    // verify against the signing requirement recorded at build time → atomic replace (any failure removes the temp folder and keeps the old driver). killall failing (coreaudiod not running) doesn't count as a failure.
    private static let installScript = #"""
        on installdriver(sourcePath, installDirectory, installedPath, requirement)
            set cmd to "set -e" & linefeed & ¬
                "src=" & (quoted form of sourcePath) & linefeed & ¬
                "dir=" & (quoted form of installDirectory) & linefeed & ¬
                "dst=" & (quoted form of installedPath) & linefeed & ¬
                "tmp=\"$dir/.bluebloom-install.$$\"" & linefeed & ¬
                "cleanup() { /bin/rm -rf \"$tmp\"; }" & linefeed & ¬
                "trap cleanup EXIT" & linefeed & ¬
                "[ -d \"$src\" ] && [ ! -L \"$src\" ]" & linefeed & ¬
                "if /usr/bin/find \"$src\" -type l | /usr/bin/grep -q .; then echo 'driver bundle contains symlinks' >&2; exit 9; fi" & linefeed & ¬
                "/bin/mkdir -p \"$dir\"" & linefeed & ¬
                "/bin/rm -rf \"$tmp\"" & linefeed & ¬
                "/bin/mkdir \"$tmp\"" & linefeed & ¬
                "/bin/cp -R -X \"$src\" \"$tmp/\"" & linefeed & ¬
                "target=\"$tmp/$(/usr/bin/basename \"$dst\")\"" & linefeed & ¬
                "[ ! -L \"$target\" ]" & linefeed & ¬
                "/usr/bin/codesign --verify --strict -R " & (quoted form of ("=" & requirement)) & " \"$target\"" & linefeed & ¬
                "/bin/rm -rf \"$dst\"" & linefeed & ¬
                "/bin/mv \"$target\" \"$dst\"" & linefeed & ¬
                "{ /usr/bin/killall coreaudiod 2>/dev/null || true; }"
            do shell script cmd with administrator privileges
        end installdriver
        """#

    // For uninstall: delete the installed driver and restart coreaudiod (needs the administrator password); does nothing when not installed
    static func uninstall() -> String? {
        guard FileManager.default.fileExists(atPath: installedPath) else { return nil }
        if let error = callAppleScriptHandler("uninstalldriver", in: uninstallScript, arguments: [installedPath]) {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            BBLogMessage("Virtual device removal did not complete: \(message)")
            return message
        }
        BBLogMessage("Virtual device removed")
        return nil
    }

    private static let uninstallScript = #"""
        on uninstalldriver(installedPath)
            do shell script "/bin/rm -rf " & (quoted form of installedPath) & " && { /usr/bin/killall coreaudiod 2>/dev/null || true; }" with administrator privileges
        end uninstalldriver
        """#

    // Calls an AppleScript handler, passing the arguments in an Apple event. Four-char codes from OpenScripting's ASRegistry.h:
    // kASAppleScriptSuite = 'ascr', kASSubroutineEvent = 'psbr', keyASSubroutineName = 'snam'; the handler name must be all lowercase
    private static func callAppleScriptHandler(_ name: String, in source: String, arguments: [String]) -> NSDictionary? {
        guard let script = NSAppleScript(source: source) else { return [NSAppleScript.errorMessage: "Invalid AppleScript"] as NSDictionary }
        let event = NSAppleEventDescriptor(eventClass: fourCharCode("ascr"), eventID: fourCharCode("psbr"), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: fourCharCode("snam"))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(parameters, forKeyword: fourCharCode("----"))  // keyDirectObject
        var error: NSDictionary?
        script.executeAppleEvent(event, error: &error)
        return error
    }

    private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}

// MARK: - Headphone buttons → the system's "Now Playing" app

// MediaRemote is a private framework; the MRMediaRemoteSendCommand prototype and command numbers (kMRPlay=0 … kMRPreviousTrack=5) come from community reverse engineering, and observed behavior is authoritative
enum MediaKeys {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let send: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    static func handle(_ operation: UInt8, volume: VolumeSync?) {
        let command: UInt32
        switch Int(operation) {
        case Int(AvrcpOperation.play.rawValue): command = 0
        case Int(AvrcpOperation.pause.rawValue): command = 1
        case Int(AvrcpOperation.stop.rawValue): command = 3
        case Int(AvrcpOperation.forward.rawValue): command = 4
        case Int(AvrcpOperation.backward.rawValue): command = 5
        case Int(AvrcpOperation.volumeUp.rawValue): volume?.stepVolume(1); return
        case Int(AvrcpOperation.volumeDown.rawValue): volume?.stepVolume(-1); return
        default:
            BBLogMessage(String(format: "Headphone button 0x%02X not handled", operation))
            return
        }
        let ok = send?(command, nil) ?? false
        BBLogMessage(String(format: "Headphone button 0x%02X → media command %u: %@", operation, command, ok ? "sent" : "send failed"))
    }
}

// MARK: - Login item

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            BBLogMessage("Failed to \(enabled ? "add" : "remove") login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - macOS version

// The private XPC protocol for talking to bluetoothd directly (message numbers, key names, call order) was observed on these major macOS versions; a system update may change it.
// On untested versions the headphones aren't taken over by default (left to macOS) until the user confirms in the setup checklist; the confirmation is stored per major version and asked again on a new one
enum Compatibility {
    static let testedMajorVersions: Set<Int> = [27]

    static var majorVersion: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    static var isTested: Bool { testedMajorVersions.contains(majorVersion) }

    static var versionText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}

// MARK: - Suppress AirDrop/AirPlay while streaming

// The flag file is created only when "switch on + streaming"; whether suppression actually happens is up to /usr/local/libexec/aptx-awdl-guard (the file path is a contract with it and must not change)
enum AwdlGuard {
    static let flagPath = "/Users/Shared/.aptx-awdl-suppress"

    static func update(suppress: Bool) {
        let manager = FileManager.default
        let present = manager.fileExists(atPath: flagPath)
        guard suppress != present else { return }
        if suppress {
            manager.createFile(atPath: flagPath, contents: nil)
            BBLogMessage("AirDrop/AirPlay paused")
        } else {
            try? manager.removeItem(atPath: flagPath)
            BBLogMessage("AirDrop/AirPlay resumed")
        }
    }

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: "/usr/local/libexec/aptx-awdl-guard") }
}
