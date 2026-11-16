//
//  PanModalPresentationDelegate.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 The PanModalPresentationDelegate conforms to the various transition delegates
 and vends the appropriate object for each transition controller requested.

 Usage:
 ```
 viewController.modalPresentationStyle = .custom
 viewController.transitioningDelegate = PanModalPresentationDelegate.default
 ```
 */
public class PanModalPresentationDelegate: NSObject {

    /**
     Returns an instance of the delegate, retained for the duration of presentation
     */
    public static var `default`: PanModalPresentationDelegate = {
        return PanModalPresentationDelegate()
    }()

    /**
     The gesture velocity, in points per second, that triggered the dismissal
     currently being set up.

     The presentation controller writes this just before it asks for the
     dismissal and the animator clears it as soon as it has been read, so a
     single slot is enough.
     */
    var dismissalVelocity: CGFloat?

}

extension PanModalPresentationDelegate: UIViewControllerTransitioningDelegate {

    /**
     Returns a modal presentation animator configured for the presenting state
     */
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return PanModalPresentationAnimator(transitionStyle: .presentation)
    }

    /**
     Returns a modal presentation animator configured for the dismissing state
     */
    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let animator = PanModalPresentationAnimator(transitionStyle: .dismissal, velocity: dismissalVelocity)
        dismissalVelocity = nil
        return animator
    }

    /**
     Returns a modal presentation controller to coordinate the transition from the presenting
     view controller to the presented view controller.

     Changes in size class during presentation are handled via the adaptive presentation delegate
     */
    public func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let controller = PanModalPresentationController(presentedViewController: presented, presenting: presenting)
        controller.delegate = self
        return controller
    }

}

extension PanModalPresentationDelegate: UIAdaptivePresentationControllerDelegate {

    /**
     - Note: We do not adapt to size classes. This library vends exactly one kind of
     presentation controller (`PanModalPresentationController`), and there is no way to
     swap in a different one partway through a presentation — so the custom presentation
     is kept as-is when the size class changes.

     ⚠️ 这里原来还并列着 `UIPopoverPresentationControllerDelegate`：那是给 `presentPanModal`
     以前那条「iPad 走气泡」的路用的。那条路已经删了（见 `UIViewController+PanModalPresenter`），
     所以这个 conformance 一并去掉 —— 留着只会让读的人以为本库还支持气泡。
     */

    /**
     Dismisses the presented view controller
     */
    public func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }

}
#endif
