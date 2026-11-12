import Foundation

struct PerfSample: Equatable, Sendable {
    let t: Int64
    let cpu: Double?
    let memMb: Double?
    let fps: Double?
    let jank: Int?
    let frozen: Int?
    let threads: Int?
    let thermal: String?
    let ramFreeMb: Int?
    let storageFreeMb: Int?
    let net: String?

    init(
        t: Int64,
        cpu: Double?,
        memMb: Double?,
        fps: Double?,
        jank: Int?,
        frozen: Int?,
        threads: Int?,
        thermal: String?,
        ramFreeMb: Int? = nil,
        storageFreeMb: Int? = nil,
        net: String? = nil
    ) {
        self.t = t
        self.cpu = cpu
        self.memMb = memMb
        self.fps = fps
        self.jank = jank
        self.frozen = frozen
        self.threads = threads
        self.thermal = thermal
        self.ramFreeMb = ramFreeMb
        self.storageFreeMb = storageFreeMb
        self.net = net
    }

    func toJSON() -> JSONValue {
        var dict: [String: JSONValue] = [
            "t": .number(Double(t))
        ]
        if let cpu = cpu {
            dict["cpu"] = .number(Self.round1(cpu))
        }
        if let memMb = memMb {
            dict["mem_mb"] = .number(Self.round1(memMb))
        }
        if let fps = fps {
            dict["fps"] = .number(Self.round1(fps))
        }
        if let jank = jank {
            dict["jank"] = .number(Double(jank))
        }
        if let frozen = frozen {
            dict["frozen"] = .number(Double(frozen))
        }
        if let threads = threads {
            dict["threads"] = .number(Double(threads))
        }
        if let thermal = thermal {
            dict["thermal"] = .string(thermal)
        }
        if let ramFreeMb = ramFreeMb {
            dict["ram_free_mb"] = .number(Double(ramFreeMb))
        }
        if let storageFreeMb = storageFreeMb {
            dict["storage_free_mb"] = .number(Double(storageFreeMb))
        }
        if let net = net {
            dict["net"] = .string(net)
        }
        return .object(dict)
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }
}

