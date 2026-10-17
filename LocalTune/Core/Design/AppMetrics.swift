import UIKit

/// 尺寸与间距令牌 —— 页面里**不许出现裸数字**，一律从这里取。
///
/// 间距档位名就是点数：8 / 10 / 12 / 15 / 16 / 18 / 20 / 24。
/// 这八个值不是等比数列，是实际版式里用得上的那一组；
/// 硬起「小 / 中 / 大」这种名字反而会跟真实用法对不上。
///
/// 所以下面每一项都**不写用途** —— 写了就是猜。选哪一档看版式需要的实际点数。
///
/// ⚠️ 圆角也一样**按页面积累**：**每加一项都要说得出出处**（哪一页用、值从哪来）。
/// 现在只有浮层那一项（`hudCornerRadius`）—— 那是第一个真用到圆角的组件；
/// 别的圆角等各自的页面，别提前定几档出来。
enum AppMetrics {

    /// 描边宽度。
    static let borderWidth: CGFloat = 1

    static let s8: CGFloat = 8
    static let s10: CGFloat = 10
    static let s12: CGFloat = 12
    static let s15: CGFloat = 15
    static let s16: CGFloat = 16
    static let s18: CGFloat = 18
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24

    // MARK: - 浮层（导入进度 / 提示）

    /// 浮层圆角 —— `medium` 档第 6 阶，**16**。
    ///
    /// 浮层的效果值就是 16，跟 `RadixRadius.medium.r6` **正好同值** ——
    /// 所以这一项走令牌、不写裸数字。
    static let hudCornerRadius: CGFloat = RadixRadius.medium.r6

    /// 浮层的最小尺寸 —— 内容再少，浮层也不小于这么大。
    ///
    /// 这版浮层的设计值；要调就改这里。
    static let hudMinimumSize = CGSize(width: 150, height: 120)

    /// 提示浮层的**最短停留时间**（秒）—— 太快闪一下看不清。
    ///
    /// 这版浮层的设计值；要调就改这里。
    static let hudMinimumDismissInterval: TimeInterval = 1.5

    // MARK: - 导航栏

    /// 导航栏上**自绘按钮**的图标点大小 —— 目的是跟旁边系统那两个 `UIBarButtonItem` 的图标齐平。
    ///
    /// 🔴 为什么得自己定：`UIBarButtonItem` 会按导航栏的规格给 SF Symbol 套一层配置，
    /// **自绘按钮吃不到那一层** —— 不管的话图标就按 SF Symbol 的默认大小渲，
    /// 夹在两个系统按钮中间会明显小一圈。
    ///
    /// ⚠️ 这一档是**实机比出来的**：默认大小（17）夹在旁边两个系统按钮中间显得小，
    /// 22 又偏大 —— 20 落在中间。**要调就改这里。**
    static let barButtonIconPointSize: CGFloat = 20

    // MARK: - 迷你播放条
    //
    // 这一节是**这条子的版式规格**：它要跟系统播放条一样高、封面一样大、键一样宽，
    // 所以这一组数是**按那个版式定的**，不是"某个文档里抄来的"。
    // 改尺寸就改这里 —— 页面和组件都从这儿取。

    /// 整条高：**60**。
    ///
    /// ⚠️ 这个数**同时**是条子高度和"页面要让出的底边距"
    /// （见 `MiniBarNavController.applyBottomInset`），
    /// 两处必须一致 —— 所以只有这一个出口。
    static let miniPlayerBarHeight: CGFloat = 60

    /// 封面边长：**40**。
    ///
    /// ⚠️ 这个数和两个键的宽度**就是同一个尺寸**（版式上它们一样大）。
    /// 我们拆成两个名字只为各自好用，**值天然同源**（下面那个计算属性引用了它）。
    static let miniPlayerArtworkSize: CGFloat = 40

    /// 封面圆角：**8**（系统播放条那一档的小圆角）。
    static let miniPlayerArtworkCornerRadius = RadixRadius.medium.r4

    /// 条上两个键的**宽**：直接就是封面那个数。
    ///
    /// ⚠️ **高度不在这儿** —— 键的高是**撑满整条**，所以点击区是 `40 × 60`，
    /// 比图标本身大得多（这正是"点击区够大"的做法）。
    static var miniPlayerButtonWidth: CGFloat { miniPlayerArtworkSize }

    /// 条上键图标的点大小：**17**。
    ///
    /// 出处：SF Symbol 的**正文那一档默认大小**（`UIButton(type: .system)` 配
    /// `UIImage(systemName:)` 就是这个数）。我们这边图标必须自带尺寸
    /// （`PressScaleButton` 就是这么设计的），所以把这个默认值写出来。
    ///
    /// ⚠️ 跟上面那个 `barButtonIconPointSize`（20）**不是一件事**：那个是为了跟导航栏里
    /// 系统按钮的图标齐平（实机比出来的）。
    static let miniPlayerButtonIconPointSize: CGFloat = 17

    /// 下一首键距**右缘**：**25**。
    ///
    /// ⚠️ 这是条子里唯一一个**不在间距档位里**的数（档位是 8/10/12/15/16/18/20/24）——
    /// 因为它只有这一处用，按项目规矩就不往档位表里塞了。
    static let miniPlayerNextButtonTrailingInset: CGFloat = 25

    /// 条子和标签栏之间那条**发丝分隔线**的高：**0.5**。
    ///
    /// ⚠️ 它**不是**"1 物理像素"（那是系统自己画分隔线时的惯例），是**设计值 0.5**。
    static let miniPlayerSeparatorHeight: CGFloat = 0.5

    /// 条子顶上那条进度的高：**1**。条高 60 不动。
    static let miniPlayerProgressHeight: CGFloat = 1

    /// 进度走条叠在强调色上的透明度：**0.7**（参考指定，不是 Fangorn RGB）。
    static let miniPlayerProgressFillAlpha: CGFloat = 0.7

    /// 那条分隔线显隐的**淡入淡出时长**：**0.2 秒**。
    ///
    /// ⚠️ 跟 `pressDownDuration` 的 0.2 **是两件事** —— 值碰巧一样，**别并成一条**
    /// （改一个不该带着另一个动）。
    static let miniPlayerSeparatorFadeDuration: TimeInterval = 0.2

    // MARK: - 迷你播放条 · 顶部阴影

    /// 条子顶部那道阴影的三个值。
    ///
    /// - `opacity 0.06`；
    /// - `offset (0, -3)` —— **往上** 3 点 ⇒ 影子落在条子**顶边上方**；
    /// - `radius 3` —— 刻意的 3（不是"没设所以走了默认值"）：显式写出来，读的人不用去猜。
    ///
    /// ⚠️ 颜色不在这儿 —— 在 `AppColor.shadow`。
    /// 阴影强度：颜色在 `AppColor.shadow`（纯黑），只在这儿设一次透明度。
    static let miniPlayerShadowOpacity: Float = 0.06
    static let miniPlayerShadowVerticalOffset: CGFloat = -3
    static let miniPlayerShadowRadius: CGFloat = 3

    // MARK: - 迷你播放条 · 左右滑切歌

    /// 水平位移超过此值 ⇒ 提交切歌：**80**。
    static let miniPlayerSwipeCommitDistance: CGFloat = 80

    /// 松手瞬时速度超过此值、且与位移同号 ⇒ 提交切歌：**500**。
    static let miniPlayerSwipeCommitVelocity: CGFloat = 500

    /// 方向切换死区：超过这点才换预览内容：**10**。
    static let miniPlayerSwipeDirectionDeadZone: CGFloat = 10

    /// 滑动中当前封面/标题透明度衰减系数：**0.7**。
    static let miniPlayerSwipeCurrentFadeFactor: CGFloat = 0.7

