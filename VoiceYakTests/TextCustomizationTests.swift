import Testing
@testable import VoiceYak

/// Regression tests for the dictionary matcher — pure logic, no store or
/// UserDefaults involved.
struct TextCustomizationTests {

    private func apply(_ text: String, _ entries: [DictionaryEntry]) -> String {
        TextCustomizationStore.applyDictionary(to: text, entries: entries)
    }

    @Test func smartMatchingFromCamelCase() {
        let entry = DictionaryEntry(phrase: "VoiceYak")
        #expect(apply("I use voice yak daily", [entry]) == "I use VoiceYak daily")
        #expect(apply("open voiceyak now", [entry]) == "open VoiceYak now")
        #expect(apply("Voice-yak is great.", [entry]) == "VoiceYak is great.")
        #expect(apply("VOICE YAK!", [entry]) == "VoiceYak!")
    }

    @Test func noMatchInsideWordsOrAcrossOtherWords() {
        let entry = DictionaryEntry(phrase: "VoiceYak")
        #expect(apply("invoice yakking", [entry]) == "invoice yakking")
        #expect(apply("the voice of yak", [entry]) == "the voice of yak")
    }

    @Test func variantsMatch() {
        let entry = DictionaryEntry(phrase: "Sourdough", variants: ["sour dough"])
        #expect(apply("sour dough said hi", [entry]) == "Sourdough said hi")
        #expect(apply("sourdough said hi", [entry]) == "Sourdough said hi")
    }

    @Test func symbolEdgesMatch() {
        let entry = DictionaryEntry(phrase: "C++")
        #expect(apply("c++ meeting", [entry]) == "C++ meeting")
    }

    @Test func longestMatchWinsOverCascadingRewrites() {
        let newYork = DictionaryEntry(phrase: "New York")
        let york = DictionaryEntry(phrase: "YORK")
        // "york" inside the longer match must not be rewritten again,
        // regardless of entry order.
        #expect(apply("i live in new york", [newYork, york]) == "i live in New York")
        #expect(apply("i live in new york", [york, newYork]) == "i live in New York")
        #expect(apply("york is old", [newYork, york]) == "YORK is old")
    }

    @Test func variantLongerThanPhraseStillWins() {
        let zed = DictionaryEntry(phrase: "Zed", variants: ["a very long misheard variant"])
        let newYork = DictionaryEntry(phrase: "New York")
        #expect(apply("a very long misheard variant here", [zed, newYork]) == "Zed here")
    }

    @Test func decomposedUnicodeMatches() {
        let entry = DictionaryEntry(phrase: "Café")
        // "e" + combining acute in the input
        #expect(apply("caf\u{0065}\u{0301} time", [entry]) == "Café time")
    }

    @Test func multipleOccurrencesAllReplaced() {
        let entry = DictionaryEntry(phrase: "VoiceYak")
        #expect(apply("voice yak and voice yak", [entry]) == "VoiceYak and VoiceYak")
    }

    @Test func emptyEntriesLeaveTextUntouched() {
        #expect(apply("hello there", []) == "hello there")
        let blank = DictionaryEntry(phrase: "   ")
        #expect(apply("hello there", [blank]) == "hello there")
    }
}
