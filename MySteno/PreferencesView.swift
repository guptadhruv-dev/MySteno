import SwiftUI

struct PreferencesView: View {
    @Environment(MyStenoModel.self) private var model

    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }

            TranscriptionPreferencesView()
                .tabItem { Label("Transcription", systemImage: "waveform") }

            ShortcutPreferencesView()
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
        }
        .environment(model)
        .frame(width: 600, height: 500)
        .padding(20)
    }
}

private struct GeneralPreferencesView: View {
    @Environment(MyStenoModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Launch MySteno at login", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.setEnabled($0) }
                ))

                if model.launchAtLogin.needsApproval {
                    HStack {
                        Text("Allow MySteno in System Settings to finish turning this on.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            model.launchAtLogin.openLoginItemsSettings()
                        }
                    }
                }

                if let error = model.launchAtLogin.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Imported audio output") {
                LabeledContent("Folder") {
                    Text(model.outputFolder.displayPath)
                        .foregroundStyle(model.outputFolder.folderURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button(model.outputFolder.folderURL == nil ? "Choose Folder…" : "Change…") {
                        model.outputFolder.chooseFolder()
                    }
                    .disabled(model.isFileTranscribing)
                    Button("Open") {
                        model.outputFolder.openFolder()
                    }
                    .disabled(model.outputFolder.folderURL == nil)
                }

                Text("Choose or create a folder such as Documents/MySteno Output. Imported audio is saved as a UTF-8 text file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = model.outputFolder.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.launchAtLogin.refresh()
        }
    }
}

private struct TranscriptionPreferencesView: View {
    @Environment(MyStenoModel.self) private var model
    private static let physicalMemoryGigabytes = Int(
        (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()
    )
    private static let recommendedAccuracyMemoryGigabytes = 16

    @State private var modelToDelete: TranscriptionModel?
    @State private var showsAccuracyMemoryWarning = false
    @State private var durationDraftMinutes: Int?
    @FocusState private var durationFieldIsFocused: Bool

    var body: some View {
        Form {
            Section("Default model") {
                Picker("Model", selection: Binding(
                    get: { model.transcription.defaultModel },
                    set: { selected in
                        model.updateDefaultModel(selected)
                    }
                )) {
                    ForEach(model.transcription.installedModels) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .disabled(model.jobsAreRunning || model.transcription.installedModels.count < 2)

                Text("This model is selected when MySteno launches. Use the menu selector to change the active model for the current session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paragraphs") {
                Toggle("Start a new paragraph after a pause", isOn: Binding(
                    get: { model.insertsParagraphBreaks },
                    set: { model.updateInsertsParagraphBreaks($0) }
                ))

                Text("When on, a pause of 2 seconds or longer starts a new paragraph. When off, each dictation or file is one paragraph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio duration limit") {
                LabeledContent("Maximum duration") {
                    HStack(spacing: 5) {
                        TextField("Minutes", value: durationBinding, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .focused($durationFieldIsFocused)
                            .onSubmit { commitDurationDraft() }
                            .onChange(of: durationFieldIsFocused) { _, isFocused in
                                if !isFocused { commitDurationDraft() }
                            }

                        Text("minutes")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.jobsAreRunning)

                Text("Applies to microphone recordings and imported audio. Enter any whole number of minutes greater than zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.audioDuration.showsMemoryWarning {
                    Label(
                        "Long audio can cause a RAM usage spike and may exceed this Mac’s available system memory.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Installed models") {
                ForEach(TranscriptionModel.allCases) { option in
                    modelRow(option)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(modelToDelete?.displayName ?? "model")?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let modelToDelete {
                Button("Remove \(modelToDelete.displayName)", role: .destructive) {
                    Task { await model.deleteModel(modelToDelete) }
                    self.modelToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be deleted from this Mac.")
        }
        .alert(
            "Install Accuracy on this Mac?",
            isPresented: $showsAccuracyMemoryWarning
        ) {
            Button("Install Anyway") {
                Task { await model.installModel(.accuracy) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Accuracy is only a small improvement over Speed. On clear speech they are about equally accurate; Accuracy mainly helps with background noise and heavy accents. It takes a second or more per dictation instead of a fraction of a second, downloads 2.2 GB, and may slow down other apps on a Mac with \(Self.physicalMemoryGigabytes) GB of memory. \(Self.recommendedAccuracyMemoryGigabytes) GB or more is recommended.")
        }
    }

    private func requestInstall(_ option: TranscriptionModel) {
        if option == .accuracy, Self.physicalMemoryGigabytes < Self.recommendedAccuracyMemoryGigabytes {
            showsAccuracyMemoryWarning = true
        } else {
            Task { await model.installModel(option) }
        }
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { durationDraftMinutes ?? model.audioDuration.maximumDurationMinutes },
            set: { durationDraftMinutes = $0 }
        )
    }

    private func commitDurationDraft() {
        guard let minutes = durationDraftMinutes else { return }
        model.updateMaximumAudioDurationMinutes(minutes)
        durationDraftMinutes = nil
    }

    private func modelRow(_ option: TranscriptionModel) -> some View {
        let state = model.transcription.states[option] ?? .notInstalled
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.displayName)
                    if model.transcription.defaultModel == option {
                        Text("Default")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.transcription.errorMessage(for: option) {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            if case .downloading(let progress) = state {
                ProgressView(value: progress)
                    .frame(width: 90)
            } else {
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.isInstalled {
                if case .failed = state {
                    Button("Retry") {
                        Task { await model.selectModel(option) }
                    }
                    .disabled(model.jobsAreRunning)
                }
                Button("Remove") {
                    modelToDelete = option
                }
                .disabled(!model.transcription.canDelete(option, jobsAreRunning: model.jobsAreRunning))
            } else {
                Button("Add") {
                    requestInstall(option)
                }
                .disabled(model.jobsAreRunning || state.isBusy)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ShortcutPreferencesView: View {
    @Environment(MyStenoModel.self) private var model

    var body: some View {
        Form {
            Section("Recording shortcut") {
                LabeledContent("Current shortcut") {
                    Text(model.hotkey.config.displayString)
                        .font(.system(.body, design: .rounded).weight(.medium))
                }

                HStack {
                    Button("Change Shortcut…") {
                        model.changeShortcut()
                    }
                    Button("Reset to \(HotkeyConfig.default.displayString)") {
                        model.resetShortcut()
                    }
                    .disabled(model.hotkey.config == .default)
                }

                Text("The shortcut starts and stops microphone recording from any app. It is unavailable while an imported audio file is being transcribed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
