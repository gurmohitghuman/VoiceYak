import Testing
@testable import VoiceYak

/// Version-comparison logic for the update checker — pure functions.
struct UpdateCheckerTests {

    @Test func newerVersionsDetected() {
        #expect(UpdateChecker.isVersion("1.1.0", newerThan: "1.0.1"))
        #expect(UpdateChecker.isVersion("2.0", newerThan: "1.9.9"))
        #expect(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.1"))
        #expect(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
    }

    @Test func olderAndEqualVersionsRejected() {
        #expect(!UpdateChecker.isVersion("1.0.1", newerThan: "1.1.0"))
        #expect(!UpdateChecker.isVersion("1.1.0", newerThan: "1.1.0"))
        #expect(!UpdateChecker.isVersion("1.1", newerThan: "1.1.0"))
        #expect(!UpdateChecker.isVersion("1.1.0", newerThan: "1.1"))
    }

    @Test func vPrefixHandled() {
        #expect(UpdateChecker.isVersion("v1.2.0", newerThan: "1.1.0"))
        #expect(UpdateChecker.isVersion("1.2.0", newerThan: "v1.1.0"))
        #expect(!UpdateChecker.isVersion("v1.1.0", newerThan: "v1.1.0"))
        #expect(UpdateChecker.normalized("v1.2.3") == "1.2.3")
        #expect(UpdateChecker.normalized("1.2.3") == "1.2.3")
    }

    @Test func malformedTagsNeverLookNewer() {
        #expect(!UpdateChecker.isVersion("beta", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion("", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion("v", newerThan: "0.0.1"))
        #expect(!UpdateChecker.isVersion("2.beta", newerThan: "1.9"))
        #expect(!UpdateChecker.isVersion("1.x.1", newerThan: "1.0.0"))
        #expect(!UpdateChecker.isVersion("2.0-rc1", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion("2..0", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion(".2", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion("2.", newerThan: "1.0"))
    }
}
