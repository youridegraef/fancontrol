import AppKit

struct PresetSettings: Equatable {
    var autoMinTemp: Double
    var autoMaxTemp: Double
    var silentRPM: Int
    var balancedRPM: Int
    var performanceRPM: Int
    var maxRPM: Int

    static let defaultValues = PresetSettings(
        autoMinTemp: 50, autoMaxTemp: 75,
        silentRPM: 2500, balancedRPM: 4500, performanceRPM: 5000, maxRPM: 6800
    )

    private enum Key {
        static let autoMinTemp = "autoMinTemp"
        static let autoMaxTemp = "autoMaxTemp"
        static let silentRPM = "silentRPM"
        static let balancedRPM = "balancedRPM"
        static let performanceRPM = "performanceRPM"
        static let maxRPM = "maxRPM"
    }

    static func load() -> PresetSettings {
        let d = UserDefaults.standard
        func double(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
        }
        let defaults = PresetSettings.defaultValues
        return PresetSettings(
            autoMinTemp: double(Key.autoMinTemp, defaults.autoMinTemp),
            autoMaxTemp: double(Key.autoMaxTemp, defaults.autoMaxTemp),
            silentRPM: int(Key.silentRPM, defaults.silentRPM),
            balancedRPM: int(Key.balancedRPM, defaults.balancedRPM),
            performanceRPM: int(Key.performanceRPM, defaults.performanceRPM),
            maxRPM: int(Key.maxRPM, defaults.maxRPM)
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(autoMinTemp, forKey: Key.autoMinTemp)
        d.set(autoMaxTemp, forKey: Key.autoMaxTemp)
        d.set(silentRPM, forKey: Key.silentRPM)
        d.set(balancedRPM, forKey: Key.balancedRPM)
        d.set(performanceRPM, forKey: Key.performanceRPM)
        d.set(maxRPM, forKey: Key.maxRPM)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onSave: (PresetSettings) -> Void

    private let autoMinField = NSTextField()
    private let autoMaxField = NSTextField()
    private let silentField = NSTextField()
    private let balancedField = NSTextField()
    private let performanceField = NSTextField()
    private let maxField = NSTextField()

    init(settings: PresetSettings, onSave: @escaping (PresetSettings) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Edit Presets"
        super.init(window: window)
        window.delegate = self
        buildUI()
        populate(settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func row(_ label: String, _ field: NSTextField) -> NSView {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.translatesAutoresizingMaskIntoConstraints = false
            text.widthAnchor.constraint(equalToConstant: 150).isActive = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let stack = NSStackView(views: [text, field])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(reset))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [resetButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [
            row("Auto: min temp (\u{00B0}C)", autoMinField),
            row("Auto: max temp (\u{00B0}C)", autoMaxField),
            row("Silent (RPM)", silentField),
            row("Balanced (RPM)", balancedField),
            row("Performance (RPM)", performanceField),
            row("Max (RPM)", maxField),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
    }

    private func populate(_ s: PresetSettings) {
        autoMinField.stringValue = String(format: "%.0f", s.autoMinTemp)
        autoMaxField.stringValue = String(format: "%.0f", s.autoMaxTemp)
        silentField.stringValue = String(s.silentRPM)
        balancedField.stringValue = String(s.balancedRPM)
        performanceField.stringValue = String(s.performanceRPM)
        maxField.stringValue = String(s.maxRPM)
    }

    @objc private func reset() {
        populate(.defaultValues)
    }

    @objc private func save() {
        guard let autoMin = Double(autoMinField.stringValue),
              let autoMax = Double(autoMaxField.stringValue),
              let silent = Int(silentField.stringValue),
              let balanced = Int(balancedField.stringValue),
              let performance = Int(performanceField.stringValue),
              let max = Int(maxField.stringValue) else {
            showValidationError("All fields must be numbers.")
            return
        }
        guard autoMin < autoMax else {
            showValidationError("Auto min temp must be below max temp.")
            return
        }
        guard [silent, balanced, performance, max].allSatisfy({ (0...20000).contains($0) }) else {
            showValidationError("RPM values must be between 0 and 20000.")
            return
        }

        let settings = PresetSettings(
            autoMinTemp: autoMin, autoMaxTemp: autoMax,
            silentRPM: silent, balancedRPM: balanced,
            performanceRPM: performance, maxRPM: max
        )
        settings.save()
        onSave(settings)
        window?.close()
    }

    private func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid value"
        alert.informativeText = message
        alert.runModal()
    }
}
