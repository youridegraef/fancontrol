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

    // When true (default), fans are returned to macOS automatic control on
    // sleep/lid-close and the preset is re-applied on wake.
    private var resetOnSleep: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: "resetOnSleep") == nil ? true : d.bool(forKey: "resetOnSleep")
    }()

    // currentPresetID == nil means "Off" - macOS automatic control, no forcing.

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
        refreshFanRange()

        switch PresetStore.loadSelectedRaw() {
        case PresetStore.offSelection:
            currentPresetID = nil   // Off / macOS automatic
        case let raw?:
            if let id = UUID(uuidString: raw), presets.contains(where: { $0.id == id }) {
                currentPresetID = id
            } else {
                currentPresetID = presets.first?.id
            }
        case nil:
            currentPresetID = presets.first?.id   // first run
        }

        // Install/refresh the setuid helper bundled in the app (one admin
        // prompt when missing or out of date). Users who download the app
        // from a release do not need to build or run `make install`.
        HelperInstaller.ensureInstalled()

        rebuildMenu()
        temperatureTick()
        if let preset = currentPreset {
            if preset.kind == .rpm { _ = apply(preset, interactive: false) }
        } else {
            // Off: make sure fans are under macOS automatic control.
            _ = runHelper(["auto"], interactive: false)
        }
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.temperatureTick()
        }
        RunLoop.main.add(temperatureTimer!, forMode: .common)

        // Return to macOS control on sleep and re-apply on wake.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let off = NSMenuItem(title: "Off (macOS automatic)", action: #selector(selectAutomatic), keyEquivalent: "")
        off.target = self
        off.state = currentPresetID == nil ? .on : .off
        menu.addItem(off)
        menu.addItem(.separator())

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
        let sleepToggle = NSMenuItem(title: "Reset fans on sleep", action: #selector(toggleResetOnSleep), keyEquivalent: "")
        sleepToggle.target = self
        sleepToggle.state = resetOnSleep ? .on : .off
        menu.addItem(sleepToggle)
        let update = NSMenuItem(title: "Check for Updates\u{2026} (\(Updater.currentVersion))", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
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

        reassertCurrentPreset()
    }

    /// Keeps the active preset applied. If another controller (or a
    /// sleep/wake cycle) reset the fans back to SMC automatic control, the
    /// preset is re-applied so it stays sticky instead of randomly dropping
    /// out. Does nothing when Off (macOS automatic) is selected.
    private func reassertCurrentPreset() {
        guard let preset = currentPreset else { return }

        var reverted = false
        if let smc, let fan = try? smc.fan(0) { reverted = !fan.forced }

        switch preset.kind {
        case .rpm:
            if reverted { _ = runHelper(["rpm", String(preset.rpm)], interactive: false) }
        case .sensor:
            if reverted { lastAppliedCurveRPM = nil }
            if let temp = lastTemperature {
                adjustCurve(preset: preset, temperature: temp, interactive: false)
            }
        }
    }

    private func curveTargetRPM(preset: FanPreset, temperature: Float) -> Float {
        let minT = Float(preset.minTemp)
        let maxT = Float(preset.maxTemp)
        let fraction = max(0, min(1, (temperature - minT) / (maxT - minT)))
        return fanMinRPM + (fanMaxRPM - fanMinRPM) * fraction
    }

    /// Reads and caches the fan's hardware RPM range, ignoring flaky reads
    /// that report 0 or an inverted range (which would drive the curve to a
    /// 0 target and wedge the SMC).
    private func refreshFanRange() {
        guard let smc else { return }
        for _ in 0..<3 {
            if let fan = try? smc.fan(0), fan.minimum > 0, fan.maximum > fan.minimum {
                fanMinRPM = fan.minimum
                fanMaxRPM = fan.maximum
                return
            }
        }
    }

    private func adjustCurve(preset: FanPreset, temperature: Float, interactive: Bool) {
        if fanMinRPM <= 0 || fanMaxRPM <= fanMinRPM { refreshFanRange() }
        guard fanMinRPM > 0, fanMaxRPM > fanMinRPM else { return }
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
            PresetStore.saveSelected(id)
            rebuildMenu()
        }
    }

    @objc private func selectAutomatic() {
        if runHelper(["auto"], interactive: true) {
            currentPresetID = nil
            lastAppliedCurveRPM = nil
            PresetStore.saveSelected(nil)
            rebuildMenu()
        }
    }

    @objc private func toggleResetOnSleep() {
        resetOnSleep.toggle()
        UserDefaults.standard.set(resetOnSleep, forKey: "resetOnSleep")
        rebuildMenu()
    }

    // MARK: - Sleep / wake

    @objc private func systemWillSleep() {
        guard resetOnSleep, currentPreset != nil else { return }
        // Hand fans back to macOS while asleep.
        _ = runHelper(["auto"], interactive: false)
        lastAppliedCurveRPM = nil
    }

    @objc private func systemDidWake() {
        guard resetOnSleep, let preset = currentPreset else { return }
        lastAppliedCurveRPM = nil
        _ = apply(preset, interactive: false)
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

        // If the selected preset was deleted, fall back to the first one.
        // A nil id means Off (macOS automatic) and is left untouched.
        if let id = currentPresetID, !presets.contains(where: { $0.id == id }) {
            currentPresetID = presets.first?.id
            PresetStore.saveSelected(currentPresetID)
        }
        rebuildMenu()
        if let preset = currentPreset {
            lastAppliedCurveRPM = nil
            _ = apply(preset, interactive: true)
        }
    }

    // MARK: - Updates

    private var isUpdating = false

    @objc private func checkForUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        Updater.fetchLatest { [weak self] result in
            guard let self else { return }
            self.isUpdating = false
            NSApp.activate(ignoringOtherApps: true)
            switch result {
            case .failure(let error):
                self.showError("Update check failed", error.localizedDescription)
            case .success(let release):
                if Updater.isNewer(release.version, than: Updater.currentVersion) {
                    self.promptInstall(release)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "You're up to date"
                    alert.informativeText = "FanControl \(Updater.currentVersion) is the latest version."
                    alert.runModal()
                }
            }
        }
    }

    private func promptInstall(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "Update available: \(release.version)"
        var info = "You have \(Updater.currentVersion). Install \(release.version)? FanControl will restart."
        if !release.notes.isEmpty { info += "\n\n\(release.notes)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isUpdating = true
        Updater.downloadAndInstall(release) { [weak self] result in
            guard let self else { return }
            self.isUpdating = false
            switch result {
            case .success:
                // The detached installer swaps the bundle and relaunches
                // once this process exits.
                NSApp.terminate(nil)
            case .failure(let error):
                NSApp.activate(ignoringOtherApps: true)
                self.showError("Update failed", error.localizedDescription)
            }
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
        if !FileManager.default.isExecutableFile(atPath: helperPath) {
            // Helper missing (first launch, or the admin prompt was
            // cancelled). Try installing the bundled copy again.
            _ = HelperInstaller.ensureInstalled()
        }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            if interactive {
                showError("Helper not installed",
                          "fanctl was not installed at \(helperPath).\n\nAuthorize the administrator prompt so FanControl can install its helper, then try again.")
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
