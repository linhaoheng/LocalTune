//
//  PanModalPresentable+Defaults.swift
//  PanModal
//
//  Copyright © 2018 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 Default values for the PanModalPresentable.
 */
public extension PanModalPresentable where Self: UIViewController {
    
    var topOffset: CGFloat {
        topLayoutOffset + 21.0
    }
    
    var shortFormHeight: PanModalHeight {
        longFormHeight
    }
    
    var longFormHeight: PanModalHeight {
        
        guard let scrollView = panScrollable
        else { return .maxHeight }
        
        // called once during presentation and stored
        scrollView.layoutIfNeeded()
        return .contentHeight(scrollView.contentSize.height)
    }
    
    var cornerRadius: CGFloat {
        8.0
    }
    
    var presentationSpring: PanModalSpring {
        PanModalAnimator.Constants.defaultSpring
    }
    
    var dismissalSpring: PanModalSpring {
        presentationSpring
    }
    
    var snapSpring: PanModalSpring {
        presentationSpring
    }
    
    var minimumVelocityForBounce: CGFloat {
        PanModalAnimator.Constants.minimumVelocityForBounce
    }
    
    var transitionDuration: Double {
        PanModalAnimator.Constants.defaultTransitionDuration
    }
    
    var transitionAnimationOptions: UIView.AnimationOptions {
        [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    }
    
    var panModalBackgroundColor: UIColor {
        UIColor.black.withAlphaComponent(0.7)
    }
    
    var dragIndicatorBackgroundColor: UIColor {
        UIColor.lightGray
    }
    
    var scrollIndicatorInsets: UIEdgeInsets {
        let top: CGFloat = shouldRoundTopCorners ? cornerRadius : 0.0
        return UIEdgeInsets(top: top, left: 0, bottom: bottomLayoutOffset, right: 0)
    }
    
    var allowModifyShowScrollIndicator: Bool {
        true
    }
    
    var anchorModalToLongForm: Bool {
        true
    }
    
    var allowsExtendedPanScrolling: Bool {
        
        guard let scrollView = panScrollable
        else { return false }
        
        scrollView.layoutIfNeeded()
        return scrollView.contentSize.height > (scrollView.frame.height - bottomLayoutOffset)
    }
    
    var allowsDragToDismiss: Bool {
        true
    }
    
    var allowsTapToDismiss: Bool {
        true
    }
    
    var isUserInteractionEnabled: Bool {
        true
    }
    
    var isHapticFeedbackEnabled: Bool {
        true
    }
    
    var shouldRoundTopCorners: Bool {
        isPanModalPresented
    }
    
    var showDragIndicator: Bool {
        shouldRoundTopCorners
    }
    
    var shouldDismissWhenLongForm: Bool {
        false
    }
    
    var shouldUseAppearanceTransitions: Bool {
        false
    }
    
    var shouldAdjustToBottomSafeArea: Bool {
        true
    }
    
    func shouldBeginPanGesture(_ panModalGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        return true
    }
    
    func shouldRespond(to panModalGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        true
    }
    
    func willRespond(to panModalGestureRecognizer: UIPanGestureRecognizer) {
        
    }
    
    func shouldTransition(to state: PanModalPresentationController.PresentationState) -> Bool {
        true
    }
    
    func shouldPrioritize(panModalGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        false
    }
    
    func willTransition(to state: PanModalPresentationController.PresentationState) {
        
    }
    
    func panModalWillDismiss() {
        
    }
    
    func panModalDidDismiss() {
        
    }
}
#endif
