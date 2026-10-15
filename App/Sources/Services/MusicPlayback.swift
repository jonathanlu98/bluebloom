// Whether Apple Music is playing: "follow source" uses the track sample rate Music reports only while it plays; once stopped or quit, it goes back to the device's current sample rate
// (when a player that changes the output sample rate itself changes the virtual device, Blue Bloom follows).
// Every play, pause and stop, Music posts the distributed notification com.apple.Music.playerInfo; userInfo's Player State is Playing/Paused/Stopped
// (both strings are in the Music binary, checked 2026-10-14); quitting is detected via NSWorkspace's app-termination notification. Both are real-time, unlike the log, which is batched for 5 s.
// At launch no notification has arrived yet, so guess from whether Music is running; the app is not sandboxed, so the notification's userInfo is not stripped.
import AppKit

@MainActor
final class MusicPlaybackWatcher {
    nonisolated private static let bundleID = "com.apple.Music"
    private(set) var isPlaying = false
    var onChange: ((Bool) -> Void)?
    // Called each time "Playing" arrives (sent on playback start and on track change): read the current track's sample rate
    var onPlaying: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard observers.isEmpty else { return }
        isPlaying = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            let state = note.userInfo?["Player State"] as? String
            MainActor.assumeIsolated {
                self?.update(state == "Playing")
                if state == "Playing" { self?.onPlaying?() }
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.update(false) }
        }))
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func update(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        onChange?(playing)
    }
}

// Read the current track's sample rate through Music's scripting interface (sample rate of current track, Hz; observed 2026-10-14: a streamed 96k track reads 96000).
// Ask for "current track" directly instead of guessing which log entry belongs to which track as log reading must (the preloaded next track interferes, and Music sometimes logs no format for a long stretch).
// LosslessSwitcher and Choritsu both read the log; Choritsu's script only reads the track name and such, and MediaRemote returns nothing to third parties since macOS 15.4.
// The first time, macOS prompts "Allow Blue Bloom to control Music"; once refused (-1743) we stop trying and the caller falls back to reading the log.
// Use an osascript subprocess instead of NSAppleScript: the latter only works on the main thread and freezes the UI while the permission prompt waits for the user
@MainActor
final class MusicSampleRateReader {
    private(set) var denied = false
    private var running = false
    private var lastError = ""

    // Completes on the main thread: sample rate (Hz), nil if it cannot be read
    func read(_ completion: @escaping (Double?) -> Void) {
        guard !denied, !running else { return }
        running = true
        // Check that it is running first: a plain tell would launch Music if it is not open
        let script = """
        if application "Music" is running then
            tell application "Music"
                if player state is playing or player state is paused then return (sample rate of current track) as text
            end tell
        end if
        return ""
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.running = false
                    if status != 0, error.contains("-1743") {
                        self.denied = true
                        BBLogMessage("Not allowed to control Music: reading the sample rate from the Apple Music log instead")
                    } else if status != 0 {
                        // Other errors (Music busy, timeout, etc.): log each distinct one only once
                        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
                        if message != self.lastError { BBLogMessage("Failed to read the sample rate of Music's current track: \(message)") }
                        self.lastError = message
                    }
                    completion(Double(text).flatMap { $0 > 0 ? $0 : nil })
                }
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            completion(nil)
        }
    }
}

