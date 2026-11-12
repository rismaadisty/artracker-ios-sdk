import Foundation

protocol FrameSource: AnyObject, Sendable {
    func start()
    func stop()
    func drain() -> FrameWindow
}

