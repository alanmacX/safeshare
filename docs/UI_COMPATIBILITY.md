# UI compatibility and material strategy

## Current baseline: HarmonyOS 6.1.1 / API 24

- 页面容器使用 UI Design Kit 的 `HdsNavigation` / `HdsNavDestination`（`@kit.UIDesignKit`），路由仍基于 `NavPathStack` + `navDestination`。
- 首页顶部栏为 HdsNavigation 原生 `titleBar`（主标题「净享」/ 副标题 SafeShare + 右侧设置菜单），不再手搓 Row 标题栏。
- 处理方式选择使用原生 `bindMenu`（`MenuElement[]` + `symbolIcon`），菜单玻璃材质、动效与无障碍行为由系统提供。
- 底部主操作使用 `HdsActionBar`（`primaryButton` + `BlurStrategy.ADAPTIVE`），分享/生成副本按钮固定底部并自带模糊背景。
- HdsNavigation / HdsNavDestination 标题栏开启 `scrollEffectOpts`（`IMMERSIVE_GRADIENT_BLUR`）与 `systemMaterialEffect`（`MaterialType.IMMERSIVE` + `MaterialLevel.ADAPTIVE`，均 since 6.1.0(23)）。
- 沉浸式窗口：`EntryAbility.onWindowStageCreate` 调用 `setWindowLayoutFullScreen(true)` 并将状态栏/导航栏底色设为透明；避让交给 HdsNavigation 安全区策略，不在页面手搓 padding。
- `bindSheet` 继续使用原生 `blurStyle: BlurStyle.COMPONENT_ULTRA_THICK`；遮罩色走语义资源 `app.color.sheet_mask`。
- 首次教程使用居中悬浮的圆角模糊面板，避免窄屏 `bindSheet` 强制贴底；翻页使用原生 `Swiper`、可交互 `DotIndicator` 与直接绑定的胶囊按钮，只有末页的“开始使用”才关闭教程。
- 照片教程在同一页同步呈现样例图上的视觉区域与位置、拍摄时间、设备信息等元数据结果；文件教程读取内置 `project_handover.docx` 的真实业务正文与 OOXML 属性作为演示内容，只通过顺序属性动画解释状态变化，不使用随机粒子或装饰性循环动画。
- 教程中的人脸、二维码框是内置样例上的能力演示，文案明确标注“设备能力可用并检出时”；它不替代真实设备上的 Core Vision / Scan Kit 验证。
- 两个及以上文件生成安全副本且持续超过 1.5 秒时，使用 API 24 `LiveViewKit` 的 `PROGRESS` 实况窗展示匿名计数进度；更新至少间隔 1 秒，成功与失败都显式结束，功能关闭、权益未开通或设备不支持时无损降级到应用内进度。
- 所有界面颜色使用语义资源，`base` 与 `dark` 资源跟随系统浅色/深色模式切换；`configColorModeChangePerformanceInArkUI` 已开启。
- 功能性预览层（打码/水印预览的 `backdropBlur`、检测框覆盖层）是产品能力本身，不属于装饰性材质，保留。
- ArkUI 通用 `uiMaterial`（`ImmersiveMaterial` / 通用 `systemMaterial` 属性）自 API 26 起提供，本机 API 24 SDK 不存在，未使用。

## Material gate

1. 沉浸光感只覆盖标题栏、底部操作栏、Menu、Sheet 等高频交互区域；不对整页背景、大图预览、长列表卡片叠加材质。
2. 不与额外模糊和重复阴影叠加；`applyShadow` 类自定义阴影不与系统材质混用。
3. 浅色、深色、高/中/低算力设备分别截图并测量帧率、功耗与文字对比度。
4. 设备材质策略可通过 `hdsMaterial.getSystemMaterialTypes()` 查询；能力不可用时系统自动降级为普通背景。

## Verified on emulator (6.1.1)

- 首页：HdsTitleBar + 设置菜单入口 + 中央原生按钮 `bindMenu` 弹出「隐私处理 / 用途水印」。
- feature / scan 页：HdsNavDestination 标题栏、返回键、`onBackPressed` 重置逻辑正常。
- 设置 Sheet：原生 SheetPage + ListItemGroup CARD 正常。
- 深色模式切换后布局与控件状态正常。

## Future UI Design Kit adoption

- 扫描结果的可选择处理项可迁移到 `HdsListItemCard`，获得统一的选中、菜单与无障碍行为。
- 平板/折叠屏使用 `HdsNavigation` 双栏（`mode(NavigationMode.Split)`），而不是简单放大手机页面。
