import Foundation
import IOKit

// Minimal SMC client for reading and writing fan-related keys.
// Works on Apple Silicon and Intel. Writes require root.

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case smcResult(String, UInt8)
    case unsupportedType(String, String)
    case invalidFanRange(Int)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return "IOServiceOpen failed (\(kr))"
        case .callFailed(let kr): return "IOConnectCallStructMethod failed (\(kr))"
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .smcResult(let key, let code):
            // 130 (0x82) = kSMCBadArgumentError. Two common causes on Apple
            // Silicon: another fan-control app owns the SMC, or the SMC is
            // wedged in a forced state (which a full shutdown clears - a
            // restart does not power-cycle the SMC).
            if code == 130 {
                return "SMC rejected write to \(key) (result 130). Either another fan-control app is holding the SMC (quit it), or the SMC is stuck - shut the Mac fully down (not restart), wait 30s, and power on."
            }
            return "SMC error for \(key): result \(code)"
        case .unsupportedType(let key, let type): return "Unsupported data type \(type) for key \(key)"
        case .invalidFanRange(let i): return "Fan \(i) reported an invalid RPM range; skipping write to avoid wedging the SMC."
        }
    }
}

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCGetKeyInfo: UInt8 = 9
private let kSMCKeyNotFound: UInt8 = 0x84

private func fourCC(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for c in s.utf8 { result = result << 8 | UInt32(c) }
    return result
}

private func fourCCString(_ v: UInt32) -> String {
    let chars = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: chars, encoding: .ascii) ?? "????"
}

public final class SMC {
    private var connection: io_connect_t = 0

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection, kSMCHandleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        return output
    }

    private func keyInfo(_ key: String) throws -> SMCKeyInfoData {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = kSMCGetKeyInfo
        let output = try call(&input)
        if output.result == kSMCKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.smcResult(key, output.result) }
        return output.keyInfo
    }

    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    private func readBytes(_ key: String) throws -> (type: String, data: [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCReadKey
        let output = try call(&input)
        guard output.result == 0 else { throw SMCError.smcResult(key, output.result) }
        let mirror = Mirror(reflecting: output.bytes)
        let all = mirror.children.map { $0.value as! UInt8 }
        return (fourCCString(info.dataType), Array(all.prefix(Int(info.dataSize))))
    }

    private func writeBytes(_ key: String, _ data: [UInt8]) throws {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (i, b) in data.prefix(32).enumerated() { buf[i] = b }
        }
        let output = try call(&input)
        guard output.result == 0 else { throw SMCError.smcResult(key, output.result) }
    }

    // MARK: - Typed access

    public func readFloat(_ key: String) throws -> Float {
        let (type, data) = try readBytes(key)
        switch type {
        case "flt ":
            let bits = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
            return Float(bitPattern: bits)
        case "fpe2":
            return Float(UInt16(data[0]) << 8 | UInt16(data[1])) / 4.0
        case "sp78":
            let raw = Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))
            return Float(raw) / 256.0
        case "ui8 ":
            return Float(data[0])
        case "ui16":
            return Float(UInt16(data[0]) << 8 | UInt16(data[1]))
        case "ui32":
            return Float(UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3]))
        default:
            throw SMCError.unsupportedType(key, type)
        }
    }

    public func writeFloat(_ key: String, _ value: Float) throws {
        let info = try keyInfo(key)
        switch fourCCString(info.dataType) {
        case "flt ":
            let bits = value.bitPattern
            try writeBytes(key, [
                UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF),
                UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF),
            ])
        case "fpe2":
            let fixed = UInt16(max(0, min(65535, value * 4)))
            try writeBytes(key, [UInt8(fixed >> 8), UInt8(fixed & 0xFF)])
        default:
            throw SMCError.unsupportedType(key, fourCCString(info.dataType))
        }
    }

    public func readUInt8(_ key: String) throws -> UInt8 {
        let (_, data) = try readBytes(key)
        return data.first ?? 0
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeBytes(key, [value])
    }

    // MARK: - Key enumeration

    public func allKeys() throws -> [String] {
        let count = Int(try readFloat("#KEY"))
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var input = SMCParamStruct()
            input.data8 = kSMCGetKeyFromIndex
            input.data32 = UInt32(i)
            guard let output = try? call(&input), output.result == 0 else { continue }
            keys.append(fourCCString(output.key))
        }
        return keys
    }

    // MARK: - CPU temperature

    /// SMC keys that report a plausible CPU die temperature. Key names vary
    /// per chip generation: Tp*/Te*/Tf* on Apple Silicon, TC* on Intel.
    public func cpuTemperatureKeys() throws -> [String] {
        let prefixes = ["Tp", "Te", "Tf", "TC"]
        return try allKeys().filter { key in
            guard prefixes.contains(where: key.hasPrefix) else { return false }
            guard let v = try? readFloat(key) else { return false }
            return v > 10 && v < 120
        }
    }

    /// Average over the given sensor keys, skipping ones that read invalid.
    public func averageTemperature(keys: [String]) -> Float? {
        let temps = keys.compactMap { key -> Float? in
            guard let v = try? readFloat(key), v > 10, v < 120 else { return nil }
            return v
        }
        guard !temps.isEmpty else { return nil }
        return temps.reduce(0, +) / Float(temps.count)
    }

    // MARK: - Fans

    public struct Fan {
        public let index: Int
        public let actual: Float
        public let minimum: Float
        public let maximum: Float
        public let target: Float
        public let forced: Bool
    }

    public func fanCount() throws -> Int {
        Int(try readUInt8("FNum"))
    }

    public func fan(_ i: Int) throws -> Fan {
        Fan(
            index: i,
            actual: (try? readFloat("F\(i)Ac")) ?? 0,
            minimum: (try? readFloat("F\(i)Mn")) ?? 0,
            maximum: (try? readFloat("F\(i)Mx")) ?? 0,
            target: (try? readFloat("F\(i)Tg")) ?? 0,
            forced: ((try? readUInt8("F\(i)Md")) ?? 0) != 0
        )
    }

    /// Force fan `i` to a fixed RPM (clamped to its min/max range).
    public func setFanTarget(_ i: Int, rpm: Float) throws {
        let f = try fan(i)
        // Guard against a flaky read reporting a 0/inverted range. Writing a
        // 0 target (or forcing with a bogus target) wedges the SMC into a
        // state where all F0Md writes are then rejected with result 130.
        guard f.minimum > 0, f.maximum > f.minimum else {
            throw SMCError.invalidFanRange(i)
        }
        let clamped = max(f.minimum, min(f.maximum, rpm))
        // Write a valid target *before* engaging manual mode, so the fan is
        // never in forced mode with an invalid target.
        try writeFloat("F\(i)Tg", clamped)
        if keyExists("F\(i)Md") {
            try writeUInt8("F\(i)Md", 1)
        } else if keyExists("FS! ") {
            let current = UInt16(try readFloat("FS! "))
            let mask = current | (1 << UInt16(i))
            try writeBytes("FS! ", [UInt8(mask >> 8), UInt8(mask & 0xFF)])
        }
    }

    /// Return fan `i` to automatic (SMC-managed) control.
    public func setFanAuto(_ i: Int) throws {
        if keyExists("F\(i)Md") {
            try writeUInt8("F\(i)Md", 0)
        } else if keyExists("FS! ") {
            let current = UInt16(try readFloat("FS! "))
            let mask = current & ~(1 << UInt16(i))
            try writeBytes("FS! ", [UInt8(mask >> 8), UInt8(mask & 0xFF)])
        }
    }
}
