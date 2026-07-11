import AppKit
import Foundation
import Observation

// MARK: - Models

/// A user dictionary entry: the canonical spelling plus optional
/// "misheard as" variants. Matching is smart — "VoiceYak" automatically
/// catches "voice yak", "voice-yak", and "Voiceyak" without variants.
nonisolated struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    /// The correct spelling that gets pasted (e.g. "VoiceYak").
    var phrase: String
    /// Extra spoken/misheard forms to match (e.g. "voice yack").
    var variants: [String]

    init(id: UUID = UUID(), phrase: String, variants: [String] = []) {
        self.id = id
        self.phrase = phrase
        self.variants = variants
    }

    /// Tolerant decoding: one malformed or older record must not wipe the
    /// whole dictionary (synthesized Codable has no per-key fallbacks).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        phrase = (try? container.decode(String.self, forKey: .phrase)) ?? ""
        variants = (try? container.decode([String].self, forKey: .variants)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, phrase, variants
    }
}

/// Per-app overrides of the global Output formatting settings.
nonisolated struct AppFormattingRule: Codable, Identifiable, Equatable {
    var id: UUID
    var bundleId: String
    var displayName: String
    var autoCapitalize: Bool
    var addTrailingSpace: Bool

    init(
        id: UUID = UUID(),
        bundleId: String,
        displayName: String,
        autoCapitalize: Bool,
        addTrailingSpace: Bool
    ) {
        self.id = id
        self.bundleId = bundleId
        self.displayName = displayName
        self.autoCapitalize = autoCapitalize
        self.addTrailingSpace = addTrailingSpace
    }

    /// Tolerant decoding — see DictionaryEntry.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        bundleId = (try? container.decode(String.self, forKey: .bundleId)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? bundleId
        autoCapitalize = (try? container.decode(Bool.self, forKey: .autoCapitalize)) ?? true
        addTrailingSpace = (try? container.decode(Bool.self, forKey: .addTrailingSpace)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleId, displayName, autoCapitalize, addTrailingSpace
    }
}

/// How the first character of a dictation is treated. The voice model
/// capitalizes sentence starts on its own, so merely "not adding" a
/// capital is invisible; terminal-style targets need it actively removed.
nonisolated enum CapitalizationBehavior {
    /// Uppercase the first letter (adds a capital when the model didn't).
    case capitalize
    /// Leave the model's output untouched.
    case preserve
    /// Lowercase the first letter.
    case lowercase
}

/// The formatting actually applied to one dictation.
nonisolated struct EffectiveFormatting {
    var capitalization: CapitalizationBehavior
    var addTrailingSpace: Bool
    /// Remove one trailing sentence terminator (. ! ?) the model added,
    /// so commands are paste-ready. Terminal rule only.
    var stripTrailingPunctuation: Bool
}

// MARK: - Store

/// Owns the user dictionary and per-app formatting rules. Persisted as JSON
/// in UserDefaults — both lists are small (tens of entries).
@MainActor
@Observable
final class TextCustomizationStore {
    static let shared = TextCustomizationStore()

    var entries: [DictionaryEntry] {
        didSet { save(entries, forKey: Self.entriesKey) }
    }
    var appRules: [AppFormattingRule] {
        didSet { save(appRules, forKey: Self.appRulesKey) }
    }
    /// Built-in rule: paste plain text (no capitalization, no trailing
    /// space) into known terminal apps. On by default.
    var plainTextInTerminals: Bool {
        didSet { UserDefaults.standard.set(plainTextInTerminals, forKey: Self.terminalsKey) }
    }

    private static let entriesKey = "dictionaryEntries"
    private static let appRulesKey = "perAppFormattingRules"
    private static let terminalsKey = "plainTextInTerminals"

