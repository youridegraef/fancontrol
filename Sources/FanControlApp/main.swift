import AppKit

// FanControl - minimal menu bar app. Presets only: Auto, Silent, Balanced,
// Performance, Max. Applies presets by invoking the setuid fanctl helper.

let helperPath = "/usr/local/bin/fanctl"

enum Preset: CaseIterable {
    case auto, silent, balanced, performance, max

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .silent: return "Silent"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .max: return "Max"
        }
    }

    var helperArguments: [String] {
        switch self {
        case .auto: return ["auto"]
        case .silent: return ["set", "0"]
        case .balanced: return ["set", "35"]
        case .performance: return ["set", "65"]
        case .max: return ["set", "100"]
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var presetItems: [NSMenuItem] = []
    private var currentPreset: Preset = .auto

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "FanControl")
        }

        let menu = NSMenu()
        for preset in Preset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            menu.addItem(item)
            presetItems.append(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FanControl", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        updateCheckmarks()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }
        if apply(preset) {
            currentPreset = preset
            updateCheckmarks()
        }
    }

    @objc private func quit() {
        // Safety: never leave fans forced after the app is gone.
        if currentPreset != .auto {
            _ = apply(.auto)
        }
        NSApp.terminate(nil)
    }

    private func updateCheckmarks() {
        for item in presetItems {
            let preset = item.representedObject as? Preset
            item.state = preset == currentPreset ? .on : .off
        }
    }

    private func apply(_ preset: Preset) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            showError("Helper not installed",
                      "fanctl was not found at \(helperPath).\n\nRun `sudo make install` in the FanControl project directory first.")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = preset.helperArguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            showError("Failed to run helper", error.localizedDescription)
            return false
        }

        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            showError("Could not apply preset", message)
            return false
        }
        return true
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
