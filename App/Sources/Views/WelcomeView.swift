// First-run notice: shown on first launch to explain what Blue Bloom does to this Mac; the headphones aren't taken over until it is accepted (AppModel noticePending).
// Bump noticeVersion when the content changes materially, and users will see it once more
import AppKit
import SwiftUI

struct WelcomeView: View {
    static let noticeVersion = 2

    @Environment(AppModel.self) private var model
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BloomMark(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Blue Bloom").font(.title2.weight(.semibold))
                    Text("Before you start, here's what Blue Bloom does on your Mac.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                item("headphones", "It takes your headphones' Bluetooth audio over from macOS to stream it with better codecs. When you quit or turn it off, the headphones go back to macOS. Headphones that only support codecs macOS already uses stay with macOS.")
                item("mic.slash", "While Blue Bloom is connected, other apps can't use the headphones' microphone — calls, dictation and recording included.")
                item("hifispeaker", "It adds a virtual audio device named Blue Bloom. Installing it needs an administrator password once.")
                item("exclamationmark.triangle", "It relies on private macOS interfaces, so a macOS update can break it. If that happens, turn Blue Bloom off or quit it.")
                item("trash", "To remove it completely, use Uninstall Blue Bloom in Settings › Advanced.")
            }
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Button("Continue") {
                    model.acceptNotice()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func item(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.blue).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