    /// Bundle ids treated as terminals by the built-in rule. Dedicated
    /// terminal apps only — IDE-integrated terminals (VS Code, JetBrains)
    /// report the IDE's bundle id and need a custom rule instead.
    static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "org.wezfurlong.wezterm",
        "net.kovidgoyal.kitty",
        "org.tabby",
        "co.zeit.hyper",
    ]

    private init() {
        entries = (Self.load([DictionaryEntry].self, forKey: Self.entriesKey) ?? [])
            .filter { !$0.phrase.isEmpty }
        appRules = (Self.load([AppFormattingRule].self, forKey: Self.appRulesKey) ?? [])
            .filter { !$0.bundleId.isEmpty }
        plainTextInTerminals = UserDefaults.standard.object(forKey: Self.terminalsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.terminalsKey)
    }

    // MARK: Dictionary matching

    func applyDictionary(to text: String) -> String {
        Self.applyDictionary(to: text, entries: entries)
    }

    /// Replaces misheard forms of each dictionary entry with its canonical
    /// spelling. All patterns are matched against the ORIGINAL text and
    /// resolved as one non-overlapping set (longest match wins) — cascading
    /// per-entry replacement let a short entry rewrite part of a longer
    /// entry's freshly-inserted canonical text.
    /// Static and pure so tests can exercise it without the shared store.
    nonisolated static func applyDictionary(to text: String, entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else { return text }
        // Canonical composition so "é" matches "e" + combining accent.
        let source = text.precomposedStringWithCanonicalMapping
        let fullRange = NSRange(source.startIndex..., in: source)

        struct Candidate {
            let range: NSRange
            let replacement: String
        }
        var candidates: [Candidate] = []
        for entry in entries {
            let phrase = entry.phrase.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { continue }
            for pattern in Self.patterns(for: entry) {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ) else { continue }
                regex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
                    if let match {
                        candidates.append(Candidate(range: match.range, replacement: phrase))
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return text }

        // Longest match wins on overlap; position breaks ties.
        let ordered = candidates.sorted {
            $0.range.length != $1.range.length
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        var chosen: [Candidate] = []
        for candidate in ordered
        where !chosen.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
            chosen.append(candidate)
        }

        // Apply right-to-left so unapplied ranges keep their offsets.
        var result = source
        for candidate in chosen.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(candidate.range, in: result) else { continue }
            result.replaceSubrange(range, with: candidate.replacement)
        }
        return result
    }

    /// Regex patterns for an entry: the phrase's subwords joined by
    /// flexible separators, plus each user variant treated the same way.
    /// "VoiceYak" → subwords ["Voice","Yak"] → matches "voice yak",
    /// "voice-yak", "voiceyak" (any case).
    nonisolated static func patterns(for entry: DictionaryEntry) -> [String] {
        var sources = [entry.phrase]
        sources.append(contentsOf: entry.variants)
        return sources.compactMap { rawSource in
            let source = rawSource.precomposedStringWithCanonicalMapping
            let subwords = subwords(of: source)
            guard !subwords.isEmpty else { return nil }
            let body = subwords
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: #"[\s\-]*"#)
            // Lookarounds instead of \b: a phrase edge that is itself a
            // non-word character ("C++") has no \b against a space.
            return #"(?<!\w)"# + body + #"(?!\w)"#
        }
    }

    /// Splits on whitespace/hyphens and camelCase boundaries:
    /// "VoiceYak" → ["Voice","Yak"], "gur mohit" → ["gur","mohit"].
    nonisolated static func subwords(of source: String) -> [String] {
        let separated = source.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        return separated.flatMap { token -> [String] in
            var parts: [String] = []
            var current = ""
            var previous: Character?
            for char in token {
                if char.isUppercase, let prev = previous, prev.isLowercase {
                    parts.append(current)
                    current = ""
                }
                current.append(char)
                previous = char
            }
            if !current.isEmpty { parts.append(current) }
            return parts
        }
    }

    /// True when the text begins with a canonical dictionary phrase,
    /// case-sensitively and ending at a word boundary — auto-capitalize
    /// must not mangle "iPhone rocks" into "IPhone rocks".
    func beginsWithCanonicalPhrase(_ text: String) -> Bool {
        entries.contains { entry in
            let phrase = entry.phrase.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty, text.hasPrefix(phrase) else { return false }
            let after = text.index(text.startIndex, offsetBy: phrase.count)
            guard after < text.endIndex else { return true }
            let next = text[after]
            return !(next.isLetter || next.isNumber)
        }
    }

    // MARK: Per-app formatting

    /// The formatting for a paste into `bundleId`: a custom rule wins,
    /// then the built-in terminal rule, then the global Output settings.
    /// A rule's unchecked Capitalize means LOWERCASE (the model always
    /// capitalizes, so a per-app opt-out must undo that); the global
    /// toggle's off state stays "preserve" so switching it off never
    /// rewrites the model's natural sentences.
    func effectiveFormatting(for bundleId: String?) -> EffectiveFormatting {
        let defaults = UserDefaults.standard
        var formatting = EffectiveFormatting(
            capitalization: defaults.autoCapitalize ? .capitalize : .preserve,
            addTrailingSpace: defaults.addTrailingSpace,
            stripTrailingPunctuation: false
        )
        guard let bundleId else { return formatting }

        // Terminal baseline first, custom rule on top: a custom rule for a
        // listed terminal overrides capitalization/space but must not lose
        // the punctuation stripping the terminal baseline provides.
        if plainTextInTerminals, Self.terminalBundleIds.contains(bundleId) {
            formatting.capitalization = .lowercase
            formatting.addTrailingSpace = false
            formatting.stripTrailingPunctuation = true
        }
        if let rule = appRules.first(where: { $0.bundleId == bundleId }) {
            formatting.capitalization = rule.autoCapitalize ? .capitalize : .lowercase
            formatting.addTrailingSpace = rule.addTrailingSpace
        }
        return formatting
    }

    func addRule(for app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier,
              !appRules.contains(where: { $0.bundleId == bundleId }) else { return }
        // Seed from the app's CURRENT effective formatting so adding a rule
        // is behavior-preserving (adding Terminal must not re-enable
        // capitalization that the terminal rule was suppressing).
        let current = effectiveFormatting(for: bundleId)
        appRules.append(AppFormattingRule(
            bundleId: bundleId,
            displayName: app.localizedName ?? bundleId,
            autoCapitalize: current.capitalization == .capitalize,
            addTrailingSpace: current.addTrailingSpace
        ))
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
