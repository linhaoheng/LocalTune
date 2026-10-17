//
//  RadiusRadix.swift
//  LocalTune
//
//  L0 令牌层 · Radix Themes 圆角 —— **本文件是生成出来的，不要手改。** 改值请改生成器再跑一遍。
//
//  生成器：`scripts/generate_metrics_radix_uikit.py`
//  数据来源（唯一）：https://github.com/radix-ui/themes  ·  MIT License, (c) WorkOS
//      上游源码 packages/radix-ui-themes/src/styles/tokens/radius.css
//      钉住提交 7300f2a9be4309e04b2c1b4e43b5d7cf4a58eb43（Release 3.3.0）
//
//  重新生成：      python3 scripts/generate_metrics_radix_uikit.py
//  核对有没有被手改：python3 scripts/generate_metrics_radix_uikit.py --check
//
//  ## 分层（业务代码只用最上面一层）
//
//      页面 / 组件 → AppMetrics（语义，手写）→ RadixRadius（本文件）
//
//  ⚠️ 业务代码**不要直接用本文件**，也不要写字面圆角 —— 走 `AppMetrics`。
//
//  ## 用法
//
//      view.layer.cornerRadius   = RadixRadius.medium.r3
//      avatar.layer.cornerRadius = RadixRadius.medium.capsule
//
//  ## 五档不是「一个系数 × 六阶」
//
//      上游在根节点上用 `data-radius` 选一档，整站统一。六阶数值都乘该档的
//      `--radius-factor`；但**另外两项是各档写死的**，跟六阶不成比例：
//        `--radius-full`（胶囊形）· `--radius-thumb`（滑块拇指）
//      所以下面五套是**完整表**，不是「一个系数 + 六个基数」。
//      ⚠️ medium / large 档的 `capsule` 是 0 —— 上游原文如此，不是这里写漏。
//
//  ## `--scaling`
//
//      上游每个值都还要乘 `var(--scaling)`（整体密度档位，默认 1）。
//      本项目不做密度档位，固定 1，生成器直接忽略这一项。
//
//  ## iOS 上的对应
//
//      直接给 `CALayer.cornerRadius`（单位 pt）。上游的 9999px 就是「足够大」：
//      半径超过视图高度一半时系统按一半画，结果就是胶囊。
//

import CoreGraphics

// MARK: - 一套刻度

/// 某一档圆角风格下的完整取值：六阶 + 胶囊 + 拇指。
struct RadixRadiusScale: Equatable, Sendable {

    /// 六阶，由小到大
    let r1: CGFloat
    let r2: CGFloat
    let r3: CGFloat
    let r4: CGFloat
    let r5: CGFloat
    let r6: CGFloat

    /// 胶囊形（上游 `--radius-full`）
    let capsule: CGFloat

    /// 滑块拇指（上游 `--radius-thumb`）
    let thumb: CGFloat
}

// MARK: - 圆角令牌

/// Radix Themes 圆角令牌。**业务代码不要直接用** —— 走同目录的 `AppMetrics`。
enum RadixRadius {

    /// 上游 `none` 档（`--radius-factor: 0`）。
    static let none = RadixRadiusScale(
        r1: 0, r2: 0, r3: 0, r4: 0, r5: 0, r6: 0,
        capsule: 0, thumb: 0.5
    )

    /// 上游 `small` 档（`--radius-factor: 0.75`）。
    static let small = RadixRadiusScale(
        r1: 2.25, r2: 3, r3: 4.5, r4: 6, r5: 9, r6: 12,
        capsule: 0, thumb: 0.5
    )

    /// 上游 `medium` 档（`--radius-factor: 1`）。
    static let medium = RadixRadiusScale(
        r1: 3, r2: 4, r3: 6, r4: 8, r5: 12, r6: 16,
        capsule: 0, thumb: 9999
    )

    /// 上游 `large` 档（`--radius-factor: 1.5`）。
    static let large = RadixRadiusScale(
        r1: 4.5, r2: 6, r3: 9, r4: 12, r5: 18, r6: 24,
        capsule: 0, thumb: 9999
    )

    /// 上游 `full` 档（`--radius-factor: 1.5`）。
    static let full = RadixRadiusScale(
        r1: 4.5, r2: 6, r3: 9, r4: 12, r5: 18, r6: 24,
        capsule: 9999, thumb: 9999
    )
}
