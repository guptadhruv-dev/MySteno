import SwiftUI

@main
struct MyStenoApp: App {
    @State private var model = MyStenoModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environment(model)
        }

        Window("Welcome to MySteno", id: SetupGuide.windowID) {
            SetupGuideView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(SetupGuide.isCompleted ? .suppressed : .presented)
        .restorationBehavior(.disabled)
    }

}

private struct MenuBarLabel: View {
    let model: MyStenoModel

    var body: some View {
        HStack(spacing: 5) {
            if let resizedIcon = getResizedMenuIcon() {
                Image(nsImage: resizedIcon)
            } else {
                Image(systemName: "waveform")
            }

            if model.isRecording {
                Text(model.recordingTimerLabel)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(model.isRecording ? .white : .primary)
        .padding(.horizontal, model.isRecording ? 7 : 0)
        .padding(.vertical, model.isRecording ? 3 : 0)
        .background(
            model.isRecording ? Color(nsColor: .darkGray) : .clear,
            in: Capsule()
        )
        .animation(.easeInOut(duration: 0.2), value: model.isRecording)
    }

    private func getResizedMenuIcon() -> NSImage? {
        guard let image = NSImage(named: "Icon") else { return nil }
        image.size = NSSize(width: 17, height: 17)
        return image
    }
}
