// Shared by Nabd and its fan helper: the System Management Controller, which holds temperatures and fan state.

import Foundation
import IOKit

struct Fan {
    var rpm: Double, min: Double, max: Double
    var fraction: Double { max > min ? Swift.min(1, Swift.max(0, (rpm - min) / (max - min))) : 0 }
}

// MARK: - SMC (CPU/GPU core temperatures and fans; reading needs no sudo, writing needs root)

final class SMC {
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]
    private(set) var cpuKeys: [UInt32] = []
    private(set) var gpuKeys: [UInt32] = []
    private var fanInfo: [(key: UInt32, min: Double, max: Double)] = []

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func name(_ k: UInt32) -> String {
        String(bytes: [UInt8(k >> 24), UInt8((k >> 16) & 0xff), UInt8((k >> 8) & 0xff), UInt8(k & 0xff)], encoding: .ascii) ?? "?"
    }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        discover()
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[key] { return cached }
        var input = KeyData()
        input.key = key
        input.data8 = 9
        guard let out = call(&input) else { return nil }
        let info = (out.keyInfo.dataSize, out.keyInfo.dataType)
        infoCache[key] = info
        return info
    }

    func has(_ key: String) -> Bool { info(SMC.fourCC(key)) != nil }

    func read(_ key: UInt32) -> Double? {
        guard let info = info(key) else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo.dataSize = info.size
        input.data8 = 5
        guard let out = call(&input) else { return nil }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.size))) }
        switch SMC.name(info.type) {
        case "flt " where b.count == 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "sp78" where b.count == 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 " where b.count == 1: return Double(b[0])
        case "ui32" where b.count == 4: return Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default: return nil
        }
    }

    /// Core sensor keys differ per chip generation, so enumerate them once instead of hardcoding.
    private func discover() {
        guard let count = read(SMC.fourCC("#KEY")) else { return }
        var alt: [UInt32] = []
        for i in 0..<UInt32(count) {
            var input = KeyData()
            input.data8 = 8
            input.data32 = i
            guard let key = call(&input)?.key, key >> 24 == 0x54 else { continue }  // "T…"
            guard let v = read(key), let type = infoCache[key]?.type, ["flt ", "sp78"].contains(SMC.name(type)) else { continue }
            guard v > 5, v < 130 else { continue }
            switch UInt8((key >> 16) & 0xff) {
            case 0x70, 0x65: cpuKeys.append(key)  // Tp… / Te…
            case 0x67: gpuKeys.append(key)        // Tg…
            case 0x66: alt.append(key)            // Tf… (M3 family)
            default: break
            }
        }
        if cpuKeys.isEmpty { cpuKeys = alt }
        let fans = Int(read(SMC.fourCC("FNum")) ?? 0)
        for i in 0..<min(fans, 4) {
            fanInfo.append((SMC.fourCC("F\(i)Ac"), read(SMC.fourCC("F\(i)Mn")) ?? 0, read(SMC.fourCC("F\(i)Mx")) ?? 0))
        }
    }

    /// Writes a value in the key's own format. The SMC accepts writes from root only, so this is for the fan helper.
    @discardableResult
    func write(_ key: String, _ value: Double) -> Bool {
        let code = SMC.fourCC(key)
        guard let info = info(code) else { return false }
        var raw = [UInt8](repeating: 0, count: Int(info.size))
        switch SMC.name(info.type) {
        case "flt " where info.size == 4: withUnsafeBytes(of: Float32(value)) { raw = Array($0) }
        case "ui8 " where info.size == 1: raw = [UInt8(max(0, min(255, value.rounded())))]
        case "ui16" where info.size == 2:
            let v = UInt16(max(0, min(65535, value.rounded())))
            raw = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "fpe2" where info.size == 2:
            let v = UInt16(max(0, min(16383, (value * 4).rounded())))
            raw = [UInt8(v >> 8), UInt8(v & 0xff)]
        default: return false
        }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = 6
        withUnsafeMutableBytes(of: &input.bytes) { buffer in for (i, byte) in raw.enumerated() { buffer[i] = byte } }
        return call(&input) != nil
    }

    func values(_ keys: [UInt32]) -> [Double] { keys.compactMap { read($0) }.filter { $0 >= 20 && $0 < 130 } }
    func fans() -> [Fan] { fanInfo.compactMap { f in read(f.key).map { Fan(rpm: $0, min: f.min, max: f.max) } } }
}

