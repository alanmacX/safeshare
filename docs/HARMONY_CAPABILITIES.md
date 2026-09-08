# HarmonyOS Capability Audit

审计环境：项目兼容/目标版本为 HarmonyOS 6.1.1(24)，使用 DevEco Studio 内置 API 24 SDK 编译。

## 已使用并编译验证

| 能力 | 当前 API | 用法 |
|---|---|---|
| 分享接收 | `@kit.ShareKit` `systemShare.getSharedData` | 从 `ohos.want.action.sendData` 的 Want 解析 SharedRecord URI |
| 分享发出 | `systemShare.SharedData` + `ShareController.show` | 分享缓存中的清理副本，并监听 completed/dismiss |
| 图片读取 | `@kit.ImageKit` `image.createImageSource` | 从已授权 URI 读取图片 |
| 元数据 | `ImageSource.getImageProperty(PropertyKey)` | 只读取隐私相关 EXIF 字段 |
| 安全副本 | `createPixelMap` + `ImagePacker.packToFile` | 新文件不复制源元数据块 |
| 输出 URI | `@kit.CoreFileKit` `fileUri.getUriFromPath` | 将沙箱路径交给 Share Kit |
| 权限免打扰选图 | `@kit.MediaLibraryKit` `PhotoViewPicker` | 不申请全量相册权限 |
| 原生主题 | ArkUI 语义颜色资源 + `dark` 限定资源 | 跟随系统浅色/深色模式 |
| 人脸 | Core Vision `faceDetector` | 真实人脸矩形，默认由用户决定是否遮盖 |
| 二维码/条码 | Scan Kit `detectBarcode.decode` | 隐藏码内容，只保留风险与矩形 |
| 视觉遮盖 | Image Kit `PixelMap` 像素读写 | 强模糊、马赛克、纯色遮盖与智能推荐 |
| 多图 | Share Kit 多 SharedRecord + PhotoViewPicker | 最多 50 张，逐张检查、预览和分享 |

旧的 `wantConstant.ACTION_SEND_DATA` 与 `PARAMS_STREAM` 在本机 SDK 中标记为 deprecated。接收端因此采用当前官方 Share Kit 的 `getSharedData`，仅在 `module.json5` 中保留系统规定的 action 字符串用于能力声明。

## 已接入、待真机发布门禁

- Core Vision Kit `faceDetector`：返回人脸矩形区域。
- Scan Kit `detectBarcode.decode`：对规范方向的检测图片识别二维码/条码并返回角点。

这些能力可能依赖设备支持或本地模型资源。应用会逐项捕获失败并告诉用户哪些检查未完成，元数据清理仍可继续。未通过至少两台真机验证前，不把它们写成商店已交付卖点。

模拟器不能代替人脸与二维码的识别率、坐标或输出打码验收。代码会先用 `canIUse` 判断人脸能力；能力不可用或调用失败时明确提示，仍允许只处理元数据。

## 性能策略

视觉检测使用一张最长边 1600、保持比例的 `RGBA_8888` PixelMap，人脸模型在批次内复用初始化。二维码从同一检测图生成规范方向输入，所有框以独立 X/Y 比例还原到原始像素。输出阶段保持全分辨率，但只按遮盖矩形分区读写。当前不运行 OCR、敏感文字分类或泛化对象检测，也不把多个系统模型盲目并行。

## HarmonyOS 6.1

已落地 UIDesignKit（`@kit.UIDesignKit`，since 5.1.0(18)~6.1.0(23)）沉浸光感：`HdsNavigation` / `HdsNavDestination` 标题栏（`IMMERSIVE_GRADIENT_BLUR` 滚动联动 + `hdsMaterial.MaterialType.IMMERSIVE`）、`HdsActionBar` 底部操作栏、首页原生 `bindMenu`。已在 6.1.1 模拟器验证页面与交互；效果、功耗和低算力降级表现仍需真机矩阵验证。ArkUI 通用 `uiMaterial`（`ImmersiveMaterial`）自 API 26 起提供，本机 API 24 SDK 无此接口，未使用。
