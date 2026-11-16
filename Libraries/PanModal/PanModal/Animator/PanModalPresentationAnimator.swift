//
//  PanModalPresentationAnimator.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 Handles the animation of the presentedViewController as it is presented or dismissed.

 This is a vertical animation that
 - Animates up from the bottom of the screen
 - Dismisses from the top to the bottom of the screen

 This can be used as a standalone object for transition animation,
 but is primarily used in the PanModalPresentationDelegate for handling pan modal transitions.

 - Note: The presentedViewController can conform to PanModalPresentable to adjust
 it's starting position through manipulating the shortFormHeight
 */

public class PanModalPresentationAnimator: NSObject {

    /**
     Enum representing the possible transition styles
     */
    public enum TransitionStyle {
        case presentation
        case dismissal
    }

    // MARK: - Properties

    /**
     The transition style
     */
    private let transitionStyle: TransitionStyle

    /**
     The gesture velocity, in points per second, that triggered this
     transition. `nil` when the transition is not driven by a gesture.
     */
    private let velocity: CGFloat?

    /**
     Haptic feedback generator (during presentation)
     */
    private var feedbackGenerator: UISelectionFeedbackGenerator?

    /**
     The animator driving the transition currently in flight.

     UIKit may ask for the interruptible animator more than once during a
     single transition, so the same instance has to be handed back every time.
     */
    private var runningAnimator: UIViewPropertyAnimator?

    // MARK: - Initializers

    required public init(transitionStyle: TransitionStyle, velocity: CGFloat? = nil) {
        self.transitionStyle = transitionStyle
        self.velocity = velocity
        super.init()

        /**
         Prepare haptic feedback, only during the presentation state
         */
        if case .presentation = transitionStyle {
            feedbackGenerator = UISelectionFeedbackGenerator()
            feedbackGenerator?.prepare()
        }
    }

    /**
     Builds the animator that presents the view controller.
     */
    private func makePresentationAnimator(transitionContext: UIViewControllerContextTransitioning) -> UIViewPropertyAnimator {

        guard
            let toVC = transitionContext.viewController(forKey: .to),
            let fromVC = transitionContext.viewController(forKey: .from)
            else {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }

        let presentable: PanModalPresentable.LayoutType? = panModalLayoutType(from: transitionContext)

        /**
         `shouldUseAppearanceTransitions == true` keeps the presenting context
         as it is, so its appearance callbacks are not forwarded.
         */
        let forwardsAppearance = presentable?.shouldUseAppearanceTransitions != true

        // Calls viewWillAppear and viewWillDisappear
        if forwardsAppearance {
            fromVC.beginAppearanceTransition(false, animated: true)
        }

        // Presents the view in shortForm position, initially
        let yPos: CGFloat = presentable?.shortFormYPos ?? 0.0

        // Use panView as presentingView if it already exists within the containerView
        let panView: UIView = transitionContext.containerView.panContainerView ?? toVC.view

        // Move presented view offscreen (from the bottom)
        panView.frame = transitionContext.finalFrame(for: toVC)
        panView.frame.origin.y = transitionContext.containerView.frame.height

        // Haptic feedback
        if presentable?.isHapticFeedbackEnabled == true {
            feedbackGenerator?.selectionChanged()
        }

        return PanModalAnimator.makeAnimator({
            panView.frame.origin.y = yPos
        },
        config: presentable,
        spring: presentable?.presentationSpring) { [weak self] _ in
            // Calls viewDidAppear and viewDidDisappear
            if forwardsAppearance {
                fromVC.endAppearanceTransition()
            }
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            self?.feedbackGenerator = nil
            self?.runningAnimator = nil
        }
    }

    /**
     Builds the animator that dismisses the view controller.

     When the dismissal was triggered by a gesture, its velocity is carried
     into the spring so the view keeps travelling at the speed the finger left
     it with instead of starting from a standstill.
     */
    private func makeDismissalAnimator(transitionContext: UIViewControllerContextTransitioning) -> UIViewPropertyAnimator {

        guard
            let toVC = transitionContext.viewController(forKey: .to),
            let fromVC = transitionContext.viewController(forKey: .from)
            else {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }

        let presentable = panModalLayoutType(from: transitionContext)

        /**
         `shouldUseAppearanceTransitions == true` keeps the presenting context
         as it is, so its appearance callbacks are not forwarded.
         */
        let forwardsAppearance = presentable?.shouldUseAppearanceTransitions != true

        // Calls viewWillAppear and viewWillDisappear
        if forwardsAppearance {
            toVC.beginAppearanceTransition(true, animated: true)
        }

        let panView: UIView = transitionContext.containerView.panContainerView ?? fromVC.view
        let destination = transitionContext.containerView.frame.height

        return PanModalAnimator.makeAnimator({
            panView.frame.origin.y = destination
        },
        config: presentable,
        spring: presentable?.dismissalSpring,
        velocity: velocity,
        remainingDistance: destination - panView.frame.origin.y) { [weak self] _ in
            fromVC.view.removeFromSuperview()
            // Calls viewDidAppear and viewDidDisappear
            if forwardsAppearance {
                toVC.endAppearanceTransition()
            }
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            self?.runningAnimator = nil
        }
    }

    /**
     Extracts the PanModal from the transition context, if it exists
     */
    private func panModalLayoutType(from context: UIViewControllerContextTransitioning) -> PanModalPresentable.LayoutType? {
        switch transitionStyle {
        case .presentation:
            return context.viewController(forKey: .to) as? PanModalPresentable.LayoutType
        case .dismissal:
            return context.viewController(forKey: .from) as? PanModalPresentable.LayoutType
        }
    }

}

// MARK: - UIViewControllerAnimatedTransitioning Delegate

extension PanModalPresentationAnimator: UIViewControllerAnimatedTransitioning {

    /**
     Returns the transition duration
     */
    public func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {

        guard
            let context = transitionContext,
            let presentable = panModalLayoutType(from: context)
            else { return PanModalAnimator.Constants.defaultTransitionDuration }

        return presentable.transitionDuration
    }

    /**
     Performs the appropriate animation based on the transition style
     */
    public func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    /**
     Returns the animator driving the transition, so UIKit can pause, reverse
     or cancel it while it is still in flight.
     */
    public func interruptibleAnimator(using transitionContext: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {

        if let runningAnimator = runningAnimator {
            return runningAnimator
        }

        let animator: UIViewPropertyAnimator
        switch transitionStyle {
        case .presentation:
            animator = makePresentationAnimator(transitionContext: transitionContext)
        case .dismissal:
            animator = makeDismissalAnimator(transitionContext: transitionContext)
        }

        runningAnimator = animator
        return animator
    }

}
#endif
