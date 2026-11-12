import Foundation

enum DeviceFacts {
    static func freeRamMb(
        freePages: UInt64,
        inactivePages: UInt64,
        speculativePages: UInt64,
        pageSize: UInt64
    ) -> Int {
        let totalBytes = Double(freePages + inactivePages + speculativePages) * Double(pageSize)
        return Int((totalBytes / 1_048_576.0).rounded())
    }

    static func freeRamMb(
        sample: (free: UInt64, inactive: UInt64, speculative: UInt64, pageSize: UInt64)?
    ) -> Int? {
        guard let sample = sample, sample.pageSize > 0 else { return nil }
        return freeRamMb(
            freePages: sample.free,
            inactivePages: sample.inactive,
            speculativePages: sample.speculative,
            pageSize: sample.pageSize
        )
    }

    static func storageMb(bytes: Int64?) -> Int? {
        guard let bytes = bytes, bytes > 0 else { return nil }
        return Int((Double(bytes) / 1_048_576.0).rounded())
    }

    static func osVersionString(major: Int, minor: Int, patch: Int) -> String {
        patch != 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }
}

