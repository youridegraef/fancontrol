import AppKit
import SMCKit

// FanControl - minimal menu bar app. Shows average CPU temperature and
// applies user-defined fan presets via the setuid fanctl helper.
//
// Presets are either a fixed RPM or sensor based (temperature curve:
// fans at hardware minimum at or below minTemp, hardware maximum at or
// above maxTemp, linear in between, re-evaluated on every tick).

let helperPath = "/usr/local/bin/fanctl"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var presets = PresetStore.load()
    private var currentPresetID: UUID?
    private var editorController: PresetEditorController?

    private var smc: SMC?
    private var temperatureKeys: [String] = []
    private var temperatureTimer: Timer?
    private var lastTemperature: Float?

    private var fanMinRPM: Float = 0
    private var fanMaxRPM: Float = 0
    private var lastAppliedCurveRPM: Float?

    private var currentPreset: FanPreset? {
        presets.first { $0.id == currentPresetID }
    }

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

        if let saved = PresetStore.loadSelectedID(), presets.contains(where: { $0.id == saved }) {
            currentPresetID = saved
        } else {
            currentPresetID = presets.first?.id
        }

        rebuildMenu()
        temperatureTick()
        if let preset = currentPreset, preset.kind == .rpm {
            _ = apply(preset, interactive: false)
        }
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.temperatureTick()
        }
        RunLoop.main.add(temperatureTimer!, forMode: .common)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        for preset in presets {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.id == currentPresetID ? .on : .off
            menu.addItem(item)
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
    }

    // MARK: - Temperature + sensor curve

    private func temperatureTick() {
        guard let smc, !temperatureKeys.isEmpty,
              let avg = smc.averageTemperature(keys: temperatureKeys) else {
            statusItem.button?.title = "--\u{00B0}C"
            return
        }
        lastTemperature = avg
        statusItem.button?.title = "\(Int(avg.rounded()))\u{00B0}C"

        if let preset = currentPreset, preset.kind == .sensor {
            adjustCurve(preset: preset, temperature: avg, interactive: false)
        }
    }

    private func curveTargetRPM(preset: FanPreset, temperature: Float) -> Float {
        let minT = Float(preset.minTemp)
        let maxT = Float(preset.maxTemp)
        let fraction = max(0, min(1, (temperature - minT) / (maxT - minT)))
        return fanMinRPM + (fanMaxRPM - fanMinRPM) * fraction
    }

    private func adjustCurve(preset: FanPreset, temperature: Float, interactive: Bool) {
        guard fanMaxRPM > fanMinRPM else { return }
        let target = curveTargetRPM(preset: preset, temperature: temperature)
        if let last = lastAppliedCurveRPM, abs(target - last) < 100 { return }
        if runHelper(["rpm", String(Int(target))], interactive: interactive) {
            lastAppliedCurveRPM = target
        }
    }

    // MARK: - Menu actions

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = presets.first(where: { $0.id == id }) else { return }
        if apply(preset, interactive: true) {
            currentPresetID = id
            PresetStore.saveSelectedID(id)
            rebuildMenu()
        }
    }

    @objc private func editPresets() {
        if editorController == nil {
            editorController = PresetEditorController(presets: presets) { [weak self] newPresets in
                self?.presetsSaved(newPresets)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        editorController?.window?.center()
        editorController?.showWindow(nil)
    }

    private func presetsSaved(_ newPresets: [FanPreset]) {
        presets = newPresets
        PresetStore.save(presets)
        editorController = nil

        if currentPreset == nil {
            currentPresetID = presets.first?.id
            PresetStore.saveSelectedID(currentPresetID)
        }
        rebuildMenu()
        if let preset = currentPreset {
            lastAppliedCurveRPM = nil
            _ = apply(preset, interactive: true)
        }
    }

    @objc private func quit() {
        // Safety: return fans to SMC-managed automatic control before exiting.
        _ = runHelper(["auto"], interactive: false)
        NSApp.terminate(nil)
    }

    // MARK: - Applying presets

    private func apply(_ preset: FanPreset, interactive: Bool) -> Bool {
        switch preset.kind {
        case .rpm:
            return runHelper(["rpm", String(preset.rpm)], interactive: interactive)
        case .sensor:
            lastAppliedCurveRPM = nil
            if let temp = lastTemperature {
                adjustCurve(preset: preset, temperature: temp, interactive: interactive)
            }
            return true
        }
    }

    /// Runs the fanctl helper. When `interactive` is false (background curve
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

private extension FanPreset {
    var title: String {
        switch kind {
        case .rpm: return "\(name) (\(rpm) RPM)"
        case .sensor: return "\(name) (\(Int(minTemp))-\(Int(maxTemp))\u{00B0}C)"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