    /// 滑动中预览透明度上升系数：**1.5**。
    static let miniPlayerSwipePreviewRiseFactor: CGFloat = 1.5

    /// 提交切歌滑出动画时长：**0.2**。
    static let miniPlayerSwipeCommitDuration: TimeInterval = 0.2

    /// 回弹弹簧：时长 **0.25** / damping **0.7** / 初速 **0.5**。
    static let miniPlayerSwipeSpringDuration: TimeInterval = 0.25
    static let miniPlayerSwipeSpringDamping: CGFloat = 0.7
    static let miniPlayerSwipeSpringVelocity: CGFloat = 0.5

    // MARK: - 跑马灯（迷你条 / 播放页歌名共用速率与渐隐）

    /// 滚动速率（点/秒）—— 迷你条 / 播放页**共用这一档 32**。
    static let marqueeScrollRate: CGFloat = 32

    /// 两端渐隐长度：**10**。
    static let marqueeFadeLength: CGFloat = 10

    /// 播放页歌名尾缓冲：**32**（迷你条不设这一项）。
    static let nowPlayingMarqueeTrailingBuffer: CGFloat = 32

    /// 播放页歌名开始滚之前的停顿：**1.2** 秒。
    static let nowPlayingMarqueeStartDelay: TimeInterval = 1.2

    // MARK: - 播放可靠性

    /// `encounteredError` 宽限。出处：Cosmos 400ms。
    static let engineErrorGrace: TimeInterval = 0.4

    /// 「在播但位置不动」多久算卡死。出处：Cosmos `stallDetectionWindow` 1.5s。
    static let playbackStallWindow: TimeInterval = 1.5

    /// 进度差小于这个不算动了。出处：Cosmos 0.001。
    static let playbackStallEpsilon: TimeInterval = 0.001

    /// stall 自动重建冷却。出处：Cosmos `stalledSFBRecoveryCooldown` 10s。
    static let playbackStallRecoveryCooldown: TimeInterval = 10

    // MARK: - 播放存档

    /// 距开头不到这么多秒不算有效续播点。出处：primuse `minimumMeaningfulResumeTime`。
    static let playbackSessionMeaningfulResume: TimeInterval = 3

    // MARK: - 播放页（满屏弹层）

