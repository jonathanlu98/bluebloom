import BlueBloomEngine
import SwiftUI

// Settings › Advanced › Experiments: the switches of BBExperiments, for investigating dropouts. Hidden until the version
// in Settings › About is Option-clicked (or `defaults write app.bluebloom BBShowExperiments -bool true`).
// The text is English only on purpose (Text(verbatim:), so it stays out of the string catalog): the switches come and go
// with the investigation, are not product features, and their names match the log lines and the command-line flags
struct ExperimentsSections: View {
    @AppStorage(BBExperimentsVisibleKey) private var visible = false
    @AppStorage(BBExperimentSlowABRKey) private var slowABR = false

    var body: some View {
        Section {
            ExperimentToggle(title: "Always use slow adaptive recovery",
                             detail: "Keep slow bitrate recovery even off 2.4 GHz Wi-Fi (automatic on 2.4 GHz; except LDAC, which manages its own).",
                             isOn: $slowABR)
            HStack {
                // Read on every update of the switches above; also lists the test harness values set with `defaults write`
                Text(verbatim: "On: \(BBExperiments.shared.summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    BBExperiments.resetAll()
                } label: {
                    Text(verbatim: "Turn All Off")
                }
                .disabled(BBExperiments.shared.activeCount == 0)
                Button {
                    visible = false
                } label: {
                    Text(verbatim: "Hide")
                }
            }
        } header: {
            Text(verbatim: "Experiments")
        } footer: {
            Text(verbatim: "For investigating dropouts. Off by default. A change applies to the current stream within a second or at its next pause. Hide keeps the switches as they are; Option-click the version in About to show this again.")
        }
    }
}

// A switch with its name and one line on what it does
private struct ExperimentToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: title)
            Text(verbatim: detail)
        }
    }
}
