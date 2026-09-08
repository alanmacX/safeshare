# Architecture

## Vertical slice

```text
Gallery / Files / Browser
  → ohos.want.action.sendData
  → systemShare.getSharedData
  → ImagePrivacyProcessor
      → MetadataScanner
      → one normalized RGBA detection PixelMap (max edge 1600)
          → QR → Face (sequential, shared coordinates)
  → findings shown directly (no synthetic privacy score)
  → MetadataSanitizer (decode pixels → selected redaction → format-aware encoding)
  → MetadataScanner verification
  → systemShare.ShareController
  → TempFileManager cleanup
```

## File-type routing（按类型分发的专属工具）

每种文件类型有独立工具链，不混用语义。`FileTypeRouter`（extension → UTD 兜底）判定
`FileKind`，`SafeShareService` 只做路由：

| FileKind | 扫描工具 | 清理方式 | 输出验证 |
|---|---|---|---|
| IMAGE | MetadataScanner + QR/Face 端侧视觉 | 像素重编码 + 局部遮盖 | MetadataScanner 复检 + 视觉复检 |
| MOVING_PHOTO（UI 归类为 IMAGE） | `PhotoAsset.PHOTO_SUBTYPE` 识别后拆分封面与视频，分别使用图片与 ISO-BMFF 扫描器 | 封面原格式 metadata 路径；视频仅定长清除隐私 `moov` 值，保留全部轨道、样本和动态照片锚点；`loadMovingPhoto` 重组 | 封面和视频分别零 finding 后才产生组合 URI；两个沙箱组件按同一生命周期清理 |
| PDF | PDF Kit `PdfDocument.getMetadata()`（title/author/subject/keywords/creator/producer/创建/修改时间） | PDF Kit `loadDocument → saveDocument` 重写副本 | 重扫副本须零 finding，否则删除输出 |
| WORD/EXCEL/POWERPOINT | `OoxmlFamilyTool`：解析 ZIP → 解压 `docProps/core.xml`、`app.xml`、`custom.xml`，解析 dc:creator / cp:lastModifiedBy / Company / Manager / 自定义属性等 | 自建 `ZipContainer` 重打包：仅重写三个 docProps 条目（STORE 模式、XML 结构保持有效），其余条目原字节拷贝，时间戳固定 | 重扫副本须零 finding，否则删除输出 |
| AUDIO_VIDEO | `AVMetadataExtractor`（location/dateTime/author/artist 等） | **无**。HarmonyOS 无本地去除接口，如实告知，不伪造副本 | — |

入口范围：`PrivacyEntryAbility` skills 声明 `general.image` / `com.adobe.pdf` /
`org.openxmlformats.wordprocessingml.document` / `spreadsheetml.sheet` /
`presentationml.presentation` / `general.video` / `general.audio`。App 内选择：
图片走 PhotoViewPicker，PDF/Office 与音视频走 DocumentViewPicker（各自独立菜单项）。

## Non-destructive guarantee

输入 URI 只传给 `ImageSource` / `PdfDocument` / ZIP 读取 / `AVMetadataExtractor`（fd 只读）。
应用从不以写模式打开输入文件；来自 provider 的 URI 先复制到沙箱再交给需要路径的
PDF Kit。输出只写入应用 `cacheDir` 下带随机后缀的 `safeshare-*` 文件。任何复检失败
都删除输出并阻止分享。

## Why pixel re-encoding

不在源文件上逐项调用 `modifyImageProperty`。从像素创建新文件能从结构上避免复制源 EXIF/XMP 块，并能统一验证结果。编码器支持时优先保持 PNG、HEIF、WebP，其他格式回退为质量 95 的 JPEG；最终支持范围仍以真机格式矩阵为准。

元数据策略分为推荐清理、一键全清除和自定义。自定义允许保留拍摄时间、相机/镜头信息、摄影参数，或替换拍摄时间、厂商、型号、作者、版权和描述；GPS、设备序列号等高风险标识始终不提供伪造保留路径。默认策略写入本地 Preferences，本次结果页的调整不会改写默认值。

## Why a custom ZIP container (OOXML)

系统 zlib 的 `compressFile/decompressFile` 不保留目录结构、无法逐条目替换，且任何
通用 zip 工具都可能写入自己的实现指纹。`ZipContainer` 手工解析 Central Directory /
Local File Header，raw deflate 条目用 `zlib.createZipSync()` 实例的
`inflateInit2(strm, -15)` 解压（API 12+，本机 API 24 已验证），重打包时固定 DOS
时间戳，输出确定、无构建环境指纹。ZIP64 拒绝处理并明确报错（OOXML 文档不会触及）。

## Visual redaction

自动区域只来自官方端侧 API 返回的人脸矩形或二维码角点。用户可逐项保留或遮盖，并在生成后切换原图/安全副本。二维码默认使用纯色遮盖，人脸默认使用马赛克；超大模糊区域自动降级为马赛克。

## ML and memory pipeline

- 元数据直接从源 `ImageSource` 读取；视觉检测只建立一张保持宽高比、最长边 1600 的 `RGBA_8888` PixelMap。
- 人脸模型消费同一张降采样 PixelMap，模型在一批照片内复用初始化，离开任务时统一释放。
- Scan Kit 使用由同一 PixelMap 编码的规范方向临时 JPEG；二维码和人脸结果分别用 `scaleX`、`scaleY` 映射回全尺寸像素。
- 输出仍以完整像素编码保证画质和元数据清除，但遮盖时只读取、修改并写回每个局部区域，不创建整图副本。
- 输出复检只重新运行本次实际遮盖过的类别，并只判断原遮盖区域是否仍有重叠结果，避免再次执行无关模型。
- 不运行 OCR 文字分类或泛化对象检测，避免高负载和缺乏语义依据的误报。

## Next gates

1. 真机验证来自图库、文件管理与浏览器的 URI 生命周期。
2. Core Vision Face Detector 真机模型下载、性能和坐标验证。
3. Scan Kit 二维码/条码坐标在旋转图片上的真机验证。
4. JPEG、透明 PNG、HEIF/HEIC、WebP 与 HDR 的输入输出矩阵。
5. 大批量性能、系统内存压力与分享目标兼容回归。
6. 真机验证：真实 docx/xlsx/pptx 的 docProps 清理结果在 Office 中可正常打开；PDF Kit 重写副本在系统 PDF 预览中可打开；加密 PDF 明确提示不支持。
7. 真机验证音视频 AVMetadataExtractor 的 location 解析矩阵（mp4/mov/mkv/mp3/flac）。
