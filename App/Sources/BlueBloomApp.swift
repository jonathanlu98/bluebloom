// Entry point: menu bar panel, Settings window, Add Headphones window. Shown only in the menu bar (LSUIElement in Info.plist).
import AppKit
import BlueBloomEngine
import SwiftUI

@main
struct BlueBloomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }

        Window(Text("Add Headphones"), id: "pairing") {
            PairingView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var terminationSignal: DispatchSourceSignal?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // kill/pkill (SIGTERM) also takes the normal quit path: close the stream, hand back the headphones and sound output (the install script relies on this to replace the running version)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Can't terminate directly in a main-queue callback: terminateLater starts a nested event loop here, but the main queue is busy running this callback and can't re-enter,
        // and the stream-close callback and timeout are both queued on the main queue, so they never run (observed hang 2026-10-13 19:46:59). Start it from a run loop timer instead
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        }
        source.resume()
        terminationSignal = source
        // The About pane's "Welcome Notes…" must also open in demo mode, so hook it up before the early return for demo mode
        model.openWelcome = { [weak self] in self?.showWelcome() }
        if Snapshot.isActive {
            UserDefaults.standard.removePersistentDomain(forName: "app.bluebloom.snapshot")
            Snapshot.run(model: model)
            return
        }
        if model.noticePending { showWelcome() }
    }

    // First-run notice window (a menu bar app has no main window, so an AppKit window hosts it); if closed without accepting, it can be reopened from the setup checklist
    private func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(close: { [weak self] in self?.welcomeWindow?.close() }).environment(model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Welcome to Blue Bloom")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            welcomeWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    // Close the stream and hand the headphones and sound output back to macOS before quitting
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// Menu bar icon (template images from App/MenuBarIcons): a filled flower with the headphones cut out while streaming,
// an outlined flower with small headphones when connected, otherwise just the outlined flower; optionally with the codec
// name or live bitrate
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let name: String = {
            switch model.status {
            case .streaming: return "MenuBarStreaming"
            case .idle: return "MenuBarConnected"
            default: return "MenuBarDisconnected"
            }
        }()
        HStack(spacing: 3) {
            Image(nsImage: Self.icon(name))
            if model.isStreaming {
                switch model.settings.menuBarStyle {
                case .codec: Text(verbatim: Format.codecName(model.configuration?.codec))
                case .bitrate: Text(verbatim: Format.kbps(model.liveKbps)).monospacedDigit()
                case .icon: EmptyView()
                }
            }
        }
        .opacity(model.settings.enabled ? 1 : 0.55)
    }

    // NSImage(named:) picks up the 1x and 2x PNGs; template so macOS tints it for the menu bar appearance
    private static func icon(_ name: String) -> NSImage {
        let image = NSImage(named: name) ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
