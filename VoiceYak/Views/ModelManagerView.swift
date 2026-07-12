import SwiftUI

struct ModelManagerView: View {
    let appState: AppState

    private var downloader: ModelDownloader { appState.modelDownloader }

    @AppStorage("selectedVoiceModel") private var selectedVoiceModel = "multilingual"

    private var selectedModel: VoiceModel {
        VoiceModel(rawValue: selectedVoiceModel) ?? .multilingual
    }

    /// "Ready" only when THIS model is actually loaded in memory — on disk
    /// but unloaded (still loading, a failed load, or a different model
    /// currently loaded) must not claim ready while the hotkey would say
    /// the model is unavailable.
    private var modelStatus: (label: String, color: Color) {
        if appState.parakeetService.isModelLoaded,
           appState.parakeetService.loadedModelDirectory == selectedModel.directory {
            return ("Ready", .green)
        }
        if downloader.isModelDownloaded {
            return ("Downloaded, not loaded", .yellow)
        }
        return ("Not downloaded", .orange)
    }

    var body: some View {
        Form {
            // Current model status
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.25)), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Active Model")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Text(selectedModel.modelName)
                            .font(.headline)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(modelStatus.color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(modelStatus.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Language Support") {
                Picker("Model", selection: $selectedVoiceModel) {
                    ForEach(VoiceModel.allCases) { model in
                        Text(model.displayName)
                            .tag(model.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedVoiceModel) { _, _ in
                    Task { await appState.modelSelectionChanged() }
                }

                Text(selectedModel == .multilingual
                     ? "English and 24 other European languages."
                     : "English only, with the best English accuracy and a smaller download.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let other = VoiceModel.allCases.first(where: { $0 != selectedModel }),
                   other.isDownloaded {
                    Text("The \(other.displayName) model is also downloaded. Switching won't need another download.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            // Model info
            Section("Model Details") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(selectedModel.modelName)
                                .font(.body.weight(.medium))

                            Text("INT8")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: .capsule)
                        }

                        HStack(spacing: 8) {
                            Label(selectedModel.displaySize, systemImage: "arrow.down.circle")
                            Label("~1-2 GB RAM", systemImage: "memorychip")
                            Label("Very Fast", systemImage: "bolt")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(selectedModel.details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    Spacer()

                    modelActionButton
                }
                .padding(.vertical, 2)
            }

            // Attribution
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Speech recognition powered by NVIDIA Parakeet TDT, licensed under CC-BY-4.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelActionButton: some View {
        // Only this model's own download state may drive its UI —
        // another model's in-flight download shows nothing here.
        let state = downloader.downloadState.flatMap { $0.model == selectedModel ? $0 : nil }

        if let state, !state.isComplete, state.error == nil {
            // Actively downloading
            VStack(spacing: 6) {
                ProgressView(value: state.progress)
                    .frame(width: 80)

                Text("\(Int(state.progress * 100))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Button(action: { downloader.cancelDownload() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
        } else if downloader.isModelDownloaded {
            VStack(spacing: 4) {
                Text("Downloaded")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)

                Button("Delete", role: .destructive) {
                    appState.deleteModel()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(appState.status.isRecording || appState.status == .transcribing)
                .help("Unavailable while dictating")
            }
        } else {
            VStack(spacing: 4) {
                Button(action: { downloader.download() }) {
                    Text("Download")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if let error = state?.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }
}
