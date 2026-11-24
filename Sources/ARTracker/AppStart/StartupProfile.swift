import Foundation
import ARTrackerNative
import Darwin

public struct LoadedImage: Sendable, Equatable {
    public let load: UInt
    public let textStart: UInt
    public let textEnd: UInt
    public let uuid: String?
    public let name: String
    public let path: String
    public let isApp: Bool

    public init(
        load: UInt,
        textStart: UInt,
        textEnd: UInt,
        uuid: String?,
        name: String,
        path: String,
        isApp: Bool
    ) {
        self.load = load
        self.textStart = textStart
        self.textEnd = textEnd
        self.uuid = uuid
        self.name = name
        self.path = path
        self.isApp = isApp
    }
}

public struct ImageTable: Sendable {
    public let images: [LoadedImage]

    public init(images: [LoadedImage]) {
        self.images = images.sorted(by: { $0.textStart < $1.textStart })
    }

    public static func current(bundlePath: String = Bundle.main.bundlePath) -> ImageTable {
        let cap: UInt32 = 2048
        var rawImages = [artn_image](repeating: artn_image(), count: Int(cap))
        let written = artn_copy_images(&rawImages, cap)

        var list: [LoadedImage] = []
        list.reserveCapacity(Int(written))

        for i in 0..<Int(written) {
            let img = rawImages[i]
            let path = img.path != nil ? String(cString: img.path) : ""
            let name = (path as NSString).lastPathComponent

            var uuidStr: String?
            if img.has_uuid {
                let u = img.uuid
                uuidStr = String(
                    format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                    u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
                )
            }

            let isApp: Bool
            if bundlePath.isEmpty || bundlePath == "/" {
                isApp = !path.hasPrefix("/usr/") && !path.hasPrefix("/System/")
            } else {
                isApp = path.hasPrefix(bundlePath)
            }

            list.append(LoadedImage(
                load: img.load,
                textStart: img.text_start,
                textEnd: img.text_end,
                uuid: uuidStr,
                name: name,
                path: path,
                isApp: isApp
            ))
        }

        return ImageTable(images: list)
    }

    public func index(of address: UInt) -> Int? {
        var low = 0
        var high = images.count - 1

        while low <= high {
            let mid = low + (high - low) / 2
            let img = images[mid]
            if address < img.textStart {
                high = mid - 1
            } else if address >= img.textEnd {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }
}

public struct ProfileImage: Codable, Equatable, Sendable {
    public let uuid: String?
    public let name: String
    public let load: String
    public let app: Bool

    enum CodingKeys: String, CodingKey {
        case uuid, name, load, app
    }
}

public struct ProfileFrame: Codable, Equatable, Sendable {
    public let a: String
    public let i: Int?
    public let sym: String?

    enum CodingKeys: String, CodingKey {
        case a, i, sym
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(a, forKey: .a)
        try container.encodeIfPresent(i, forKey: .i)
        try container.encodeIfPresent(sym, forKey: .sym)
    }
}

public struct ProfileSample: Codable, Equatable, Sendable {
    public let t: Int
    public let s: Int

    enum CodingKeys: String, CodingKey {
        case t, s
    }
}

public struct StartupProfile: Codable, Equatable, Sendable {
    public let v: Int
    public let startId: String
    public let platform: String
    public let intervalMs: Int
    public let t0: String
    public let images: [ProfileImage]
    public let frames: [ProfileFrame]
    public let stacks: [[Int]]
    public let samples: [ProfileSample]

    enum CodingKeys: String, CodingKey {
        case v
        case startId = "start_id"
        case platform
        case intervalMs = "interval_ms"
        case t0
        case images
        case frames
        case stacks
        case samples
    }
}

public enum StartupProfileBuilder {
    public static func build(
        raw: RawProfile,
        images: ImageTable,
        anchorNs: UInt64,
        startId: String,
        symbolName: (UInt) -> String? = { addr in
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0,
               let sname = info.dli_sname {
                return String(cString: sname)
            }
            return nil
        }
    ) -> StartupProfile {
        var frameMap: [UInt: Int] = [:]
        var frames: [ProfileFrame] = []
        var imageIndexMap: [Int: Int] = [:]
        var profileImages: [ProfileImage] = []

        var stackMap: [[Int]: Int] = [:]
        var stacks: [[Int]] = []
        var samples: [ProfileSample] = []

        func getOrAddImageIndex(for addr: UInt) -> (Int?, Bool) {
            guard let tableIdx = images.index(of: addr) else {
                return (nil, false)
            }
            let img = images.images[tableIdx]
            if let existingProfileIdx = imageIndexMap[tableIdx] {
                return (existingProfileIdx, img.isApp)
            }
            let newProfileIdx = profileImages.count
            imageIndexMap[tableIdx] = newProfileIdx
            let pImg = ProfileImage(
                uuid: img.uuid,
                name: img.name,
                load: String(format: "0x%lx", img.load),
                app: img.isApp
            )
            profileImages.append(pImg)
            return (newProfileIdx, img.isApp)
        }

        func getOrAddFrame(addr: UInt) -> Int {
            if let existing = frameMap[addr] {
                return existing
            }
            let (imgIdx, isApp) = getOrAddImageIndex(for: addr)
            let sym: String?
            if !isApp {
                sym = symbolName(addr)
            } else {
                sym = nil
            }
            let frameIdx = frames.count
            frameMap[addr] = frameIdx
            let pFrame = ProfileFrame(
                a: String(format: "0x%lx", addr),
                i: imgIdx,
                sym: sym
            )
            frames.append(pFrame)
            return frameIdx
        }

        for sample in raw.samples {
            let rootFirstAddrs = Array(sample.framesLeafFirst.reversed())
            var stackFrameIndices: [Int] = []
            stackFrameIndices.reserveCapacity(rootFirstAddrs.count)
            for addr in rootFirstAddrs {
                stackFrameIndices.append(getOrAddFrame(addr: addr))
            }

            let stackIdx: Int
            if let existing = stackMap[stackFrameIndices] {
                stackIdx = existing
            } else {
                stackIdx = stacks.count
                stackMap[stackFrameIndices] = stackIdx
                stacks.append(stackFrameIndices)
            }

            let tMs = sample.tNs >= anchorNs ? Int((sample.tNs - anchorNs) / 1_000_000) : 0
            samples.append(ProfileSample(t: tMs, s: stackIdx))
        }

        let intervalMs = max(1, raw.finalIntervalUs / 1000)

        return StartupProfile(
            v: 1,
            startId: startId,
            platform: "ios",
            intervalMs: intervalMs,
            t0: "process_start",
            images: profileImages,
            frames: frames,
            stacks: stacks,
            samples: samples
        )
    }
}
