import Foundation
import SMCKit

// fanctl - small CLI to read fan state and apply fan presets.
// Reads work as any user; writes require root (install setuid via `make install`).

let usage = """
usage:
  fanctl status        show fans (index, actual/min/max/target RPM, mode)
  fanctl auto          return all fans to automatic control
  fanctl set <pct>     force all fans to <pct>% of their min..max range (0-100)
  fanctl temp          show average CPU temperature
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func requireRoot() {
    guard geteuid() == 0 else {
        fail("fanctl: writing to the SMC requires root. Install with `sudo make install` or run with sudo.")
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail(usage) }

let smc: SMC
do {
    smc = try SMC()
} catch {
    fail("fanctl: \(error)")
}

do {
    let count = try smc.fanCount()

    switch args[1] {
    case "status":
        for i in 0..<count {
            let f = try smc.fan(i)
            let mode = f.forced ? "forced" : "auto"
            print(String(format: "fan %d: %.0f rpm (min %.0f, max %.0f, target %.0f, %@)",
                         i, f.actual, f.minimum, f.maximum, f.target, mode))
        }

    case "auto":
        requireRoot()
        for i in 0..<count { try smc.setFanAuto(i) }
        print("all fans set to automatic")

    case "set":
        guard args.count >= 3, let pct = Float(args[2]), (0...100).contains(pct) else {
            fail(usage)
        }
        requireRoot()
        for i in 0..<count {
            let f = try smc.fan(i)
            let rpm = f.minimum + (f.maximum - f.minimum) * pct / 100
            try smc.setFanTarget(i, rpm: rpm)
        }
        print(String(format: "all fans forced to %.0f%%", pct))

    case "temp":
        let keys = try smc.cpuTemperatureKeys()
        if let avg = smc.averageTemperature(keys: keys) {
            print(String(format: "cpu average: %.1f C (%d sensors)", avg, keys.count))
        } else {
            fail("fanctl: no CPU temperature sensors found")
        }

    default:
        fail(usage)
    }
} catch {
    fail("fanctl: \(error)")
}
