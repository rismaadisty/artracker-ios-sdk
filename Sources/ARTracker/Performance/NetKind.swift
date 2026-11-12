import Foundation

enum NetKind {
    static func from(satisfied: Bool, wifi: Bool, cellular: Bool, wired: Bool) -> String? {
        guard satisfied else { return "none" }
        if wifi { return "wifi" }
        if cellular { return "cellular" }
        if wired { return "ethernet" }
        return nil
    }
}

