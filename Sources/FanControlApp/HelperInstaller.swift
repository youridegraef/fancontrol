import AppKit

// Installs the setuid `fanctl` helper that ships inside the app bundle
// (Contents/Resources/fanctl) to /usr/local/bin/fanctl. Writing fan keys
// requires root, so the on-disk helper must be owned by root with the
// setuid bit. A single administrator prompt performs the copy + chown +
// chmod. This lets users who download the app from a release run it
// without building from source or running `make install`.
enum HelperInstaller {
    static let installedPath = "/usr/local/bin/fanctl"

    static var bundledPath: String? {
        Bundle.main.path(forResource: "fanctl", ofType: nil)
    }

    /// True when the installed helper exists and byte-for-byte matches the
    /// binary bundled in this app (so a new app version triggers a refresh).
    static func isUpToDate() -> Bool {
        guard let bundled = bundledPath,
              FileManager.default.isExecutableFile(atPath: installedPath),
              let bundledData = try? Data(contentsOf: URL(fileURLWithPath: bundled)),
              let installedData = try? Data(contentsOf: URL(fileURLWithPath: installedPath)) else {
            return false
        }
        return bundledData == installedData
    }

    /// Installs or refreshes the setuid helper. No-op (returns true) when
    /// already up to date. Otherwise shows one admin auth prompt. Returns
    /// false if the helper is not bundled, the user cancels, or the copy
    /// fails.
    @discardableResult
    static func ensureInstalled() -> Bool {
        if isUpToDate() { return true }
        guard let bundled = bundledPath else { return false }

        let src = shellQuote(bundled)
        let dst = shellQuote(installedPath)
        let script = "mkdir -p /usr/local/bin && cp \(src) \(dst) && chown root:wheel \(dst) && chmod 4755 \(dst)"
        return runAsAdmin(script)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command as root via a single osascript admin prompt.
    private static func runAsAdmin(_ shellCommand: String) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }
}
