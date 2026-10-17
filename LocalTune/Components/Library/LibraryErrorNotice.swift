import Foundation
import RxSwift
import UIKit

/// 曲库读不出来时那句提示 —— **文案与取舍的唯一出处**（曲库页 / 歌单页共用）。
///
/// ⚠️ 走到这儿的有两类，对用户是同一件事：观察断了（`LibraryStore` 那边写了它不会自己恢复）、
/// 或者搜索读库失败（`matchingTrackIDs` 把错误转了出来）。
///
/// ⚠️ 文案只用中文那一句 —— 底层是 SQLite 的英文报错，用户看不懂也用不上
///（跟 `LibraryDatabaseError` 里那个取舍同一条理由）。要排查时那条流上带着原文。
///
/// ⚠️ 没有「重试」按钮：观察断了不是点一下能接回来的，只能重启（`SceneDelegate` 会重建服务）——
/// 但这句**不写进提示**（文案就是「曲库读取失败」，别的一概不加）。
enum LibraryErrorNotice {

    /// 订上库错误流，来一条弹一句。
    static func bind(_ errors: Observable<Error>, disposedBy bag: DisposeBag) {
        errors
            .subscribe(onNext: { _ in
                HUD.showMessage("曲库读取失败", style: .error)
            })
            .disposed(by: bag)
    }
}
