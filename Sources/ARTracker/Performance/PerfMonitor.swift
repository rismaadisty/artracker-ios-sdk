import Foundation

struct PerfDevice: Sendable, Equatable {
    let ramMb: Int
    let storageMb: Int?
    let osVersion: String?
    let cores: Int
    let refreshHz: Double?

    init(
        ramMb: Int,
        storageMb: Int? = nil,
        osVersion: String? = nil,
        cores: Int,
        refreshHz: Double?
    ) {
        self.ramMb = ramMb
        self.storageMb = storageMb
        self.osVersion = osVersion
        self.cores = cores
        self.refreshHz = refreshHz
    }

    static func current(refreshHz: Double?) -> PerfDevice {
        PerfDevice(
            ramMb: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            storageMb: DeviceFacts.storageMb(bytes: Metrics.storageCapacities().totalBytes),
            osVersion: Metrics.osVersion(),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            refreshHz: refreshHz
        )
    }
}

final class PerfMonitor: @unchecked Sendable {
    static let flushEvery = 10
    static let maxSamples = 60

    private let sampler: PerfSampler
    private let intervalMs: Int
    private let device: @Sendable () -> PerfDevice
    private let sessionId: @Sendable () -> String?
    private let userId: @Sendable () -> String?
    private let enqueue: @Sendable (Item) -> Void
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let timerLock = UnfairLock()

    private var timer: DispatchSourceTimer?
    private var samples: [PerfSample] = []
    private var bufferedSessionId: String?
    private var lastThermal: String?

    init(
        sampler: PerfSampler,
        intervalMs: Int,
        device: @escaping @Sendable () -> PerfDevice,
        sessionId: @escaping @Sendable () -> String?,
        userId: @escaping @Sendable () -> String? = { SessionManager.shared.userId },
        enqueue: @escaping @Sendable (Item) -> Void,
        queue: DispatchQueue = DispatchQueue(label: "id.art.tracker.perf", qos: .utility)
    ) {
        self.sampler = sampler
        self.intervalMs = intervalMs
        self.device = device
        self.sessionId = sessionId
        self.userId = userId
        self.enqueue = enqueue
        self.queue = queue
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        timerLock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    func start() {
        let didStart: Bool = timerLock.withLock {
            guard timer == nil else { return false }
            let t = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.milliseconds(intervalMs)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in
                self?.tickOnQueue()
            }
            t.resume()
            timer = t
            return true
        }
        if didStart {
            Reachability.shared.start()
            sampler.startFrames()
        }
    }

    func stop() {
        let didStop: Bool = timerLock.withLock {
            guard let t = timer else { return false }
            t.cancel()
            timer = nil
            return true
        }
        if didStop {
            sampler.stopFrames()
        }
    }

    func tick() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            tickOnQueue()
        } else {
            queue.async { [weak self] in
                self?.tickOnQueue()
            }
        }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            flushOnQueue()
        } else {
            queue.sync {
                self.flushOnQueue()
            }
        }
    }

    private func tickOnQueue() {
        guard let currentSessionId = sessionId() else { return }

        if let buffered = bufferedSessionId, buffered != currentSessionId {
            flushOnQueue()
        }

        let sample = sampler.sample()

        if let currentThermal = sample.thermal {
            if let previousThermal = lastThermal {
                if previousThermal != currentThermal {
                    lastThermal = currentThermal
                    let thermalItem = Item(
                        type: .event,
                        name: "perf.thermal_change",
                        sessionId: currentSessionId,
                        userId: userId(),
                        attributes: [
                            "from": .string(previousThermal),
                            "to": .string(currentThermal)
                        ]
                    )
                    enqueue(thermalItem)
                }
            } else {
                lastThermal = currentThermal
            }
        }

        bufferedSessionId = currentSessionId
        samples.append(sample)

        if samples.count >= Self.flushEvery {
            flushOnQueue()
        }
    }

    private func flushOnQueue() {
        guard !samples.isEmpty else { return }

        let targetSessionId = bufferedSessionId
        let targetUserId = userId()
        let dev = device()

        var deviceObject: [String: JSONValue] = [
            "ram_mb": .number(Double(dev.ramMb)),
            "cores": .number(Double(dev.cores))
        ]
        if let storageMb = dev.storageMb {
            deviceObject["storage_mb"] = .number(Double(storageMb))
        }
        if let osVersion = dev.osVersion, !osVersion.isEmpty {
            deviceObject["os_version"] = .string(String(osVersion.prefix(32)))
        }
        if let refreshHz = dev.refreshHz {
            deviceObject["refresh_hz"] = .number(refreshHz)
        }

        for startIdx in stride(from: 0, to: samples.count, by: Self.maxSamples) {
            let endIdx = min(startIdx + Self.maxSamples, samples.count)
            let chunk = samples[startIdx..<endIdx]
            guard let firstSample = chunk.first else { continue }

            let timestamp = DefaultClock.shared.format(
                date: Date(timeIntervalSince1970: Double(firstSample.t) / 1000.0)
            )
            let item = Item(
                type: .perf,
                name: "perf.samples",
                timestamp: timestamp,
                sessionId: targetSessionId,
                userId: targetUserId,
                attributes: [
                    "v": .number(1),
                    "platform": .string("ios"),
                    "interval_ms": .number(Double(intervalMs)),
                    "device": .object(deviceObject),
                    "samples": .array(chunk.map { $0.toJSON() })
                ]
            )
            enqueue(item)
        }

        samples.removeAll(keepingCapacity: true)
        bufferedSessionId = nil
    }
}

