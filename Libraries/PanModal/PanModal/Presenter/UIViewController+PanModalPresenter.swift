//
//  UIViewController+PanModalPresenterProtocol.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 Extends the UIViewController to conform to the PanModalPresenter protocol
 */
extension UIViewController: PanModalPresenter {

    /**
     A flag that returns true if the topmost view controller in the navigation stack
     was presented using the custom PanModal transition

     - Warning: ⚠️ Calling `presentationController` in this function may cause a memory leak. ⚠️

     In most cases, this check will be used early in the view lifecycle and unfortunately,
     there's an Apple bug that causes multiple presentationControllers to be created if
     the presentationController is referenced here and called too early resulting in
     a strong reference to this view controller and in turn, creating a memory leak.
     */
    public var isPanModalPresented: Bool {
        return (transitioningDelegate as? PanModalPresentationDelegate) != nil
    }

    /**
     Configures a view controller for presentation using the PanModal transition

     - Parameters:
        - viewControllerToPresent: The view controller to be presented
        - completion: The block to execute after the presentation finishes. You may specify nil for this parameter.
     */
    public func presentPanModal(_ viewControllerToPresent: PanModalPresentable.LayoutType,
                                completion: (() -> Void)? = nil) {

        /**
         Here, we deliberately do not check for size classes. More info in `PanModalPresentationDelegate`
         */

        /**
         ⚠️ 这里**以前还会看设备**：`.pad` 走 `.popover`，其余走 `.custom`（`sourceView` /
         `sourceRect` 两个参数就是给那条路用的）。那条气泡路是**坏的，而且坏得很安静** ——
         它只设了 `popoverPresentationController?.delegate`，**没设 `transitioningDelegate`**，
         于是拿到的是一个**普通气泡**：`PanModalPresentable` 那一整套（高度、圆角、下拉、弹簧）
         **一条都不生效**，连 `isPanModalPresented` 都返回 `false`。

         判据本身也错了：要不要锚在某个 view 上，是**内容**决定的，不是**设备**决定的。
         真想要气泡的，本来就该走普通的 `present(_:animated:)` + `.popover`，
         不该从 `presentPanModal` 进来 —— 名字都叫 PanModal 了，它就该在哪都是 PanModal。
         */

        viewControllerToPresent.modalPresentationStyle = .custom
        viewControllerToPresent.modalPresentationCapturesStatusBarAppearance = true
        viewControllerToPresent.transitioningDelegate = PanModalPresentationDelegate.default

        present(viewControllerToPresent, animated: true, completion: completion)
    }

}
#endif
