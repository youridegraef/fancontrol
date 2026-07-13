import Foundation

struct FanPreset: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case rpm      // fixed RPM for all fans
        case sensor   // temperature curve: minTemp -> fan min, maxTemp -> fan max
    }

    var id: UUID
    var name: String
    var kind: Kind
    var rpm: Int
    var minTemp: Double
    var maxTemp: Double

    static func fixedRPM(_ name: String, _ rpm: Int) -> FanPreset {
        FanPreset(id: UUID(), name: name, kind: .rpm, rpm: rpm, minTemp: 50, maxTemp: 75)
    }

    static func sensorBased(_ name: String, minTemp: Double, maxTemp: Double) -> FanPreset {
        FanPreset(id: UUID(), name: name, kind: .sensor, rpm: 3000, minTemp: minTemp, maxTemp: maxTemp)
    }
}

enum PresetStore {
    private static let presetsKey = "presets_v1"
    private static let selectedKey = "selectedPresetID"

    static func defaultPresets() -> [FanPreset] {
        // Seed from the old scalar settings keys when present, so values
        // customized before the preset editor existed carry over.
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        return [
            .sensorBased("Auto", minTemp: double("autoMinTemp", 50), maxTemp: double("autoMaxTemp", 75)),
            .fixedRPM("Silent", int("silentRPM", 2500)),
            .fixedRPM("Balanced", int("balancedRPM", 4500)),
            .fixedRPM("Performance", int("performanceRPM", 5000)),
            .fixedRPM("Max", int("maxRPM", 6800)),
        ]
    }

    static func load() -> [FanPreset] {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let presets = try? JSONDecoder().decode([FanPreset].self, from: data),
           !presets.isEmpty {
            return presets
        }
        return defaultPresets()
    }

    static func save(_ presets: [FanPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    // Raw persisted selection: a preset UUID string, the literal "off"
    // (macOS automatic control), or nil on first run.
    static let offSelection = "off"

    static func loadSelectedRaw() -> String? {
        UserDefaults.standard.string(forKey: selectedKey)
    }

    /// Persist the selected preset, or `nil` to mean "off" (macOS automatic).
    static func saveSelected(_ id: UUID?) {
        UserDefaults.standard.set(id?.uuidString ?? offSelection, forKey: selectedKey)
    }
}
