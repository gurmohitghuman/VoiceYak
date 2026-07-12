import Foundation
import Testing
@testable import VoiceYak

/// Regression tests for B1: a corrupt or missing model must surface as a
/// thrown ParakeetError, never a fatalError crash.
struct ParakeetServiceTests {

    @Test @MainActor func loadModelThrowsOnMissingFiles() async {
        let service = ParakeetService()
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        await #expect(throws: ParakeetError.self) {
            try await service.loadModel(modelDir: emptyDir)
        }
        #expect(!service.isModelLoaded)
    }

    @Test @MainActor func loadModelThrowsOnCorruptFiles() async {
        let service = ParakeetService()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // All expected files present but holding garbage: the file-exists
        // precheck passes and the native create must fail, which used to
        // fatalError the whole process.
        for name in Constants.parakeetModelFiles {
            let garbage = Data("not a real onnx model".utf8)
            try? garbage.write(to: dir.appendingPathComponent(name))
        }

        await #expect(throws: ParakeetError.self) {
            try await service.loadModel(modelDir: dir)
        }
        #expect(!service.isModelLoaded)
    }
}
