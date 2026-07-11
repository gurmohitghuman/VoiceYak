import SwiftUI

/// Settings pane for the user dictionary: words VoiceYak should always
/// spell correctly (names, brands, jargon).
struct DictionaryPane: View {
    private let store = TextCustomizationStore.shared
    @State private var newPhrase = ""

    private var trimmedPhrase: String {
        newPhrase.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        @Bindable var store = store
        return Form {
            Section("Add a Word") {
                HStack(spacing: 8) {
                    // Bordered + leading-aligned: a bare TextField in a
                    // grouped form right-aligns its text, which made the
                    // entry point read as if typing happened "on the right".
                    TextField("Add a word or phrase, e.g. VoiceYak", text: $newPhrase)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit(addEntry)

                    Button("Add", action: addEntry)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedPhrase.isEmpty)
                }
                .padding(.vertical, 2)

                Text("Dictations are corrected to these spellings. Matching is automatic: \"VoiceYak\" also catches \"voice yak\", \"voice-yak\" and \"Voiceyak\". Add extra misheard forms per word if needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if store.entries.isEmpty {
                Section {
                    Text("No words yet. Add the names and terms VoiceYak keeps getting wrong. You only have to fix each one once.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            } else {
                Section("Words (\(store.entries.count))") {
                    ForEach($store.entries) { $entry in
                        DictionaryEntryRow(entry: $entry) { id in
                            // The id arrives by value: reading entry.id
                            // through the binding while removeAll mutates
                            // the same array is an exclusivity violation.
                            store.entries.removeAll { $0.id == id }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addEntry() {
        let phrase = trimmedPhrase
        guard !phrase.isEmpty else { return }
        guard !store.entries.contains(where: { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }) else {
            newPhrase = ""
            return
        }
        store.entries.insert(DictionaryEntry(phrase: phrase), at: 0)
        newPhrase = ""
    }
}

// MARK: - Row

private struct DictionaryEntryRow: View {
    @Binding var entry: DictionaryEntry
    let onDelete: (UUID) -> Void

    @State private var variantsText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.phrase)
                    .font(.body.weight(.medium))

                TextField("Also matches (comma-separated, optional)", text: $variantsText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
            }

            Spacer()

            Button {
                onDelete(entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \"\(entry.phrase)\"")
            .accessibilityLabel("Remove \(entry.phrase)")
        }
        .padding(.vertical, 2)
        .onAppear {
            variantsText = entry.variants.joined(separator: ", ")
        }
        // Commit on every keystroke — a focus/submit-only commit loses the
        // edit when the pane or window closes first. The field keeps the
        // raw text, so normalizing into variants doesn't fight the cursor.
        .onChange(of: variantsText) { _, _ in
            commitVariants()
        }
    }

    private func commitVariants() {
        entry.variants = variantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
