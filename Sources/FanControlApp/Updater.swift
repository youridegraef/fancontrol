import AppKit

// Checks GitHub Releases for a newer version and, when the user agrees,
// downloads the release zip, swaps the running app bundle in place, and
// relaunches. All network work is off the main thread; every completion
// is delivered on the main queue so callers can drive UI directly.
enum Updater {
    static let repo = "youridegraef/fan"
    static let assetName = "FanControl.zip"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    struct Release {
        let version: String   // normalized (no leading "v")
        let tag: String
        let downloadURL: URL
        let notes: String
    }

    enum UpdateError: LocalizedError {
        case badResponse, noAsset, downloadFailed, installFailed
        var errorDescription: String? {
            switch self {
            case .badResponse: return "Could not read release information from GitHub."
            case .noAsset: return "The latest release has no \(assetName) download."
            case .downloadFailed: return "Downloading the update failed."
            case .installFailed: return "Installing the update failed."
            }
        }
    }

    /// `true` when semantic version `a` is newer than `b` (e.g. 1.0.10 > 1.0.9).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        let finish: (Result<Release, Error>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FanControl", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error { finish(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                finish(.failure(UpdateError.badResponse)); return
            }
            let notes = json["body"] as? String ?? ""
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
                  let urlStr = asset["browser_download_url"] as? String,
                  let dl = URL(string: urlStr) else {
                finish(.failure(UpdateError.noAsset)); return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            finish(.success(Release(version: version, tag: tag, downloadURL: dl, notes: notes)))
        }.resume()
    }

    static func downloadAndInstall(_ release: Release, completion: @escaping (Result<Void, Error>) -> Void) {
        let finish: (Result<Void, Error>) -> Void = { r in
            DispatchQueue.main.async { completion(r) }
        }
        URLSession.shared.downloadTask(with: release.downloadURL) { tmp, _, error in
            if let error { finish(.failure(error)); return }
            guard let tmp else { finish(.failure(UpdateError.downloadFailed)); return }
            do {
                try installZip(at: tmp)
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        }.resume()
    }

    /// Unzip the downloaded app and schedule a detached swap that runs once
    /// this process exits, then relaunches the updated app. Throws if the
    /// zip is malformed; the swap itself runs after we terminate.
    private static func installZip(at zipURL: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("FanControlUpdate-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.installFailed }

        let newApp = work.appendingPathComponent("FanControl.app")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.installFailed }

        let dst = Bundle.main.bundlePath   // e.g. /Applications/FanControl.app
        let pid = ProcessInfo.processInfo.processIdentifier

        // Wait for this process to exit, then swap atomically-ish: move the
        // old bundle aside, copy the new one in, and relaunch. Restore the
        // old bundle if the copy fails so the user is never left without an app.
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(sh(dst)).old
        mv \(sh(dst)) \(sh(dst)).old && /usr/bin/ditto \(sh(newApp.path)) \(sh(dst))
        if [ -d \(sh(dst)) ]; then
          rm -rf \(sh(dst)).old \(sh(work.path))
        else
          mv \(sh(dst)).old \(sh(dst))
        fi
        open \(sh(dst))
        """
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = ["-c", script]
        try runner.run()   // detached - do not wait
    }

    private static func sh(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
