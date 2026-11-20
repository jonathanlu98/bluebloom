// Privileged AWDL helper management and socket client.
// Installs /Library/PrivilegedHelperTools/app.bluebloom.awdl-helper as a LaunchDaemon (on demand,
// verified against its build-time designated requirement) and communicates over a Unix stream socket
// so a crash or quit immediately restores awdl0 up.
import Darwin
import Foundation

enum AwdlHelperManager {
    static let label = "app.bluebloom.awdl-helper"
    static let expectedVersion = "1"
    static let installDirectory = "/Library/PrivilegedHelperTools"
    static let installedPath = installDirectory + "/" + label
    static let plistPath = "/Library/LaunchDaemons/" + label + ".plist"
    static let socketPath = "/var/run/" + label + ".sock"

    static var bundledPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BlueBloomAWDLHelper").path
    }

    static var isInstalledOnDisk: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: installedPath) && fm.fileExists(atPath: plistPath)
    }

    // Checks both on-disk installation and live daemon version over the Unix socket
    static var state: DriverState {
        guard isInstalledOnDisk else { return .missing }
        return liveVersion() == expectedVersion ? .current : .outdated
    }

    // Queries the running daemon with '?' (non-blocking, bounded to 500 ms so a busy kernel ioctl doesn't false-timeout); returns nil if unreachable
    static func liveVersion() -> String? {
        let fd = connectSocket(timeoutMs: 500)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var cmd: UInt8 = UInt8(ascii: "?")
        guard write(fd, &cmd, 1) == 1 else { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 500) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buf, buf.count)
        guard n >= 2, buf[0] == UInt8(ascii: "v") else { return nil }
        let raw = String(decoding: buf[1..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // Connects to the helper's Unix stream socket with a short non-blocking timeout
    static func connectSocket(timeoutMs: Int32) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            pathBytes.withUnsafeBytes { src in raw.copyMemory(from: src) }
        }
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if res < 0 && errno != EINPROGRESS {
            close(fd)
            return -1
        }
        if res < 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) > 0 else {
                close(fd)
                return -1
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0, soErr == 0 else {
                close(fd)
                return -1
            }
        }
        return fd
    }

    // Installs or updates the privileged helper and loads its LaunchDaemon (requires administrator password once).
    // Uses the same hardened copy-and-verify sequence as DriverManager (rejects symlinks, verifies against the build-time designated requirement).
    static func install() -> String? {
        guard FileManager.default.fileExists(atPath: bundledPath) else { return "AWDL helper not found in app bundle" }
        let args = [bundledPath, installDirectory, installedPath, plistPath, label, awdlHelperDesignatedRequirement]
        if let error = DriverManager.callAppleScriptHandler("installhelper", in: installScript, arguments: args) {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            BBLogMessage("AWDL helper install did not complete: \(message)")
            return message
        }
        BBLogMessage("AWDL helper installed and started")
        return nil
    }

    // Stops and removes the helper, restoring awdl0 up (requires administrator password)
    static func uninstall() -> String? {
        guard isInstalledOnDisk || FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let args = [label, plistPath, installedPath, socketPath]
        if let error = DriverManager.callAppleScriptHandler("uninstallhelper", in: uninstallScript, arguments: args) {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            BBLogMessage("AWDL helper removal did not complete: \(message)")
            return message
        }
        BBLogMessage("AWDL helper removed")
        return nil
    }

    private static let installScript = #"""
        on installhelper(sourcePath, installDirectory, installedPath, plistPath, daemonLabel, requirement)
            set cmd to "set -e" & linefeed & ¬
                "src=" & (quoted form of sourcePath) & linefeed & ¬
                "dir=" & (quoted form of installDirectory) & linefeed & ¬
                "dst=" & (quoted form of installedPath) & linefeed & ¬
                "plist=" & (quoted form of plistPath) & linefeed & ¬
                "label=" & (quoted form of daemonLabel) & linefeed & ¬
                "tmp=\"$dir/.bluebloom-awdl-install.$$\"" & linefeed & ¬
                "cleanup() { /bin/rm -rf \"$tmp\"; }" & linefeed & ¬
                "trap cleanup EXIT" & linefeed & ¬
                "[ -f \"$src\" ] && [ ! -L \"$src\" ]" & linefeed & ¬
                "/bin/mkdir -p \"$dir\"" & linefeed & ¬
                "/bin/rm -rf \"$tmp\"" & linefeed & ¬
                "/bin/mkdir \"$tmp\"" & linefeed & ¬
                "/bin/cp -X \"$src\" \"$tmp/helper\"" & linefeed & ¬
                "[ ! -L \"$tmp/helper\" ]" & linefeed & ¬
                "/usr/bin/codesign --verify --strict -R " & (quoted form of ("=" & requirement)) & " \"$tmp/helper\"" & linefeed & ¬
                "/usr/sbin/chown root:wheel \"$tmp/helper\"" & linefeed & ¬
                "/bin/chmod 755 \"$tmp/helper\"" & linefeed & ¬
                "/bin/launchctl bootout system/\"$label\" 2>/dev/null || true" & linefeed & ¬
                "/bin/mv -f \"$tmp/helper\" \"$dst\"" & linefeed & ¬
                "/bin/cat > \"$plist\" <<'PLIST'" & linefeed & ¬
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" & linefeed & ¬
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" & linefeed & ¬
                "<plist version=\"1.0\">" & linefeed & ¬
                "<dict>" & linefeed & ¬
                "  <key>Label</key><string>app.bluebloom.awdl-helper</string>" & linefeed & ¬
                "  <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/app.bluebloom.awdl-helper</string></array>" & linefeed & ¬
                "  <key>RunAtLoad</key><true/>" & linefeed & ¬
                "  <key>KeepAlive</key><true/>" & linefeed & ¬
                "  <key>ProcessType</key><string>Background</string>" & linefeed & ¬
                "</dict>" & linefeed & ¬
                "</plist>" & linefeed & ¬
                "PLIST" & linefeed & ¬
                "/usr/sbin/chown root:wheel \"$plist\"" & linefeed & ¬
                "/bin/chmod 644 \"$plist\"" & linefeed & ¬
                "/bin/launchctl bootstrap system \"$plist\""
            do shell script cmd with administrator privileges
        end installhelper
        """#

    private static let uninstallScript = #"""
        on uninstallhelper(daemonLabel, plistPath, installedPath, socketPath)
            set cmd to "{ /bin/launchctl bootout system/" & (quoted form of daemonLabel) & " 2>/dev/null || true; } && " & ¬
                "{ /sbin/ifconfig awdl0 up 2>/dev/null || true; } && " & ¬
                "/bin/rm -f " & (quoted form of plistPath) & " " & (quoted form of installedPath) & " " & (quoted form of socketPath)
            do shell script cmd with administrator privileges
        end uninstallhelper
        """#
}

// Persistent Unix socket client to AwdlHelper: keeps the connection open while suppressing so that
// any app exit or crash automatically closes the fd and lets the helper restore awdl0 immediately.
final class AwdlSuppressionClient {
    private let queue = DispatchQueue(label: "bluebloom.awdl-client")
    private var fd: Int32 = -1
    private var active = false

    func setSuppressed(_ want: Bool, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            if want {
                if !active || fd < 0 {
                    let ok = sendCommand(UInt8(ascii: "1"))
                    let changed = ok && !active
                    active = ok
                    if changed { BBLogMessage("Paused AWDL (AirDrop/AirPlay discovery) while streaming") }
                }
            } else {
                let wasActive = active
                if fd >= 0 {
                    _ = sendCommand(UInt8(ascii: "0"))
                    close(fd)
                    fd = -1
                }
                active = false
                if wasActive { BBLogMessage("Restored AWDL") }
            }
            let nowActive = active
            if let completion {
                DispatchQueue.main.async { completion(nowActive) }
            }
        }
    }

    // Non-blocking health check for an active suppression socket (detects daemon exit via POLLHUP/EOF without opening a probe socket)
    func checkActiveConnection(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            var alive = false
            if active && fd >= 0 {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let rc = poll(&pfd, 1, 0)
                if rc == 0 {
                    alive = true
                } else if rc > 0 && (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) == 0 {
                    var buf = [UInt8](repeating: 0, count: 16)
                    let n = read(fd, &buf, buf.count)
                    alive = n > 0 || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                }
                if !alive {
                    close(fd)
                    fd = -1
                    active = false
                }
            }
            DispatchQueue.main.async { completion(alive) }
        }
    }

    // Synchronous release used during quit / uninstall so awdl0 is restored before the process exits
    func releaseSync() {
        queue.sync { [self] in
            let wasActive = active
            if fd >= 0 {
                var cmd: UInt8 = UInt8(ascii: "0")
                _ = write(fd, &cmd, 1)
                close(fd)
                fd = -1
            }
            active = false
            if wasActive { BBLogMessage("Restored AWDL") }
        }
    }

    private func sendCommand(_ byte: UInt8) -> Bool {
        if fd < 0 {
            fd = AwdlHelperManager.connectSocket(timeoutMs: 200)
            guard fd >= 0 else { return false }
        }
        var cmd = byte
        if write(fd, &cmd, 1) == 1 {
            // Drain 2-byte reply ("1\n" or "0\n") if available so the socket stays clean
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 100) > 0 {
                var buf = [UInt8](repeating: 0, count: 16)
                let n = read(fd, &buf, buf.count)
                if n <= 0 {
                    close(fd)
                    fd = -1
                    return false
                }
            }
            return true
        }
        // Socket was closed (e.g. helper restarted): reconnect once and retry
        close(fd)
        fd = AwdlHelperManager.connectSocket(timeoutMs: 200)
        guard fd >= 0 else { return false }
        return write(fd, &cmd, 1) == 1
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}
