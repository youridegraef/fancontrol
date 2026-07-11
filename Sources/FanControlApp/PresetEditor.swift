import AppKit

// Preset editor: list of presets on the left, detail form on the right.
// Presets can be added, removed, renamed, retyped (fixed RPM or sensor
// based) and have their values changed. Changes only persist on Save.

final class PresetEditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var presets: [FanPreset]
    private let onSave: ([FanPreset]) -> Void

    private let tableView = NSTableView()
    private let addRemoveControl = NSSegmentedControl()

    private let nameField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let rpmField = NSTextField()
    private let minTempField = NSTextField()
    private let maxTempField = NSTextField()

    private var rpmRow: NSView!
    private var minTempRow: NSView!
    private var maxTempRow: NSView!
    private var detailStack: NSStackView!

    private var selectedIndex: Int = -1

    init(presets: [FanPreset], onSave: @escaping ([FanPreset]) -> Void) {
        self.presets = presets
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Preset Editor"
        super.init(window: window)
        window.delegate = self
        buildUI()
        if !presets.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Left: preset list + add/remove control
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preset"))
        column.title = "Presets"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 170).isActive = true

        addRemoveControl.segmentCount = 2
        addRemoveControl.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), forSegment: 0)
        addRemoveControl.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove"), forSegment: 1)
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveClicked)

        let left = NSStackView(views: [scroll, addRemoveControl])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6

        // Right: detail form
        func row(_ label: String, _ control: NSView) -> NSView {
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.translatesAutoresizingMaskIntoConstraints = false
            text.widthAnchor.constraint(equalToConstant: 120).isActive = true
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let stack = NSStackView(views: [text, control])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }

        typePopup.addItems(withTitles: ["Fixed RPM", "Sensor based"])
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        rpmRow = row("RPM", rpmField)
        minTempRow = row("Min temp (\u{00B0}C)", minTempField)
        maxTempRow = row("Max temp (\u{00B0}C)", maxTempField)

        let hint = NSTextField(wrappingLabelWithString:
            "Sensor based: fans run at their hardware minimum at or below min temp, at their hardware maximum at or above max temp, linear in between.")
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 280).isActive = true

        detailStack = NSStackView(views: [
            row("Name", nameField),
            row("Type", typePopup),
            rpmRow, minTempRow, maxTempRow,
            hint,
        ])
        detailStack.orientation = .vertical
        detailStack.alignment = .trailing
        detailStack.spacing = 10

        // Bottom buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1B}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let top = NSStackView(views: [left, detailStack])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 16

        let root = NSStackView(views: [top, buttons])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 210),
        ])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { presets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = presets[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        commitDetail()
        selectedIndex = tableView.selectedRow
        loadDetail()
    }

    // MARK: - Detail form

    private func loadDetail() {
        guard presets.indices.contains(selectedIndex) else {
            nameField.stringValue = ""
            rpmField.stringValue = ""
            minTempField.stringValue = ""
            maxTempField.stringValue = ""
            return
        }
        let p = presets[selectedIndex]
        nameField.stringValue = p.name
        typePopup.selectItem(at: p.kind == .rpm ? 0 : 1)
        rpmField.stringValue = String(p.rpm)
        minTempField.stringValue = String(format: "%.0f", p.minTemp)
        maxTempField.stringValue = String(format: "%.0f", p.maxTemp)
        updateRowVisibility()
    }

    /// Writes the form fields back into the working copy. Unparseable
    /// numbers keep the previous value; hard validation happens on Save.
    private func commitDetail() {
        guard presets.indices.contains(selectedIndex) else { return }
        var p = presets[selectedIndex]
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { p.name = trimmed }
        p.kind = typePopup.indexOfSelectedItem == 0 ? .rpm : .sensor
        if let rpm = Int(rpmField.stringValue) { p.rpm = rpm }
        if let minT = Double(minTempField.stringValue) { p.minTemp = minT }
        if let maxT = Double(maxTempField.stringValue) { p.maxTemp = maxT }
        presets[selectedIndex] = p
        tableView.reloadData(forRowIndexes: [selectedIndex], columnIndexes: [0])
    }

    private func updateRowVisibility() {
        let isRPM = typePopup.indexOfSelectedItem == 0
        rpmRow.isHidden = !isRPM
        minTempRow.isHidden = isRPM
        maxTempRow.isHidden = isRPM
    }

    @objc private func typeChanged() {
        updateRowVisibility()
    }

    // MARK: - Actions

    @objc private func addRemoveClicked() {
        commitDetail()
        if addRemoveControl.selectedSegment == 0 {
            let preset = FanPreset.fixedRPM("New Preset", 3000)
            presets.append(preset)
            tableView.reloadData()
            tableView.selectRowIndexes([presets.count - 1], byExtendingSelection: false)
            window?.makeFirstResponder(nameField)
        } else {
            guard presets.count > 1, presets.indices.contains(selectedIndex) else {
                NSSound.beep()
                return
            }
            presets.remove(at: selectedIndex)
            let newIndex = min(selectedIndex, presets.count - 1)
            selectedIndex = -1
            tableView.reloadData()
            tableView.selectRowIndexes([newIndex], byExtendingSelection: false)
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func save() {
        commitDetail()

        for p in presets {
            if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
                return showValidationError("Every preset needs a name.")
            }
            switch p.kind {
            case .rpm:
                guard (0...20000).contains(p.rpm) else {
                    return showValidationError("\(p.name): RPM must be between 0 and 20000.")
                }
            case .sensor:
                guard p.minTemp < p.maxTemp else {
                    return showValidationError("\(p.name): min temp must be below max temp.")
                }
                guard (0...120).contains(p.minTemp), (0...120).contains(p.maxTemp) else {
                    return showValidationError("\(p.name): temperatures must be between 0 and 120 \u{00B0}C.")
                }
            }
        }

        onSave(presets)
        window?.close()
    }

    private func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid preset"
        alert.informativeText = message
        alert.runModal()
    }
}
