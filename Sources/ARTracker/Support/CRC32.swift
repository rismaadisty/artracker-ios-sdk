import Foundation
import zlib

public struct CRC32 {
    public static func checksum(data: Data) -> UInt32 {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            let sum = crc32(0, ptr, uInt(data.count))
            return UInt32(sum)
        }
    }
}

