import AgentHUDCore
import AppKit
import Observation

/// Checks GitHub for a newer release (daily, and on demand) and installs it through Homebrew,
/// which quits this copy, swaps in the new one, and relaunches it.
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle, checking, upToDate, available(UpdateCheck.Release), installing, failed(String)
    }

    private let settings: AppSettings
    private(set) var status: Status = .idle
    @ObservationIgnored private var timer: Timer?
    /// Asked before installing on its own, so an update never restarts the panel while an agent waits on you.
    @ObservationIgnored var canAutoInstall: () -> Bool = { true }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Installed with Homebrew (and brew is still there to upgrade it).
    var viaHomebrew: Bool { UpdateCheck.brewCaskroom() != nil && UpdateCheck.brewBinary != nil }

    var available: UpdateCheck.Release? {
        if case .available(let r) = status { return r }
        return nil
    }

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relaunchIfReplaced() }
        }
        // Give the app a moment to settle before the first check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    /// The app on disk is a newer version than this running copy (a `brew upgrade` that couldn't quit us):
    /// restart into it, once nothing is waiting on you.
    private func relaunchIfReplaced() {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let onDisk = info["CFBundleShortVersionString"] as? String,
              UpdateCheck.isNewer(onDisk, than: Self.currentVersion), canAutoInstall() else { return }
        Self.relaunch()
    }

    /// Quits and reopens the app from disk.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -b com.xeratec.agenthud"]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func checkIfDue() {
        guard settings.checkForUpdates else { return }
        if Date().timeIntervalSince1970 - settings.lastUpdateCheck >= 24 * 3600 { check() }
        else if let r = available { maybeAutoInstall(r) }
    }

    func check() {
        guard status != .checking, status != .installing else { return }
        status = .checking
        // The release page's redirect first (no rate limit); the API only if that fails.
        var head = URLRequest(url: UpdateCheck.releasesPage, timeoutInterval: 20)
        head.httpMethod = "HEAD"
        head.setValue("AgentHUD/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: head) { _, response, _ in
            let release = response?.url.flatMap(UpdateCheck.release(fromPage:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let release { self.finish(release) } else { self.checkAPI() }
                }
            }
        }.resume()
    }

    private func finish(_ release: UpdateCheck.Release) {
        settings.lastUpdateCheck = Date().timeIntervalSince1970
        if UpdateCheck.isNewer(release.version, than: Self.currentVersion) {
            status = .available(release)
            maybeAutoInstall(release)
        } else {
            status = .upToDate
        }
    }

    private func checkAPI() {
        var req = URLRequest(url: UpdateCheck.latestURL, timeoutInterval: 20)
        req.setValue("AgentHUD/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(UpdateCheck.parse)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.settings.lastUpdateCheck = Date().timeIntervalSince1970
                    if let release, UpdateCheck.isNewer(release.version, than: Self.currentVersion) {
                        self.status = .available(release)
                        self.maybeAutoInstall(release)
                    } else if release != nil || code == 404 {
                        self.status = .upToDate
                    } else if code == 403 || code == 429 {
                        self.status = .failed("GitHub is rate-limiting this network; try again in an hour")
                    } else {
                        self.status = .failed(error?.localizedDescription ?? "GitHub returned \(code)")
                    }
                }
            }
        }.resume()
    }

    private func maybeAutoInstall(_ r: UpdateCheck.Release) {
        guard settings.installUpdatesAutomatically, viaHomebrew, canAutoInstall() else { return }
        install()
    }

    /// Homebrew: update the tap and upgrade, then quit this copy and launch the new one. brew won't quit
    /// an app it's running inside, so the script does it after the swap. Otherwise, the release page.
    func install() {
        guard viaHomebrew, let brew = UpdateCheck.brewBinary else {
            NSWorkspace.shared.open(available?.page ?? UpdateCheck.releasesPage)
            return
        }
        status = .installing
        let log = Paths.home.appendingPathComponent("update.log").path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        {
          date
          "\(brew)" update --quiet
          "\(brew)" upgrade --cask agent-hud
        } >> '\(log)' 2>&1
        kill \(pid) 2>/dev/null
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /usr/bin/open -b com.xeratec.agenthud
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        do {
            try p.run()
            // Homebrew quits this app when it swaps in the new copy; still here after 5 minutes means it failed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self, self.status == .installing else { return }
                self.status = .failed("Update didn't finish; see ~/.agenthud/update.log")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
