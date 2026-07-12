import Foundation
import os

/// Out-of-process model verification. The sherpa/ONNX native code can call
/// exit() or abort when model files are corrupt — that is not catchable
/// in-process, so a model that has never loaded successfully is first
/// loaded in a throwaway child process (this same executable, launched
/// with --verify-model). Only if the child survives does the main process
/// load the model. Models stamped by a previous successful load skip the
/// canary, so steady-state launches pay nothing.
nonisolated enum ModelVerifier {

    static let argumentFlag = "--verify-model"
    private static let stampsKey = "verifiedModelStamps"

    /// Child-process entry, called first thing at app startup. When the
    /// verify flag is present this loads the model and never returns:
    /// exit 0 on success, exit 2 on a thrown load error, and any native
    /// exit/abort surfaces to the parent as a nonzero termination status.
    static func handleVerifyModelArgumentIfPresent() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: argumentFlag),
              args.count > flagIndex + 1 else { return }
        let modelDir = URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true)
        do {
            _ = try ParakeetService.makeRecognizer(modelDir: modelDir)
            exit(0)
        } catch {
            exit(2)
        }
    }

    /// Loads the model in a child process. Blocking — call off the main
    /// thread. Returns true only when the child loaded the model and
    /// exited cleanly. Fails closed: if the canary cannot run at all, the
    /// load is refused rather than handing an unproven model to native
    /// code that may exit() the whole app.
    static func verifyOutOfProcess(modelDir: URL) -> Bool {
        guard let executable = Bundle.main.executableURL else {
            Log.models.error("model canary unavailable: no executable URL")
            return false
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argumentFlag, modelDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.models.error("model canary failed to spawn: \(error.localizedDescription)")
            return false
        }
        // A healthy load takes on the order of a second; the deadline only
        // bounds a pathological hang.
        if !waitForExit(process, within: 30) {
            Log.models.error("model canary timed out, treating model as bad")
            process.terminate()
            // Grace, then escalate — a wedged child must not keep burning
            // CPU after we've already declared the model bad.
            if !waitForExit(process, within: 2) {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return false
        }
        let ok = process.terminationStatus == 0
        if !ok {
            Log.models.error("model canary died with status \(process.terminationStatus) — model is corrupt or unloadable")
        }
        return ok
    }

    private static func waitForExit(_ process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    // MARK: - Verified stamps

    /// A model that changed on disk since its last successful load must be
    /// re-verified: the stamp encodes the full path plus every file's own
    /// size and sub-second modification time, so replacing or rewriting any
    /// file invalidates it. Metadata-preserving in-place corruption
    /// (bit rot) is covered not by the stamp but by the unmark-before-load
    /// protocol in ParakeetService: a load that crashes the app leaves the
    /// model unstamped, so the next launch routes it through the canary.
    static func stamp(for modelDir: URL) -> String {
        var parts: [String] = [modelDir.path]
        for file in Constants.parakeetModelFiles {
            let path = modelDir.appendingPathComponent(file).path
            let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attrs[.size] as? UInt64) ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(file)=\(size):\(String(format: "%.6f", mtime))")
        }
        return parts.joined(separator: "|")
    }

    static func isVerified(_ stamp: String) -> Bool {
        let stamps = UserDefaults.standard.array(forKey: stampsKey) as? [String] ?? []
        return stamps.contains(stamp)
    }

    /// Recorded after a successful IN-PROCESS load — that is the real proof.
    static func markVerified(_ stamp: String) {
        var stamps = UserDefaults.standard.array(forKey: stampsKey) as? [String] ?? []
        guard !stamps.contains(stamp) else { return }
        stamps.append(stamp)
        // Bounded: two models times a handful of re-downloads.
        if stamps.count > 8 {
            stamps.removeFirst(stamps.count - 8)
        }
        UserDefaults.standard.set(stamps, forKey: stampsKey)
    }

    /// Crash-loop breaker: called immediately BEFORE every in-process load.
    /// If that load takes the process down (e.g. bit rot the stamp cannot
    /// see), the stamp is already gone, and the next launch verifies the
    /// model in a child process instead of crashing again.
    static func unmarkVerified(_ stamp: String) {
        var stamps = UserDefaults.standard.array(forKey: stampsKey) as? [String] ?? []
        guard let index = stamps.firstIndex(of: stamp) else { return }
        stamps.remove(at: index)
        UserDefaults.standard.set(stamps, forKey: stampsKey)
        // The whole point is surviving a crash on the very next call:
        // defaults writes flush asynchronously, so force the write to disk
        // BEFORE the risky native load happens.
        UserDefaults.standard.synchronize()
    }
}
