//
//  PanModalAnimator.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 Helper animation function to keep animations consistent.
 */
struct PanModalAnimator {

    /**
     Constant Animation Properties
     */
    struct Constants {
        static let defaultTransitionDuration: TimeInterval = 0.5

        /**
         The spring used when a presentable does not provide its own.

         The response matches the default transition duration, so a spring
         driven animation settles in about the time the old duration based
         animation took.
         */
        static let defaultSpring = PanModalSpring(response: 0.5, damping: 0.8)

        /**
         The absolute gesture velocity, in points per second, above which a
         gesture keeps the configured bounce. Gestures that end slower settle
         without overshooting.
         */
        static let minimumVelocityForBounce: CGFloat = 300
    }

    /**
     Runs a spring animation immediately.

     - Parameters:
        - animations: The layout changes to animate.
        - config: The presentable driving the animation, if any.
        - spring: The spring to run. Pass `nil` to use the default.
        - velocity: The gesture velocity, in points per second, at the moment
                    the gesture ended. Pass `nil` for animations that are not
                    driven by a gesture.
        - remainingDistance: The distance left to travel, in points. Used to
                             normalize `velocity` the way UIKit expects.
        - completion: Called with `true` when the animation reaches its end.

     - Returns: The animator running the animation, in case the caller needs to
                pause or cancel it.
     */
    @discardableResult
    static func animate(_ animations: @escaping PanModalPresentable.AnimationBlockType,
                        config: PanModalPresentable?,
                        spring: PanModalSpring? = nil,
                        velocity: CGFloat? = nil,
                        remainingDistance: CGFloat = 0,
                        completion: PanModalPresentable.AnimationCompletionType? = nil) -> UIViewPropertyAnimator {

        let animator = makeAnimator(animations,
                                    config: config,
                                    spring: spring,
                                    velocity: velocity,
                                    remainingDistance: remainingDistance,
                                    completion: completion)
        animator.startAnimation()
        return animator
    }

    /**
     Builds a spring animator without starting it.

     UIKit asks a transition for its interruptible animator and then drives it
     itself, so that path needs an animator that has not been started yet.

     - Returns: A ready to start animator.
     */
    static func makeAnimator(_ animations: @escaping PanModalPresentable.AnimationBlockType,
                             config: PanModalPresentable?,
                             spring: PanModalSpring? = nil,
                             velocity: CGFloat? = nil,
                             remainingDistance: CGFloat = 0,
                             completion: PanModalPresentable.AnimationCompletionType? = nil) -> UIViewPropertyAnimator {

        let animator = UIViewPropertyAnimator(duration: 0,
                                              timingParameters: timingParameters(
                                                  spring: spring ?? Constants.defaultSpring,
                                                  velocity: velocity,
                                                  remainingDistance: remainingDistance,
                                                  minimumVelocityForBounce: config?.minimumVelocityForBounce
                                                      ?? Constants.minimumVelocityForBounce))

        animator.isUserInteractionEnabled = config?.transitionAnimationOptions.contains(.allowUserInteraction) ?? true
        animator.addAnimations(animations)

        if let completion = completion {
            animator.addCompletion { position in
                completion(position == .end)
            }
        }

        return animator
    }

    /**
     Builds the timing parameters for a spring.

     `PanModalSpring` describes the spring the way SwiftUI does - a response
     time and a damping ratio - and this converts it into the mass, stiffness
     and damping coefficients `UISpringTimingParameters` takes.

     The damping ratio is adaptive. A gesture that ends slowly settles
     critically damped so the modal does not wobble back, while a gesture that
     ends fast keeps the bounce the spring asked for.

     The initial velocity is normalized the way UIKit documents it: the gesture
     velocity expressed as a fraction of the remaining distance, per second.
     The sign matters, so a gesture travelling away from its destination starts
     by overshooting in the direction it was already going.
     */
    private static func timingParameters(spring: PanModalSpring,
                                         velocity: CGFloat?,
                                         remainingDistance: CGFloat,
                                         minimumVelocityForBounce: CGFloat) -> UISpringTimingParameters {

        let dampingRatio: Double
        let normalizedVelocity: CGFloat

        if let velocity = velocity {
            dampingRatio = abs(velocity) >= minimumVelocityForBounce ? Double(spring.damping) : 1.0
            normalizedVelocity = remainingDistance == 0 ? 0 : velocity / remainingDistance
        } else {
            dampingRatio = Double(spring.damping)
            normalizedVelocity = 0
        }

        let response = spring.response

        return UISpringTimingParameters(mass: 1.0,
                                        stiffness: CGFloat(pow(2 * Double.pi / response, 2)),
                                        damping: CGFloat(4 * Double.pi * dampingRatio / response),
                                        initialVelocity: CGVector(dx: 0, dy: normalizedVelocity))
    }
}
#endif
