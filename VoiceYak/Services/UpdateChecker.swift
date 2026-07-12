import Foundation
import Observation
import os

/// Checks GitHub Releases for a newer version. Notification only: the app
/// never downloads or installs anything itself, it points the user at the
/// release page in their browser. The check runs only when the user has
/// opted in (or presses Check Now) and sends nothing beyond the request
/// itself: no identifiers, no analytics, just an anonymous read of the
/// latest release tag.
@MainActor
@Observable
final class UpdateChecker {

    struct UpdateInfo: Equatable {
        let version: String
        let releaseURL: URL
    }

    /// Set when a release newer than the running version is known.
    var available: UpdateInfo?
    /// True while a check is in flight (drives the Check Now button).
    var isChecking = false
    /// Set after a manual Check Now that found no update, so settings can
    /// confirm "up to date". Cleared when the next check starts.
    var upToDateConfirmed = false

    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    private let currentVersion: String

    init(currentVersion: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.currentVersion = currentVersion
    }

    /// Starts the opt-in daily loop: one check shortly after launch at a
    /// randomized delay (so there is no distinctive launch-time beacon),
    /// then roughly daily with jitter. A relaunch inside the daily window
    /// does not re-ping — the last check time is persisted.
    func startDailyChecks() {
        guard scheduleTask == nil else { return }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double.random(in: 10...60)))
            while !Task.isCancelled {
                guard let self else { return }
                var elapsed = Date().timeIntervalSince1970 - UserDefaults.standard.lastUpdateCheckAt
                if elapsed < 0 {
                    // A timestamp in the future means the clock moved
                    // backwards; a stale guard must not suppress checks
                    // until wall time catches up. Treat as due now.
                    elapsed = Constants.updateCheckInterval
                }
                if elapsed >= Constants.updateCheckInterval * 0.9 {
                    await self.check(manual: false)
                    try? await Task.sleep(for: .seconds(
                        Constants.updateCheckInterval + Double.random(in: 0...3600)
                    ))
                } else {
                    // Not due yet: wake when the current interval actually
                    // elapses, not a full interval from now — sleeping the
                    // full interval after a skip stretched the effective
                    // cadence to nearly two days.
                    try? await Task.sleep(for: .seconds(
                        Constants.updateCheckInterval - elapsed + Double.random(in: 0...3600)
                    ))
                }
            }
        }
    }

    func stopDailyChecks() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    /// User-initiated check; always allowed regardless of the setting.
    func checkNow() async {
        await check(manual: true)
    }

    private func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        upToDateConfirmed = false
        defer { isChecking = false }

        guard let url = URL(string: Constants.latestReleaseAPIURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Log.updates.info("update check HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            UserDefaults.standard.lastUpdateCheckAt = Date().timeIntervalSince1970

            struct Release: Decodable {
                let tagName: String
                let htmlURL: String
                enum CodingKeys: String, CodingKey {
                    case tagName = "tag_name"
                    case htmlURL = "html_url"
                }
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = Self.normalized(release.tagName)

            if Self.isVersion(latest, newerThan: currentVersion),
               let pageURL = URL(string: release.htmlURL) {
                available = UpdateInfo(version: latest, releaseURL: pageURL)
                Log.updates.info("update available: \(latest, privacy: .public)")
            } else {
                available = nil
                if manual { upToDateConfirmed = true }
            }
        } catch {
            // Offline or GitHub unreachable is normal; never surface it.
            Log.updates.info("update check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version comparison

    /// Strips a leading "v" ("v1.2.0" becomes "1.2.0").
    nonisolated static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric per-component comparison: "1.10.0" is newer than "1.9.1",
    /// "1.1" equals "1.1.0". Every component must be a nonnegative integer;
    /// a malformed version on either side compares as not-newer, so a
    /// malformed release tag ("2.beta", "1.x.1") can never be advertised
    /// as an update.
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        guard let av = numericComponents(a), let bv = numericComponents(b) else { return false }
        for index in 0..<max(av.count, bv.count) {
            let x = index < av.count ? av[index] : 0
            let y = index < bv.count ? bv[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func numericComponents(_ version: String) -> [Int]? {
        // Keep empty subsequences: "2..0" or "2." must fail the numeric
        // parse below, not silently collapse to valid components.
        let parts = normalized(version).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        return components
    }
}
