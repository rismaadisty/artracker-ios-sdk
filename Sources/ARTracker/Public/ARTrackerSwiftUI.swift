import SwiftUI

public struct ARTrackerScreenModifier: ViewModifier {
    let name: String

    public func body(content: Content) -> some View {
        content.onAppear {
            ARTracker.setScreen(name)
        }
    }
}

public struct ARTrackerMaskModifier: ViewModifier {
    public func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.accessibilityIdentifier("mask:view")
        #else
        content
        #endif
    }
}

public extension View {
    func artrackerScreen(_ name: String) -> some View {
        modifier(ARTrackerScreenModifier(name: name))
    }

    func artrackerMask() -> some View {
        modifier(ARTrackerMaskModifier())
    }
}

