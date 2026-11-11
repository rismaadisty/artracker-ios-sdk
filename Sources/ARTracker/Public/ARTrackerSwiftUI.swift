import SwiftUI
#if canImport(UIKit)
import UIKit

/// Invisible zero-cost UIView injected into the UIKit hierarchy to track exact geometry of masked SwiftUI views.
public final class _ARTrackerMaskMarkerView: UIView {
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        self.artrackerMasked = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.isUserInteractionEnabled = false
        self.accessibilityElementsHidden = true
    }
}

/// Zero-cost UIViewRepresentable bridge for SwiftUI mask tracking.
public struct _ARTrackerMaskBackground: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> _ARTrackerMaskMarkerView {
        let view = _ARTrackerMaskMarkerView(frame: .zero)
        return view
    }

    public func updateUIView(_ uiView: _ARTrackerMaskMarkerView, context: Context) {}
}
#endif

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
        content
            .background(_ARTrackerMaskBackground().allowsHitTesting(false).accessibilityHidden(true))
            .accessibilityIdentifier("mask:view")
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
