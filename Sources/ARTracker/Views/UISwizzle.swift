import Foundation
#if canImport(UIKit)
import UIKit

public final class UISwizzle: @unchecked Sendable {
    public static let shared = UISwizzle()

    private let lock = UnfairLock()
    private var isSwizzled: Bool = false

    public func enable() {
        lock.withLock {
            guard !isSwizzled else { return }
            isSwizzled = true

            let originalSelector = #selector(UIViewController.viewDidAppear(_:))
            let swizzledSelector = #selector(UIViewController.artracker_viewDidAppear(_:))

            guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
                  let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector) else {
                return
            }

            let didAddMethod = class_addMethod(
                UIViewController.self,
                originalSelector,
                method_getImplementation(swizzledMethod),
                method_getTypeEncoding(swizzledMethod)
            )

            if didAddMethod {
                class_replaceMethod(
                    UIViewController.self,
                    swizzledSelector,
                    method_getImplementation(originalMethod),
                    method_getTypeEncoding(originalMethod)
                )
            } else {
                method_exchangeImplementations(originalMethod, swizzledMethod)
            }
        }
    }
}

extension UIViewController {
    @objc func artracker_viewDidAppear(_ animated: Bool) {
        artracker_viewDidAppear(animated)

        let className = String(describing: type(of: self))
        guard !className.hasPrefix("_"),
              !className.hasPrefix("UIInput"),
              !className.hasPrefix("UICompatibility"),
              !className.contains("HostingController") else {
            return
        }

        ARTracker.shared.recordScreenView(name: className, view: self.viewIfLoaded)
    }
}
#endif

