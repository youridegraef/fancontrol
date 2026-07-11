import AppKit
import SMCKit

// FanControl - minimal menu bar app. Shows average CPU temperature and
// applies fan presets via the setuid fanctl helper.
//
// Presets are fixed RPMs (user-editable, see Settings.swift). "Auto" is an
// app-managed curve: at or below the min temp fans run at their hardware
// minimum, at or above the max temp at their hardware maximum, linear
// in between. Re-evaluated on every temperature tick.

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

    func rpm(in settings: PresetSettings) -> Int? {
        switch self {
        case .auto: return nil
        case .silent: return settings.silentRPM
        case .balanced: return settings.balancedRPM
        case .performance: return settings.performanceRPM
        case .max: return settings.maxRPM
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var presetItems: [NSMenuItem] = []
    private var currentPreset: Preset = .auto
    private var settings = PresetSettings.load()
    private var settingsController: SettingsWindowController?

    private var smc: SMC?
    private var temperatureKeys: [String] = []
    private var temperatureTimer: Timer?
    private var lastTemperature: Float?

    private var fanMinRPM: Float = 0
    private var fanMaxRPM: Float = 0
    private var lastAppliedAutoRPM: Float?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = "--\u{00B0}C"
        }

        smc = try? SMC()
        temperatureKeys = (try? smc?.cpuTemperatureKeys()) ?? []
        if let smc, let fan = try? smc.fan(0) {
            fanMinRPM = fan.minimum
            fanMaxRPM = fan.maximum
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
        let edit = NSMenuItem(title: "Edit Presets\u{2026}", action: #selector(editPresets), keyEquivalent: ",")
        edit.target = self
        menu.addItem(edit)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FanControl", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        updateCheckmarks()
        temperatureTick()
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.temperatureTick()
        }
        RunLoop.main.add(temperatureTimer!, forMode: .common)
    }

    // MARK: - Temperature + auto curve

    private func temperatureTick() {
        guard let smc, !temperatureKeys.isEmpty,
              let avg = smc.averageTemperature(keys: temperatureKeys) else {
            statusItem.button?.title = "--\u{00B0}C"
            return
        }
        lastTemperature = avg
        statusItem.button?.title = "\(Int(avg.rounded()))\u{00B0}C"

        if currentPreset == .auto {
            autoAdjust(temperature: avg, interactive: false)
        }
    }

    /// Linear curve: settings.autoMinTemp -> fan hardware minimum,
    /// settings.autoMaxTemp -> fan hardware maximum.
    private func autoTargetRPM(for temperature: Float) -> Float {
        let minT = Float(settings.autoMinTemp)
        let maxT = Float(settings.autoMaxTemp)
        let fraction = max(0, min(1, (temperature - minT) / (maxT - minT)))
        return fanMinRPM + (fanMaxRPM - fanMinRPM) * fraction
    }

    private func autoAdjust(temperature: Float, interactive: Bool) {
        guard fanMaxRPM > fanMinRPM else { return }
        let target = autoTargetRPM(for: temperature)
        if let last = lastAppliedAutoRPM, abs(target - last) < 100 { return }
        if runHelper(["rpm", String(Int(target))], interactive: interactive) {
            lastAppliedAutoRPM = target
        }
    }

    // MARK: - Menu actions

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }
        if apply(preset) {
            currentPreset = preset
            updateCheckmarks()
        }
    }

    @objc private func editPresets() {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings) { [weak self] newSettings in
                guard let self else { return }
                self.settings = newSettings
                self.lastAppliedAutoRPM = nil
                _ = self.apply(self.currentPreset)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.window?.center()
        settingsController?.showWindow(nil)
    }

    @objc private func quit() {
        // Safety: return fans to SMC-managed automatic control before exiting.
        _ = runHelper(["auto"], interactive: false)
        NSApp.terminate(nil)
    }

    // MARK: - Applying presets

    private func apply(_ preset: Preset) -> Bool {
        if let rpm = preset.rpm(in: settings) {
            return runHelper(["rpm", String(rpm)], interactive: true)
        }
        // Auto: apply the curve for the current temperature right away.
        lastAppliedAutoRPM = nil
        if let temp = lastTemperature {
            autoAdjust(temperature: temp, interactive: true)
        }
        return true
    }

    private func updateCheckmarks() {
        for item in presetItems {
            let preset = item.representedObject as? Preset
            item.state = preset == currentPreset ? .on : .off
        }
    }

    /// Runs the fanctl helper. When `interactive` is false (background auto
    /// adjustments), failures are logged instead of shown as alerts.
    @discardableResult
    private func runHelper(_ arguments: [String], interactive: Bool) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            if interactive {
                showError("Helper not installed",
                          "fanctl was not found at \(helperPath).\n\nRun `make app` and `sudo make install` in the FanControl project directory first.")
            } else {
                NSLog("FanControl: helper missing at \(helperPath)")
            }
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            if interactive { showError("Failed to run helper", error.localizedDescription) }
            else { NSLog("FanControl: failed to run helper: \(error)") }
            return false
        }

        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            if interactive { showError("Could not apply preset", message) }
            else { NSLog("FanControl: helper failed: \(message)") }
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