    /// 播放页**上边两角**的圆角：手机 **20**、iPad **18**。**定稿。**
    ///
    /// iPad **18** 对着屏幕自己的圆角（2018 以后圆角屏；直角屏这个数没意义）。
    /// 手机曾手调到 **43**（想跟屏幕圆角同心）。深色模式、只开播放页进
    /// 卡片式后台，右上会露一点黑 —— **43 会、20 不会**（真机验证）。
    /// 要调就改这里。
    ///
    /// ⚠️ 判设备读 `UIDevice.current.userInterfaceIdiom`（跟 `BaseViewController` 那条一致）——
    /// 这里读的是**全局事实**（这是台什么设备），不是调用点能选的东西，所以做成属性而不是
    /// 要传参的函数：`AppMetrics` 里每一项都该是「拿来就用」。
    static var nowPlayingSheetCornerRadius: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 18 : 20
    }

    // MARK: - 播放页（满屏弹层的内容）

    /// 内容区左右边距 —— **信息行 / 进度块**用它：**30**。
    ///
    /// ⚠️ 曾经写 24（那个值是从别处量的，跟这一页的取景不配），
    /// 按信息行 / 进度块两处实际用到的内缩统一成 30；
    /// **封面不吃这个数**（它的 30 是内部的 `nowPlayingCoverInset`），**音质条也不吃**（见下一项）。
    static let nowPlayingHorizontalInset: CGFloat = 30

    /// 音质条左右边距：**48** —— 比别的块窄（它是条"胶囊"，不铺满）。
    ///
    static let nowPlayingQualityHorizontalInset: CGFloat = 48

    /// 音质条距**安全区顶**：**44**；高度：**24**。
    ///
    /// 🔴 **两个都是固定值** —— 这一条**不跟着字体行高走**，也**不因为"没有音质信息"而收起**。
    /// ⚠️ 曾经把高度做成"一行字那么高"（≈13）⇒ 位置和大小整个不对。
    /// ⚠️ 高度是**写死的**（`make.height.equalTo(24)`），所以就算 `qualityInfoView.isHidden = true`，
    /// 这一格照样占着 —— 封面于是**永远**停在 `安全区 + 72`，不会往上顶。
    ///
    /// ⚠️ **44 比顶部那排键的底边（`chromeTopInset 12 + 键高 40 = 52`）还靠上** ——
    /// 音质条和那排键在竖直方向**重叠 8 点**。这是版式本身如此，不是写错了：
    /// 那排键只在左 / 右两头，中间是空的，音质条从 44 起正好从它们中间穿过去。
    static let nowPlayingQualityTopOffset: CGFloat = 44
    static let nowPlayingQualityBarHeight: CGFloat = 24

    /// 信息行的上下内边距与行距：**上 10 · 行距 15 · 下 10**。
    ///
    /// ⇒ 这块的高度是这么长出来的：`10 + 标题 + 15 + 副标题 + 10 ≈ 73.4` ——
    /// ⚠️ **73.4 是算出来的结果，不是拍进去的输入**（曾经反过来把 73.67 当输入用，
    /// 一改字号就跟真实的行高对不上）。
    static let nowPlayingInfoTopPadding: CGFloat = 10
    static let nowPlayingInfoLineGap: CGFloat = 15
    static let nowPlayingInfoBottomPadding: CGFloat = 10

    /// 进度块的上下内边距与"时间距滑杆"：**上 10 · 距滑杆 6 · 下 10**。
    ///
    /// ⇒ 块高 = `10 + 滑杆 16 + 6 + 时间 + 10 ≈ 55`（另有资料记的是 54.33，
    /// 差在把时间行算窄了，以这个为准）。
    static let nowPlayingProgressTopPadding: CGFloat = 10
    static let nowPlayingProgressLabelGap: CGFloat = 6
    static let nowPlayingProgressBottomPadding: CGFloat = 10

    /// 大封面四边的让位：**30**。
    ///
    /// 🔴 这 30 是**反推出来的**：那份实现把竖屏封面让位写成了一个 double 的位模式
    /// `0x403E000000000000`，解出来正好 30.0（横屏那一支 `0x4030000000000000` = 16.0）。
    /// —— 不是随手取的整数。
    static let nowPlayingCoverInset: CGFloat = 30

    /// 手机横屏封面让位：**16**（就是上面那个位模式的横屏那一支）。
    static let nowPlayingCoverLandscapeInset: CGFloat = 16

    /// 手机横屏：顶让 **20**、底让 **6**、歌词顶缝 **8**。
    ///
    static let nowPlayingLandscapeTopInset: CGFloat = 20
    static let nowPlayingLandscapeBottomInset: CGFloat = 6
    static let nowPlayingLandscapeLyricsTopGap: CGFloat = 8

    /// 手机横屏封面宽 = 父宽 × **0.46**，水平中心 = 父中心 × **0.5**。
    static let nowPlayingLandscapeCoverWidthFraction: CGFloat = 0.46
    static let nowPlayingLandscapeCoverCenterFraction: CGFloat = 0.5

    /// 手机横屏进度宽 = 封面宽 × **0.85**。
    static let nowPlayingLandscapeProgressWidthFraction: CGFloat = 0.85

    /// iPad 横屏：开歌词时栏宽 = `0.5×w − 80`；关歌词时列宽 `min(w, 500)`；左右边 **40**；歌词顶 **80**。
    static let nowPlayingPadLandscapeColumnInset: CGFloat = 80
    static let nowPlayingPadLandscapeMaxWidth: CGFloat = 500
    static let nowPlayingPadLandscapeSideInset: CGFloat = 40
    static let nowPlayingPadLandscapeLyricsTop: CGFloat = 80

    /// 信息行横屏只剩歌名时，顶让 **4**。
    static let nowPlayingInfoLandscapeTopPadding: CGFloat = 4

    /// 转屏换约束的时长：**0.28**。走 `viewWillTransition` 时用系统 coordinator，这条给分屏那种不走 transition 的。
    static let nowPlayingLayoutDuration: TimeInterval = 0.28

    /// 封面盒子上边与**音质条**之间的让位：**4**。
    ///
    /// 🔴 **这 4 点在上面、不在下面**。竖屏的约束是
    /// `coverView.top = safeArea + coverTopOffset(72)`、`coverView.bottom = songInfo.top` ——
    /// 而 `72 = qualityTopOffset(44) + qualityBarHeight(24) + 4`，**正好是"音质条底下再留 4"**；
    /// 底边那一头**紧贴**信息行，没有间隙。
    /// 反过来验：`coverView.height = infoView.minY − qualityInfoView.maxY − 4` 算出来的
    /// 也是同一个 4 —— 两处对得上。
    ///
    /// ⚠️ 曾经按"底边让位"写（`coverView.bottom = infoView.top − 4`）⇒ 封面整体**偏下 4 点**。
    /// ⚠️ 名字也一并改了：曾经那个常量叫 `coverBottomGap`，但它量的是封面**上边**那条缝 ——
    /// 照那个名字读，会把这 4 点放到错误的一头。
    static let nowPlayingCoverTopGap: CGFloat = 4

    /// 封面长边上限：**600**。
    ///
    /// 🔴 手机上永远碰不到（屏宽 − 60 < 600），**只在 iPad 上起作用**：
    /// 没有它，iPad 竖屏的封面会撑到 `屏宽 − 60`（834 宽的机器上 774 点），
    /// 整页的比例就散了 —— 这是曾经"iPad 上封面比例不好看"的主因。
    static let nowPlayingCoverMaxSide: CGFloat = 600

    /// 封面圆角：**15**，**连续曲率**（＝ `AppMetrics.s15`）。
    ///
    /// ⚠️ 曾经是 10 —— 那个值是从别处量的，跟这一页的取景不配。
    static let nowPlayingCoverCornerRadius: CGFloat = 15

    /// 封面阴影：**opacity 0.6 · radius 15 · 偏移 (1, 1)**。
    ///
    /// 是一圈**贴着封面的实影**，不是铺开的大光晕。
    /// ⚠️ 曾经是 `0.5 / 100 / (0, 10)`：半径 100 会把影子往外糊出一大片，
    /// 在取色渐变上看着是封面四周一圈发灰的晕 —— 这一页最扎眼的一处。
    static let nowPlayingCoverShadowOpacity: Float = 0.6
    static let nowPlayingCoverShadowRadius: CGFloat = 15
    static let nowPlayingCoverShadowOffset = CGSize(width: 1, height: 1)

    // MARK: - 播放页封面 · 随播放态缩放（暂停缩、播放放）

    /// 暂停时的缩放：**0.835**（暂停态 ÷ 播放态）—— **真机手改**。
    ///
    /// 录屏实测是 **0.732**（暂停 575×574 px vs 播放 786×787 px；logo 194/142 独立第二证，两把尺子差 0.7%）——
    /// 真机上觉得"缩得有点小"，**手改到 0.835**。
    ///
    /// 🔴 **真机观感 > 录屏实测**：实测值是参照、不是出货标准。观感仍是"改尺寸"不是"缩一点"。
    /// ⚠️ 这几个数**没有外部出处** —— 是**真机手改定的**，性质跟 PanModal 那三条 spring 一样
    static let nowPlayingCoverPausedScale: CGFloat = 0.835

    /// 放大（暂停 → 播放）：**0.8 s、阻尼 0.57** —— 带过冲。
    ///
    /// 录屏实测 ≈ **0.60 s**（起 2.867 s → 归位 3.467 s；过冲 11.4% 行程 ⇒ ζ ≈ 0.57）；
    /// 真机上觉得"有点短" ⇒ **手改 0.8**。🔴 **真机观感 > 录屏实测**。
    /// 尾巴那段振荡不能切 —— 切了就成了"啪一下停"。
    static let nowPlayingCoverExpandDuration: TimeInterval = 0.8
    static let nowPlayingCoverExpandDamping: CGFloat = 0.57

    /// 缩小（播放 → 暂停）：**0.7 s、阻尼 1.0** —— 单调、无下冲。
    ///
    /// 录屏实测 ≈ **0.50 s**（起 6.550 s → 定 7.050 s），真机上觉得"有点短" ⇒ **手改 0.7**。
    ///
    /// 🔴 **两条曲线不对称，别并成一条**：放大带弹（0.57）、缩小不带（1.0）。
    static let nowPlayingCoverShrinkDuration: TimeInterval = 0.7
    static let nowPlayingCoverShrinkDamping: CGFloat = 1.0

    // MARK: - 播放页封面 · 左右拖切歌

    /// 水平位移超过此值 ⇒ 提交切歌。
    ///
    /// 🔴 **100，不是迷你条那 80** —— 播放页封面大一圈、拖起来行程也长，阈值跟着放大。
    static let nowPlayingCoverSwipeCommitDistance: CGFloat = 100

    /// 松手瞬时速度超过此值、且与位移同号 ⇒ 提交切歌：**500**（和迷你条同一档）。
    static let nowPlayingCoverSwipeCommitVelocity: CGFloat = 500

    /// 方向切换死区：超过这点才换预览图：**10**（和迷你条同一档）。
    static let nowPlayingCoverSwipeDirectionDeadZone: CGFloat = 10

    /// 滑动中当前封面透明度衰减系数：**0.7**（和迷你条同一档）。
    static let nowPlayingCoverSwipeCurrentFadeFactor: CGFloat = 0.7

    /// 滑动中预览透明度上升系数：**1.5**（和迷你条同一档）。
    static let nowPlayingCoverSwipePreviewRiseFactor: CGFloat = 1.5

    /// 提交切歌滑出动画时长：**0.25**（迷你条是 0.2，**别并成一条**）。
    static let nowPlayingCoverSwipeCommitDuration: TimeInterval = 0.25

    /// 回弹弹簧：时长 **0.3** / damping **0.7** / 初速 **0.5**（迷你条时长是 0.25，**别并**）。
    static let nowPlayingCoverSwipeSpringDuration: TimeInterval = 0.3
    static let nowPlayingCoverSwipeSpringDamping: CGFloat = 0.7
    static let nowPlayingCoverSwipeSpringVelocity: CGFloat = 0.5

    /// 播放页顶部那排键（关闭 / 更多 / 歌词设置）的尺寸：**40 × 40**；
    /// 其中「**更多**」那颗是**宽键 45 × 40**（三个点横着占地方）。
    ///
    /// ⚠️ **40 比 HIG 那条"点击区不小于 44"小** —— 但这一排的版式就是照 40 定的，
    /// 整体放大顶掉版式；真机上要是觉得不好点，就单独给某颗键扩热区。
    static let nowPlayingChromeButtonSide: CGFloat = 40
    static let nowPlayingChromeButtonHeight: CGFloat = 40
    static let nowPlayingChromeWideSide: CGFloat = 45

    /// 顶部那排键的边距与键间距离：**左 16 · 上 12 · 右 16 · 键间 8**。
    ///
    /// 🔴 这四个数**推翻过一次**：早先取的是 左 10 / 上 10 / 右 5 / 键间 10，
    /// 同机 885×1920 实测下来关闭键中心偏左 **5.3pt**、右上两颗偏右 **8~10pt** —— 肉眼一眼看得出来。
    /// 换成现在这套之后三颗都落在 ~1pt 内 —— **别再退回那组数**。
    static let nowPlayingChromeLeadingInset: CGFloat = 16
    static let nowPlayingChromeTopInset: CGFloat = 12
    static let nowPlayingChromeTrailingInset: CGFloat = 16
    static let nowPlayingChromeGap: CGFloat = 8

    /// 信息行右侧「收藏 / 引用」两颗键之间的距离：**12**。
    ///
    static let nowPlayingInfoActionGap: CGFloat = 12

    /// 传输行三个键：中间那个播放键的点击区 **60**，两侧键 **40 × 60**。
    ///
    /// ⚠️ 这三个数是"**可能被手调过**"的那一类 —— 真机上看效果再动。
    /// 但它们只在传输行里用，所以走令牌、不写裸数字。
    static let nowPlayingPlayButtonSize: CGFloat = 60
    static let nowPlayingSideButtonWidth: CGFloat = 40
    static let nowPlayingSideButtonHeight: CGFloat = 60

    /// 传输行距**安全区底部**：**20**。
    ///
    /// ⚠️ **曾经写 18** —— 那个值是从别处量的，跟这一页的取景不配，别再改回去。
    ///
    /// ⚠️ 差 2 点，但这一页整条链是从底部往上叠的 —— 改它会**连带**把进度块 / 信息行 /
    /// 封面的下边一起挪 2 点（封面 `bottom = 信息行.top`，于是封面高 2 点）。
    static let nowPlayingTransportBottomInset: CGFloat = 20

    /// 传输行最两侧的键离屏幕边缘：**20**。
    static let nowPlayingTransportSideInset: CGFloat = 20

    /// 中间那个播放键与两边切歌键之间的**空隙**：**30**。
    ///
    /// ⚠️ 它量的是两个键**边缘到边缘**，不是中心距（曾经那个常量名叫 `centerToSkipSpacing`，
    /// 容易读成中心距；用的时候是 `prev.trailing = play.leading − 30` —— 是空隙）。
    /// 照边缘空隙表达，改键宽不用重算这个数。
    static let nowPlayingTransportCenterGap: CGFloat = 30

    /// 进度条：轨道高 **4**、圆角 **2**、圆点 **16**。
    ///
    static let nowPlayingSliderTrackHeight: CGFloat = 4
    static let nowPlayingSliderTrackCornerRadius: CGFloat = 2
    static let nowPlayingSliderThumbSize: CGFloat = 16

    /// 进度条的**纵向热区**再往外扩多少：**14**。
    ///
    /// ⚠️ **别扩到 16**：滑杆本身高 16，再加 16 会跟上面的信息行、
    /// 下面的传输行**抢触摸**（那两行之间本来就只隔 20）。14 是"够好按、又不越界"的落点。
    static let nowPlayingSliderHitExpandY: CGFloat = 14

    /// 进度条的**横向热区**再往外扩多少：**8**。
    ///
    /// 相对拖动时手指常从圆点旁起手，左右多吃一点才跟手。
    static let nowPlayingSliderHitExpandX: CGFloat = 8

    /// 播放页**小图标**（顶部那排键 / 信息行两颗 / 传输行几颗）的点大小：**13**。
    ///
    /// 🔴 **定法（前几版全在"拿什么比"上出错，记下来免得再来一遍）**：
    ///
    /// | 版次 | 拿什么比 | 结果 | 错在哪 |
    /// |---|---|---|---|
    /// | 一 | 热区 × 0.4（primuse 的比例式） | 16 / 18 | 比例式是**热区**的近似，不是绘制尺寸 |
    /// | 二 | 参考实现的**绘制框**（`CenteredIconButton.imageSize`） | 15 | **框 ≠ 墨迹**（框里还有符号留白） |
    /// | 三 | **≡** 的墨迹 | 17 | ≡ 两边**色调不同**（对方 60% 白 / 我们 70%）⇒ 被亮度差骗大 |
    /// | 四 | **⋯** 的墨迹（终于同色调了 ✓） | 15 | 只比了**一颗**；而且那张"我们"的截图**是旧版**，等于拿旧尺寸当基准 |
    /// | **五** | **八颗一起比**（同色调 ✓ ＋ 同一次截图 ✓） | **13** | — |
    ///
    /// **五版的实测**（同机 885×1920；我们 15 那版 vs 参考实现当前版）：
    ///
    /// | 元素 | 参考 | 我们(15) | 比 |
    /// |---|---|---|---|
    /// | 关闭 | 29 × 17 | 34 × 19 | 1.17 / 1.12 |
    /// | ≡ 歌词设置 | 34 × 30 | 38 × 33 | 1.12 / 1.10 |
    /// | ⋯ 更多 | 33 × 8 | 36 × 8 | 1.09 |
    /// | 循环 / 上首 / 下首 / 列表 | 36 / 50 / 51 / 34 | 42 / 54 / 54 / 39 | 1.17 / 1.08 / 1.06 / 1.15 |
    ///
    /// ⇒ 平均 **≈ 1.13** ⇒ `15 ÷ 1.13 ≈ 13.3` ⇒ 取 **13**。
    ///
    /// ⚠️ **根子**：我们这条按钮管线（`UIButton.Configuration`）画出来的墨迹**比标称 `pointSize` 大约 13%** ——
    /// 所以**别照别人那 16 / 17 / 18 抄**（抄了就是"全都偏大一档"）。量法见技能 `sf-symbol-icon-sizing`。
    static let nowPlayingIconPointSize: CGFloat = 13

    /// 传输行**上一首 / 下一首**的图标点大小：**14**（比 `nowPlayingIconPointSize` 大一号）。
    ///
    /// 🔴 **为什么要拆开**：循环 / 队列仍用 13；上下一首体感偏小。
    /// 参考那边传输行也不是一档（循环 17、上下一首 18），别再并回小图标令牌。
    static let nowPlayingSkipIconPointSize: CGFloat = 14

    /// 信息行右边那两颗键（**收藏 / 引用**）的图标点大小：**16**（比上面那个 13 大一档）。
    ///
    /// 🔴 **为什么要拆开**：参考实现里这三处本来就**不是同一档** ——
    /// 顶部那排（关闭 16 / 更多 17 / 歌词设置 17）、传输行（循环 17 / 上下一首 18 / 列表 18）、
    /// **信息行（收藏 18 / 引用 17）**。用一个令牌压三处，必然有两处偏。
    ///
    /// **实测（统一用 13 时 vs 参考实现）**：
    ///
    /// | 元素 | 参考 | 我们(13) | 判定 |
    /// |---|---|---|---|
    /// | 顶部那排三颗 | 29 / 34 / 33 | 29 / 33 / 31 | ✅ 13 正好 |
    /// | 传输行（循环/播放/列表） | 36 / 62 / 34 | 36 / 60 / 34 | ✅ 13 正好 |
    /// | **收藏心** | **40 × 36** | **32 × 30** | ❌ 小 20% |
    /// | **引用** | **44 × 42** | **37 × 33** | ❌ 小 17% |
    ///
    /// ⇒ `13 × 40 ÷ 32 ≈ 16.25` ⇒ 取 **16**。
    /// ⚠️ 别再把它并回 `nowPlayingIconPointSize` —— 并回去信息行就又小一圈（这已经是"合并/拆开"的第二次教训）。
    static let nowPlayingInfoActionIconPointSize: CGFloat = 16

    /// 播放键（那颗裸三角）：**30**。
    ///
    /// 🔴 跟上面的小图标一起定的：我们 34 时墨迹 **68 × 76px**、参考实现 **62 × 67px**
    /// ⇒ 比值 1.10 / 1.13 ⇒ `34 ÷ 1.13 ≈ 30`。
    /// ⚠️ 一路是这么纠过来的：`28`（照**字号**取，太小）→ `38`（去对**框** 35×39，又太大）
    /// → `34`（对**墨迹**，但那次基准是旧的、而且只比了一颗）→ **`30`**。
    static let nowPlayingPlayIconPointSize: CGFloat = 30

    // MARK: - 按压缩放（手感）

    /// 按下去用多久：**0.2 秒**。
    ///
    /// 🔴 这两个数是**一套手感**，两个按钮共用（`PressScaleButton` 缩图标、
    /// `PressScaleActionButton` 缩整块）—— 手感是一件事，只能有一个出处；
    /// 各写一份的话，改了一处忘了另一处，两种按钮的手感就不一样了。
    ///
    /// ⚠️ 共用的是**时长**；两边**缩的倍数**是分开的（缩的东西不一样），别一起改。
    static let pressDownDuration: TimeInterval = 0.2

    /// 抬起来用多久：**0.27 秒** —— 比按下（`0.2`）慢三成半，「弹回来」的观感全在这。
    ///
    /// ⚠️ 和按下**不对称是有意的**：按下要跟手（快），抬起要弹（慢）。两者是两件事，分开调。
    ///
    /// 🔴 **`0.27` 是有意压下来的**。
    /// 同类按钮（Apple Music 播放页那排键）量出来是 **`0.47`**，实机上看觉得偏久
    /// ⇒ 压到 `0.27`。**别再把它改回 `0.47`。**
    static let pressUpDuration: TimeInterval = 0.27

    // MARK: - 锁屏封面

    /// 交给系统的封面**按多大解**：**300 点**（@3x 就是 900 像素）。
    ///
    /// 锁屏那块封面按屏幕宽显示（最宽的 iPhone 也就 430 点），**我们故意取小一点**：
    /// 系统拿到封面之后还会在主线程上把它序列化一遍交给 MediaRemote，**图越大这一下越贵** ——
    /// 而锁屏上那张图本来就不大，300 点在看感上已经够了。
    ///
    /// ⚠️ 封面是**缓存**，取小了只是糊一点，不是错误。要调就改这里。
    static let nowPlayingArtworkPointSize = CGSize(width: 300, height: 300)

    /// 换歌时背景从旧色渐变到新色要多久：**0.8** 秒。
    static let nowPlayingBackdropCrossfadeDuration: TimeInterval = 0.8

    // MARK: - 队列页

    /// 半屏占屏高的比例：**0.7**。
    static let queueSheetHeightRatio: CGFloat = 0.7

    /// 半屏顶部圆角：**18** —— 这块我们做圆角，不做成直角。
    static let queueSheetCornerRadius: CGFloat = 18

    /// 表头高：**55**。
    static let queueHeaderHeight: CGFloat = 55

    /// 行高：**50**。
    static let queueRowHeight: CGFloat = 50

    /// 当前行那组声波的边长：**20**。
    static let queuePlayingIndicatorSide: CGFloat = 20

    /// 行尾 × 键的宽：**25**。
    static let queueDeleteButtonWidth: CGFloat = 25

    /// × 的点大小：**11**（semibold）。
    static let queueDeleteIconPointSize: CGFloat = 11

    // MARK: - 歌曲信息编辑页

    /// 表头大封面边长。
    static let trackEditorCoverSide: CGFloat = 170
    static let trackEditorCoverCornerRadius: CGFloat = 12
    static let trackEditorCoverTopInset: CGFloat = 30
    static let trackEditorCoverBottomInset: CGFloat = 10
    static let trackEditorCoverHeaderHeight: CGFloat = 210
    static let trackEditorCoverShadowOpacity: Float = 0.3
    static let trackEditorCoverShadowRadius: CGFloat = 12
    static let trackEditorCoverShadowOffsetY: CGFloat = 3

    static let trackEditorSeparatorLeading: CGFloat = 20
    static let trackEditorEstimatedRowHeight: CGFloat = 45
    static let trackEditorFieldTitleLeading: CGFloat = 5
    static let trackEditorFieldTitleWidth: CGFloat = 100
    static let trackEditorTitleTrailingBuffer: CGFloat = 8
    static let trackEditorContentLeading: CGFloat = 117
    static let trackEditorContentTrailing: CGFloat = 5
    static let trackEditorFieldHeight: CGFloat = 33
    static let trackEditorLyricsVerticalInset: CGFloat = 6

    // MARK: - 均衡器

    /// 自绘顶栏高：保存 / 标题 / 重置三颗键都是 44。
    static let equalizerHeaderHeight: CGFloat = 44

    /// 顶栏左右缩进：10。
    static let equalizerHeaderInset: CGFloat = 10

    /// 标题和左右键之间的最小空隙。
    static let equalizerHeaderGap: CGFloat = 8

    /// 「保存自定义」灰时整键透明度：0.5。字色仍是 black70，只压 alpha，字号尺寸不变。
    static let equalizerHeaderActionDisabledAlpha: CGFloat = 0.5

    /// 标题到预设列表：18。
    static let equalizerPresetTop: CGFloat = 18

    /// 横滑预设条高度：100。
    static let equalizerPresetHeight: CGFloat = 100

    /// 预设卡 96×68、间距 10、sectionInset 16。
    static let equalizerCardSize = CGSize(width: 96, height: 68)
    static let equalizerCardSpacing: CGFloat = 10
    static let equalizerCardInset: CGFloat = 16

    /// 卡内文字边距。
    static let equalizerCardPadding: CGFloat = 10

    /// 卡圆角、选中描边。
    static let equalizerCardCorner: CGFloat = 10
    static let equalizerCardBorderWidth: CGFloat = 1.5

    /// 前级到十条。前级是插在中间之后的一行，所以这里只留它和下排的空隙。
    static let equalizerBandsTop: CGFloat = 24

    /// 十条容器高：300。
    static let equalizerBandsHeight: CGFloat = 300

    /// 十条左右缩进：8。
    static let equalizerBandsInset: CGFloat = 8

    /// 竖滑条行程：204（旋转后是竖直方向）。
    static let equalizerBandSliderTravel: CGFloat = 204

    /// 竖滑条上下数字条高度：收成 **14**。
    static let equalizerBandLabelHeight: CGFloat = 14

    /// 滑块圆点边长：24。
    static let equalizerThumbSide: CGFloat = 24

    /// 预设条到前级。
    static let equalizerPreampTop: CGFloat = 16

    /// 前级行高（热区）。
    static let equalizerPreampHeight: CGFloat = 44

    /// 前级行左右缩进，跟预设卡同一档 16。
    static let equalizerPreampInset: CGFloat = 16

    /// 「前级增益」到滑杆、滑杆到数字。
    static let equalizerPreampGap: CGFloat = 12

    /// 右侧「-12 dB」最小宽，避免数字变长把滑杆挤动。
    static let equalizerPreampValueMinWidth: CGFloat = 48

    // MARK: - 睡眠定时

    /// 档位行高：50。
    static let sleepTimerRowHeight: CGFloat = 50

    /// 开关脚注上下。
    static let sleepTimerFooterTop: CGFloat = 8
    static let sleepTimerFooterBottom: CGFloat = 12

    /// 开关脚注左右。
    static let sleepTimerFooterInset: CGFloat = 20

    // MARK: - 播放页 · 歌词

    /// 歌词容器左右边距：**30**。
    ///
    /// 🔴 这 30 是**版式要求**、不是随手取的：歌词容器左右各内缩 30，跟内容区其余各块对齐。
    static let nowPlayingLyricsHorizontalInset: CGFloat = 30

    /// 歌词容器**下边**离信息行顶留 **8**。
    ///
    /// ⚠️ 封面那边是**紧贴**信息行（`bottom = songInfo.top`，没有这 8）—— 两边差这 8 点
    /// 不是笔误，是有意的（歌词比封面矮一截）。
    static let nowPlayingLyricsBottomGap: CGFloat = 8

    /// 列表上下留白占**容器高**的比例：**0.15 / 0.2**。
    ///
    /// 🔴 这是**比例**、不是固定高度，所以不同屏高上首尾留白会跟着缩放。
    ///
    /// ⚠️ **不是"顶部放一个 108 高的占位行"** —— 那套占位行的做法没人真正用得上，只取这一组比例。
    static let nowPlayingLyricsInsetTopFraction: CGFloat = 0.15
    static let nowPlayingLyricsInsetBottomFraction: CGFloat = 0.2

    /// 当前句停在歌词容器**高的百分之几**处：**0.36**。
    ///
    /// 🔴 **跟上面两个留白是两件事。** 留白管"列表能滚多远"，这个数管"当前句摆多高"。
    static let nowPlayingLyricsFocusFraction: CGFloat = 0.36

    /// 列表里**行与行之间**：**12**。
    ///
    /// 🔴 取 **12**（另一份资料给的是 4.0，太挤）。
    ///
    /// ⚠️ 跟下一项（行内换行 6）是**两个不同概念**，别并成一条。
    static let nowPlayingLyricsLineSpacing: CGFloat = 12

    /// 一行歌词**自己折行**时的行距：**6**。
    static let nowPlayingLyricsInnerLineSpacing: CGFloat = 6

    /// **普通行**的字号缩放：**0.9**（当前行是 1.0 加粗）。
    ///
    /// 🔴 普通行压到 **0.9**，当前行是 1.0 加粗。
    /// ⚠️ **别照 0.75 做** —— 那是给"非当前行再降一档"准备的，可那个开关从来没人打开、
    /// 实际不生效。
    static let nowPlayingLyricsNormalFontScale: CGFloat = 0.9

    /// 歌词字号：**18**。
    ///
    /// 🔴 这是**出厂值**：歌词正文的字号跟着 `LyricsAppearance`（用户可调 16…36）走。
    /// 「暂无歌词」占位**有意不跟设置**—— 那是写死的文案、
    /// 与用户选的大小无关，所以它继续吃这一项。
    static let nowPlayingLyricsFontSize: CGFloat = 18

    /// 行下附属字（文件自带的译文 / 注音）跟正文的间隙：**3**。
    ///
    /// 🔴 出处：**primuse** 行内各条附属字之间的 spacing
    static let nowPlayingLyricsCompanionGap: CGFloat = 3

    /// 附属字的字号缩放：**0.65**（primuse 同，`NowPlayingView.swift:6218`）。
    static let nowPlayingLyricsCompanionScale: CGFloat = 0.65

    /// 用户手滑歌词之后，隔多久**自己接着跟唱**：**2.5 秒**。
    ///
    /// 🔴 取 **2.5**（另两版给的是 5.0 与 primuse 的 3.0）。
    static let nowPlayingLyricsFollowResumeDelay: TimeInterval = 2.5

    /// 跟行高亮的**提前量**（秒）：**0.25**。
    ///
    /// 🔴 出处：**primuse** 行级歌词的 lookahead。
    static let nowPlayingLyricsLookahead: TimeInterval = 0.25

    /// 上下淡出遮罩的分界点：**0 / 0.12 / 0.82 / 1**。
    ///
    /// 🔴 第三档是 **0.82**（另有一版给的是 0.85，差 0.03；我们取 0.82）。
    static let nowPlayingLyricsFadeLocations: [NSNumber] = [0, 0.12, 0.82, 1]

    // MARK: - 播放页 · 歌词设置面板

    /// 面板**内容高**（不含底部安全区）—— 弹层总高 = 它 ＋ 底部安全区
    /// （PanModal `.contentHeight(_:)` 自己加上，见 `PanModalPresentable+LayoutHelpers.topMargin(from:)`）。
    ///
    /// 🔴 它是**版式的和**，不是拍出来的：
    /// 标题条 `lyricsSettingsHeaderHeight` 58
    /// ＋ 首段顶 `lyricsSettingsFirstSectionTop` 24
    /// ＋ 段标题 `lyricsSettingsSectionTitleHeight` 22
    /// ＋ 控件顶 `lyricsSettingsSectionControlTop` 16
    /// ＋ 分段控件 `lyricsSettingsAlignControlHeight` 32
    /// ＋ 分割线顶 `lyricsSettingsDividerTop` 22 ＋ 分割线 `borderWidth` 1
    /// ＋ 次段顶 `lyricsSettingsSecondSectionTop` 22
    /// ＋ 段标题 22
    /// ＋ 滑杆顶 `lyricsSettingsSliderTop` 14
    /// ＋ 滑杆 `lyricsSettingsSliderHeight` 31
    /// ＋ 关闭顶 `lyricsSettingsCloseTop` 16
    /// ＋ 关闭 `lyricsSettingsCloseHeight` 54 ＝ **334**。
    ///
    /// 🔴 **动面板里任何一个段距 / 控件高，当场把这一项也改掉** —— 面板上下两头都钉死了
    /// （顶=标题条、底=安全区上沿），和不对就会当场打约束冲突的日志（后段被压或底下空一截）。
    static let lyricsSettingsContentHeight: CGFloat = 334

    /// 标题条高：**58**。
    static let lyricsSettingsHeaderHeight: CGFloat = 58

    /// 标题左右内缩：**24**。
    static let lyricsSettingsTitleInset: CGFloat = 24

    /// 段内容左右内缩：**28**（段标题 / 分段控件 / 分割线 / 滑杆**都是** 28）。
    static let lyricsSettingsSideInset: CGFloat = 28

    /// 段标题的高 —— **22**（标签撑出来的会随字号变；这里钉死，理由见总高那条）。
    static let lyricsSettingsSectionTitleHeight: CGFloat = 22

    /// 对齐分段控件高：**32**。
    static let lyricsSettingsAlignControlHeight: CGFloat = 32

    /// 字号滑杆的高 —— **31**（`UISlider` 自己的固有高；钉死理由见总高那条）。
    static let lyricsSettingsSliderHeight: CGFloat = 31

    /// 字号滑杆那颗圆点的直径：**20**。
    ///
    /// ⚠️ 跟播放页进度条那颗（`nowPlayingSliderThumbSize` = 16）**不是一档**：
    /// 那一个是"细长进度条"上的小点，这个是面板里独立一根滑杆的把手。
    static let lyricsSettingsSliderThumbDiameter: CGFloat = 20

    /// 底部「关闭」的高 —— **54**（那颗键的 `contentEdgeInsets` 上下各 18、p4 字，算出来 ≈54）。
    static let lyricsSettingsCloseHeight: CGFloat = 54

    /// 各段的竖直间距 —— 这五个数**一一对应、别并成一个“统一间距”**。
    static let lyricsSettingsFirstSectionTop: CGFloat = 24
    static let lyricsSettingsSectionControlTop: CGFloat = 16
    static let lyricsSettingsDividerTop: CGFloat = 22
    static let lyricsSettingsSecondSectionTop: CGFloat = 22
    static let lyricsSettingsSliderTop: CGFloat = 14
    static let lyricsSettingsCloseTop: CGFloat = 16

    /// 面板顶部圆角 —— **18**，跟队列半屏**同一档**（`queueSheetCornerRadius`）：
    /// 两片都是盖在播放页上的底弹层，圆角一样才不会一弹一个样。
    static let lyricsSettingsSheetCornerRadius: CGFloat = queueSheetCornerRadius

    // MARK: - 编辑歌词页

    /// 📍 本节是编辑歌词页的版式规格，每个数值就地标在下面。
    ///
    /// ⚠️ **「定高」不套**（表格 520 / 打轴 360 / 原文 520）——
    /// 我们主区用约束吃满剩余视口；**不**把 360 硬套在这一层。

    /// 歌曲条高：**68** · 圆角 **10**。
    static let lyricsEditorSongStripHeight: CGFloat = 68
    static let lyricsEditorSongStripCornerRadius: CGFloat = 10

    /// 歌曲条左右内缩：**12**（封面 leading 12、播放键 trailing −12）。
    static let lyricsEditorSongStripInset: CGFloat = 12

    /// 歌曲条封面边长：**44** ＋ 圆角 **8**。
    static let lyricsEditorCoverSide: CGFloat = 44
    static let lyricsEditorCoverCornerRadius: CGFloat = 8

    /// 封面与歌名之间：**10**。
    static let lyricsEditorCoverTitleGap: CGFloat = 10

    /// 歌曲条上那颗播放/暂停键：**34**。
    static let lyricsEditorPlayButtonSide: CGFloat = 34

    /// 歌曲条里那个「当前时间」标签的宽：**52**（`textAlignment = .right`）。
    static let lyricsEditorSongStripTimeWidth: CGFloat = 52

    /// 时间标签跟两边（歌名 / 播放键）之间各留 **8**。
    static let lyricsEditorSongStripTimeGap: CGFloat = 8

    /// 歌名顶到底 **12**、副标题与歌名之间 **2**、副标题底 **12**。
    static let lyricsEditorSongTitleTop: CGFloat = 12
    static let lyricsEditorSongArtistGap: CGFloat = 2
    static let lyricsEditorSongArtistBottom: CGFloat = 12

    /// 整页那条竖排内容栈：块间距 **12**；左右各 **16**。
    static let lyricsEditorBlockSpacing: CGFloat = 12
    static let lyricsEditorContentSideInset: CGFloat = 16
    static let lyricsEditorContentVerticalInset: CGFloat = 12

    /// 逐行表格：估算行高 **70** · 圆角 **10** · 边框 **1**。
    ///
    /// 行间分隔线左缩 **82**（工作台 `Divider().padding(.leading: 82)`；
    /// 左缩 116 是时间列更宽时的数 —— 时间列变窄后跟工作台取 82）。
    static let lyricsEditorEstimatedRowHeight: CGFloat = 70
    static let lyricsEditorTableCornerRadius: CGFloat = 10
    static let lyricsEditorTableBorderWidth: CGFloat = 1
    static let lyricsEditorRowSeparatorLeading: CGFloat = 82

    /// 一行的**内边距**（对齐工作台 `padding(.horizontal, 10) .padding(.vertical, 6)`）：
    /// 内容左右各 **10** · 上下各 **6** —— 画在行自己的圆角底板之内。
    static let lyricsEditorRowInsetHorizontal: CGFloat = 10
    static let lyricsEditorRowInsetVertical: CGFloat = 6

    /// 行底板的圆角：**6**（工作台 `RoundedRectangle(cornerRadius: 6)`）。
    static let lyricsEditorRowCornerRadius: CGFloat = 6

    /// 行里那颗时间键：高 **20** · 圆角 **4** · 内左右各 **6** · 最宽不小于 **44** · 距行顶 **10**。
    ///
    /// ⚠️ 工作台是"11pt 时刻字 ＋ 左右 6 上下 3"的一颗小圆角徽章（在 28 的框里居中）；
    /// 我们没有那层外框，直接给键高 20、顶 10 —— 视觉中心（20）正落在正文第一行的行心上。
    /// 未打轴那支只画「打点」两个字（10 中等，`AppFont.lyricsEditorRowStamp`）—— **没有图标**。
    static let lyricsEditorRowTimeButtonHeight: CGFloat = 20
    static let lyricsEditorRowTimeButtonCornerRadius: CGFloat = 4
    static let lyricsEditorRowTimeButtonPadding: CGFloat = 6
    static let lyricsEditorRowTimeButtonMinWidth: CGFloat = 44
    static let lyricsEditorRowTimeButtonTop: CGFloat = 10

    /// 行里的正文：距时间键 **10**（工作台 `HStack` 间距）· 正文框内上下各留 **6**。
    ///
    /// ⚠️ 视觉上"正文 ↔ 逐字条"的空 = 这 **6** ＋ 条上方那道 `lyricsEditorSyllableStripTop`（6）＝ **12**。
    static let lyricsEditorRowTextGap: CGFloat = 10
    static let lyricsEditorRowTextVerticalInset: CGFloat = 6

    /// 打轴竖栈：块间距 **14** · 内缩 **8**。
    static let lyricsEditorTimingBlockSpacing: CGFloat = 14
    static let lyricsEditorTimingInset: CGFloat = 8

    /// 打轴**卡片**高 **360**。
    ///
    /// 这不是页主区高度。七块关在这块 360 里，
    /// 装不满的余量喂给「上一句」，才有上一句到行号那截空。卡片比主区矮时，多的空白留在卡片下。
    static let lyricsEditorTimingCardHeight: CGFloat = 360

    /// 「逐字打轴」那一页的卡片高：**430**。
    ///
    /// ⚠️ 比逐行那一页（360）高出来的**就是多的那两条**（逐字块条 ＋ 当前字细条）——
    /// 不加高的话，弹性槽（上一句）会被压到底、卡片里就要打架。
    static let lyricsEditorTimingSyllableCardHeight: CGFloat = 430

    /// 打轴面板那条主键「打时间点并下一行」的高：**48**；圆角 **10**。
    static let lyricsEditorPrimaryButtonHeight: CGFloat = 48
    static let lyricsEditorPrimaryButtonCornerRadius: CGFloat = 10

    /// 底部工具条：两条行间距 **8** · 行内键间距 **8** ·
    /// 条子上下 **10** / 左右 **12** · 每颗键高 **38**、圆角 **8**。
    static let lyricsEditorToolbarRowSpacing: CGFloat = 8
    static let lyricsEditorToolbarButtonSpacing: CGFloat = 8
    static let lyricsEditorToolbarVerticalInset: CGFloat = 10
    static let lyricsEditorToolbarSideInset: CGFloat = 12
    static let lyricsEditorToolbarButtonHeight: CGFloat = 38
    static let lyricsEditorToolbarButtonCornerRadius: CGFloat = 8

    /// 原文那个文本框：圆角 **10** · 等宽字 14 · 内缩 上下 10 / 左右 12。
    static let lyricsEditorSourceCornerRadius: CGFloat = 10
    static let lyricsEditorSourceVerticalInset: CGFloat = 10
    static let lyricsEditorSourceSideInset: CGFloat = 12

    /// 「±」微调的步长：**0.5 秒**。
    ///
    /// 🔴 **取 0.5，不取 primuse 的 0.1** —— 0.1 是那边更细的增量。
    static let lyricsEditorNudgeStep: TimeInterval = 0.5

    // MARK: - 编辑歌词页 · 逐字

    /// 逐字块的微调步长：**0.1 秒**（字级）。
    ///
    /// ⚠️ 跟行级的 `lyricsEditorNudgeStep`（**0.5**）**不是同一个数、也不许并成一个**：
    /// 行与行之间动辄差好几秒，字与字之间常常只差 0.2~0.5 秒 —— 拿 0.5 去挪字，
    /// 一下就按到相邻字头上。
    static let lyricsEditorSyllableNudgeStep: TimeInterval = 0.1

    /// 逐字条：块高 **34** · 块内左右各 **7** · 块间距 **6** · 圆角 **6** · 选中描边 **1** ·
    /// 条与上方正文之间 **6** · 一块最窄 **44**、最宽 **166**（工作台 `minWidth: 44` / `maxWidth: 166`）。
    ///
    /// ⚠️ 那个 **6** 是**加在正文框自己的下内缩（`lyricsEditorRowTextVerticalInset` ＝ 6）之上**的 ⇒
    /// 正文末行到第一排字块实际空 **12**。取 4 时只有 10，正文和字块糊成一片。
    ///
    /// 🔴 **只在"这一行确实有逐字"时才留** —— 没有逐字的行整条收起来，间距一并归零
    /// （`LyricsEditorLineCell.applySyllables` 里那处 `update(offset:)`）。
    /// 常数挂着不放的话，全表每一行都会平白长高 6。
    static let lyricsEditorSyllableChipHeight: CGFloat = 34
    static let lyricsEditorSyllableChipPadding: CGFloat = 7
    static let lyricsEditorSyllableChipMinWidth: CGFloat = 44
    static let lyricsEditorSyllableChipMaxWidth: CGFloat = 166
    static let lyricsEditorSyllableChipSpacing: CGFloat = 6
    static let lyricsEditorSyllableChipCornerRadius: CGFloat = 6
    static let lyricsEditorSyllableChipBorderWidth: CGFloat = 1
    static let lyricsEditorSyllableStripTop: CGFloat = 6

    /// 当前字细条：高 **26** · 与上方字块之间 **8**（工作台 `WordStripView` 竖栈间距）。
    ///
    /// 🔴 **细条自己不画底、不留左右内缩** —— 它跟字块同在正文那一列里，最左那颗图标与第一块字
    /// 左沿对齐；底只在两颗小键上。曾经整条铺一块实底 ＋ 左右各缩 8，在「当前句」的淡染上
    /// 就是一条灰杠。
    static let lyricsEditorSyllableDetailHeight: CGFloat = 26
    static let lyricsEditorSyllableDetailTop: CGFloat = 8

    /// 细条里三段的间距：**图标 · `k/n` · 时间** 两两之间各 **8**。
    static let lyricsEditorSyllableDetailItemSpacing: CGFloat = 8

    /// 细条右沿内缩：**24**。
    ///
    /// 工作台同一行右边还有删除 / 拖拽，正文列更窄，`±` 自然靠左；我们不画那两颗，
    /// 正文列拉满后键会偏右 —— 收一颗键宽，别贴表格右沿，也别收过头。
    static let lyricsEditorSyllableDetailTrailingInset: CGFloat = 24

    /// 细条最左那颗波形图标：字号 **10 半粗** · 占位方框 **14**。
    ///
    /// ⚠️ 量过（离线 `NSImage` 同一套符号字体）：`waveform` 10 半粗出来的图是 12×13，
    /// **默认不给字号时是 16×16** —— 以前那颗就是拿默认尺寸塞进 14 的框，比细条里的字还高。
    static let lyricsEditorSyllableDetailIconPointSize: CGFloat = 10
    static let lyricsEditorSyllableDetailIconSide: CGFloat = 14

    /// 细条里那对 `±` 小键：**30 × 24** · 圆角 **6** · 两键之间 **8** ·
    /// 键面画 **SF Symbol `minus` / `plus`（10 半粗）**，步长的数字只在无障碍标签里。
    static let lyricsEditorSyllableDetailButtonWidth: CGFloat = 30
    static let lyricsEditorSyllableDetailButtonHeight: CGFloat = 24
    static let lyricsEditorSyllableDetailButtonCornerRadius: CGFloat = 6
    static let lyricsEditorSyllableDetailButtonSpacing: CGFloat = 8
    static let lyricsEditorSyllableDetailButtonIconPointSize: CGFloat = 10

    // MARK: - 获取歌词（编辑歌词页取材）

    /// 📍 本节只服务「获取歌词」页（`Features/NowPlaying/LyricsEditor/LyricsFetch*`），
    /// 口径见 `docs/设计/获取歌词设计.md`。
    ///
    /// ⚠️ **它不复用编辑歌词页那几个数**：两页的量法不一样 —— 那边是"钉死版式"（歌曲条 68、
    /// 键高 48/38），这边是**普通列表**（行高交给系统按内容算）。共用一个数会让
    /// "改这一页的版式"牵动另一页。

    /// 候选列表：估算行高 **72**。
    ///
    /// 两行 —— 歌名（15）＋「艺人 · 专辑」（11，可能折成两行）＋ 上下内边距。
    /// ⚠️ 只是**估算**（给滚动条用的），真高仍由系统按内容算（`automaticDimension`）。
    static let lyricsFetchEstimatedRowHeight: CGFloat = 72

    /// 页面正中那块（转圈 ＋ 一句话）的竖直间距 **12**、左右各留 **32**。
    ///
    /// 左右那 32 是为了让长句（「网络不可用，稍后再试」）能换行，又不至于贴到屏幕边。
    static let lyricsFetchStateSpacing: CGFloat = 12
    static let lyricsFetchStateSideInset: CGFloat = 32

    // MARK: - 歌单封面流

    /// 边长上限：宽的 **0.47**、高的 **0.66**，再与最小边 **220** 取大。
    static let coverFlowMaxWidthFraction: CGFloat = 0.47
    static let coverFlowMaxHeightFraction: CGFloat = 0.66
    static let coverFlowMinSide: CGFloat = 220
    static let coverFlowVerticalInsetHeightFactor: CGFloat = 1.52
    static let coverFlowActiveDistanceFraction: CGFloat = 0.35
    /// `m34`。写成 `-1/650`，不要再抄一串小数。
    static let coverFlowPerspective: CGFloat = -1 / 650
    static let coverFlowTranslateXFraction: CGFloat = 0.3
    static let coverFlowDepth: CGFloat = 160
    static let coverFlowZIndexScale: CGFloat = 1000
    /// 绕 Y 转角（弧度），约 73.47°。原样进令牌，不改成 73.5°。
    static let coverFlowRotationAngle: CGFloat = 1.2822827157509358
    static let coverFlowSpacingOverlapRatio: CGFloat = 0.76

    static let coverFlowCoverCornerRadius: CGFloat = 8
    static let coverFlowCoverBorderWidth: CGFloat = 0.5
    static let coverFlowReflectionHeightFraction: CGFloat = 0.5
    static let coverFlowReflectionGap: CGFloat = 2
    static let coverFlowReflectionMaskTopOpacity: CGFloat = 0.55
    static let coverFlowReflectionMaskEndY: CGFloat = 0.65
    static let coverFlowReflectionAlphaBase: CGFloat = 0.34
    static let coverFlowReflectionAlphaSlope: CGFloat = 0.18
    static let coverFlowReflectionAlphaMin: CGFloat = 0.1
    static let coverFlowInfoAlphaFullThreshold: CGFloat = 0.08
    static let coverFlowInfoAlphaFadeThreshold: CGFloat = 0.18
    static let coverFlowInfoPaddingX: CGFloat = 24
    static let coverFlowInfoHeight: CGFloat = 58
    static let coverFlowInfoTitleHeight: CGFloat = 34
    /// 歌名 / 艺人各带一层黑阴影（色走 `AppColor.shadow`，强度在这一族）。
    static let coverFlowTitleShadowOpacity: Float = 0.45
    static let coverFlowTitleShadowRadius: CGFloat = 12
    static let coverFlowTitleShadowOffsetY: CGFloat = 3
    static let coverFlowSubtitleShadowOpacity: Float = 0.35
    static let coverFlowSubtitleShadowRadius: CGFloat = 10
    static let coverFlowSubtitleShadowOffsetY: CGFloat = 2
    static let coverFlowChromeInset: CGFloat = 20
    static let coverFlowChromeButtonSide: CGFloat = 32
    static let coverFlowChromeIconSize: CGFloat = 15
}
