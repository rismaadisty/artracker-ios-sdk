#if canImport(UIKit)
import Foundation
import UIKit
import QuartzCore

private final class DisplayLinkProxy: NSObject {
    weak var owner: DisplayLinkFrameSource?

    init(owner: DisplayLinkFrameSource) {
        self.owner = owner
    }

    @objc func handleTick(_ link: CADisplayLink) {
        owner?.handleDisplayLinkTick(link)
    }
}

final class DisplayLinkFrameSource: FrameSource, @unchecked Sendable {
    private let accumulator = FrameAccumulator()
    private var displayLink: CADisplayLink?
    private var cachedMaxFPS: Double = 60.0

    deinit {
        if let link = displayLink {
            if Thread.isMainThread {
                link.invalidate()
            } else {
                DispatchQueue.main.async {
                    link.invalidate()
                }
            }
        }
    }

    func start() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
            return
        }

        guard displayLink == nil else { return }

        let maxFPS = Double(max(UIScreen.main.maximumFramesPerSecond, 60))
        cachedMaxFPS = maxFPS
        accumulator.reset()

        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.handleTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 10,
            maximum: Float(maxFPS),
            preferred: 0
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
            return
        }

        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
    }

    func drain() -> FrameWindow {
        accumulator.drain()
    }

    fileprivate func handleDisplayLinkTick(_ link: CADisplayLink) {
        let rawExpected = link.targetTimestamp - link.timestamp
        let expectedInterval = rawExpected > 0 ? rawExpected : (1.0 / cachedMaxFPS)
        accumulator.record(
            timestamp: link.timestamp,
            expectedInterval: expectedInterval,
            refreshHz: cachedMaxFPS
        )
    }
}
#endif

