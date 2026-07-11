import SwiftUI

/// Attribution for every third-party component VoiceYak ships or downloads.
/// Full license texts live in THIRD-PARTY-NOTICES.md in the repository.
struct CreditsView: View {
    private struct Credit: Identifiable {
        var id: String { name }
        let name: String
        let role: String
        let license: String
        let url: String
    }

    private let engine: [Credit] = [
        Credit(
            name: "sherpa-onnx",
            role: "Speech recognition engine (built without TTS)",
            license: "Apache-2.0",
            url: "https://github.com/k2-fsa/sherpa-onnx"
        ),
        Credit(
            name: "ONNX Runtime",
            role: "Neural network inference",
            license: "MIT",
            url: "https://github.com/microsoft/onnxruntime"
        ),
        Credit(
            name: "NVIDIA Parakeet TDT 0.6B v3",
            role: "Speech model, downloaded on first run",
            license: "CC-BY-4.0",
            url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"
        ),
    ]

    private let components: [Credit] = [
        Credit(
            name: "kaldi-native-fbank & kaldi-decoder",
            role: "Audio feature extraction and decoding",
            license: "Apache-2.0",
            url: "https://github.com/csukuangfj/kaldi-native-fbank"
        ),
        Credit(
            name: "OpenFst & kaldifst",
            role: "Finite-state transducers",
            license: "Apache-2.0",
            url: "https://www.openfst.org"
        ),
        Credit(
            name: "KissFFT",
            role: "Fast Fourier transform",
            license: "BSD-3-Clause",
            url: "https://github.com/mborgerding/kissfft"
        ),
        Credit(
            name: "SentencePiece",
            role: "Tokenization",
            license: "Apache-2.0",
            url: "https://github.com/google/sentencepiece"
        ),
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("VoiceYak is open source under the MIT License")
                            .font(.body.weight(.medium))
                        Text("It stands on the shoulders of these projects")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Speech Engine") {
                ForEach(engine) { CreditRow(credit: $0) }
            }

            Section("Bundled Components") {
                ForEach(components) { CreditRow(credit: $0) }
            }

            Section {
                Text("Full license texts are in THIRD-PARTY-NOTICES.md in the VoiceYak repository.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private struct CreditRow: View {
        let credit: Credit

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credit.name)
                        .font(.body.weight(.medium))
                    Text(credit.role)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(credit.license)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: .capsule)

                if let url = URL(string: credit.url) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .help(credit.url)
                    .accessibilityLabel("Open \(credit.name) website")
                }
            }
            .padding(.vertical, 1)
        }
    }
}
