# SafeShare API 24 格式支持与发布门禁

本表是实现、测试和用户文案的共同依据。“系统能够选择/分享/解码”不等于
SafeShare 已完整支持。只有同时通过识别、扫描、生成副本、复检、原生应用回读
五项门禁的格式，才能显示为“完整支持”。

## 完整支持的定义

- 文件内容按签名和容器结构识别，不信任扩展名或分享方 UTD。
- 能检查该格式在 API 24 可访问的隐私元数据；未检查的元数据类别必须明确披露。
- 只清元数据时不解码/重编码媒体内容，保留原格式、原码流及非目标功能。
- 用户要求删除或替换的字段必须在输出副本复检通过；要求保留的字段也必须复检。
- 输出扩展名、MIME、UTD 与真实容器一致，并能由系统相册/文件应用和对应办公应用重新打开。
- 不修改原文件；输出位于应用沙箱并进入既有清理流程。

## 系统相册媒体

| 类型 | 目标状态 | 元数据副本策略 | 当前结论 |
|---|---|---|---|
| JPEG/JPG（含 HDR/辅助图） | 完整支持 metadata | 定点处理 EXIF、注释、IPTC 和隐私 XMP；HDR/ICC/MPF/JUMBF/压缩码流列入逐字节保护 | 已实现无重编码路径、容器复检和受保护负载对比；待 HDR 真机验收 |
| PNG | 完整支持 metadata | 移除文本块，原位处理 EXIF；IDAT、透明度、色彩块不重编码 | 已实现容器复检；待真机回读 |
| HEIF/HEIC（SDR） | 完整支持元数据删除/替换 | 容器级清 `Exif`/`mime(XMP)` item 载荷；ImageKit 写回替换值；主图/HDR 不重编码 | 已实现容器 scrub + 属性替换；待真机回读 |
| HEIF/HEIC（HDR/辅助图） | 完整支持 | 必须保留 HDR、gain map、辅助图、色彩信息 | 仅元数据路径保持原容器；视觉编辑会扁平化，尚未开放为完整支持 |
| 动态照片 | **不支持** | 不接收、不处理；识别后明确拒绝 | AppGallery 拒绝 `READ_IMAGEVIDEO`，且无公开 API 可无权限写回动态照片元数据 |
| 相册普通视频（MP4/MOV） | 完整支持元数据 | demux/remux，复制编码轨道；保留方向、时序与音轨 | 已有基础实现，待补容器/轨道门禁和真机矩阵 |
| WebP（静态/动画） | 完整支持 metadata | 容器级移除 EXIF/XMP，保留 VP8/VP8L/ANIM/ANMF/ICC | 已实现并复解析；动画视觉操作不开放，待真机回读 |
| 相册中的 GIF | 完整支持 metadata | 容器级移除 Comment 和非动画 Application 扩展；帧、时序、调色板、循环块逐字节保留 | 已实现并复解析；人脸/二维码/水印不开放，待真机相册回读 |
| TIFF/DNG | 完整支持深度 metadata 清理 | 原位清零隐私 IFD、GPS IFD、XMP/IPTC 数据；图像 strip/tile 不移动 | 已实现 Classic TIFF/DNG；BigTIFF 不支持，待真机/专业软件回读 |
| HEIFS 序列 | metadata 路径 | 原容器复制并调用 HEIF 属性接口，保留全部帧和辅助信息 | 代码允许无重编码 metadata；视觉操作阻止，待真机确认系统接口覆盖范围 |

“系统相册完全可用”以实际资产子类型和内容能力为准：静态图、HDR 图、动态照片、
普通视频必须分别识别。任何无法保持媒体形态的资产都必须在处理前阻止，不能自动
转成 JPEG 或静态图。

华为并未发布一张“手机图库可保存的全部扩展名”静态清单。API 24 可依赖的官方边界是：

- Media Library 把图库资产分为图片/视频，并把图片子类型分为 `DEFAULT`、
  `MOVING_PHOTO`、`BURST`；API 21 起还会报告 SDR/HDR 动态范围。
- 预置 UTD 明确包含 JPEG、PNG、TIFF、GIF、HEIF、HEIC、WebP 和 Moving Photo，
  但“有 UTD”不等于每台设备的图库都能完整解码或编辑。
- API 24 ImageSource 声明可读 JPEG、PNG、GIF、BMP、WebP、DNG、HEIC、WBMP、
  HEIFS、TIFF、SVG、ICO；部分格式依赖硬件，仍须在真机调用
  `getImageSourceSupportedFormats` 做运行时门禁。
- 因而接收策略不能只看后缀：以 PhotoAsset 的 MIME/子类型/动态范围，加文件签名和
  运行时解码能力共同判定。DNG、TIFF、HEIFS 等“能解码但不能保证隐私元数据完整
  清理”的类型继续只读或拒绝输出。

## 文件应用中的常用图片

| 类型 | 产品分级 |
|---|---|
| JPEG、PNG、SDR HEIF/HEIC、WebP | 目标为完整支持，逐格式通过门禁后开放 |
| DNG、TIFF | Classic TIFF/DNG 支持容器级深度清理；BigTIFF 阻止 |
| GIF、WebP 动画 | metadata 清理保留序列；逐帧视觉功能阻止 |
| HEIFS | 无重编码属性路径；待真机覆盖验证 |
| BMP | metadata 模式保持原文件精确副本并提示未发现受管元数据；不静默转 JPEG |
| SVG、ICO、WBMP | 暂不接收/处理 |
| AVIF/AVIS | API 26 能力，API 24 明确不支持 |

API 24 没有 API 26 的通用 XMP 读写能力。即便 EXIF 属性复检通过，也不能使用
“所有元数据已清除”描述包含未知 XMP/IPTC/厂商私有块的输入。

## 子功能支持矩阵

“✓”表示代码路径已实现且有输出复检；“△”表示能力有限或仍需真机/对应应用验收；
“—”表示产品应隐藏或阻止该操作，而不是把文件转换成别的格式。

| 类型 | 元数据检查/清理 | 文字水印 | 图片水印 | 人脸/二维码 | 媒体形态保持 |
|---|---|---|---|---|---|
| JPEG/JPG | ✓（EXIF+COM+IPTC+隐私 XMP） | ✓ 重编码 | ✓ 重编码 | △ 端侧能力，需真机 | metadata 时保护 HDR/ICC/辅助负载；视觉编辑非无损 |
| PNG | ✓（EXIF+文本块） | ✓ 重编码 | ✓ 重编码 | △ 端侧能力，需真机 | metadata 时 IDAT/透明度/色彩块不动 |
| HEIF/HEIC SDR | ✓（API 可见属性） | △ 重编码 | △ 重编码 | △ 端侧能力，需真机 | 视觉编辑可能改变编码参数 |
| HEIF/HEIC HDR/辅助图 | ✓ 原容器 | — | — | — | 仅元数据操作保持 HDR/辅助图 |
| WebP 静态图 | ✓ 容器级深度清理 | △ 重编码 | △ 重编码 | △ 端侧能力，需真机 | metadata 时编码图像及 ICC 不动 |
| WebP 动画 | ✓ 容器级深度清理 | — | — | — | 保留动画块 |
| GIF 动画 | ✓ 容器级 | — | — | — | ✓ 不解码、不重编码、保留动画 |
| TIFF/DNG | ✓ 容器级深度清理 | — | — | — | Classic TIFF；图像 strip/tile 不动 |
| HEIFS/HEIF 多帧图 | △ 系统属性接口 | — | — | — | 原容器复制；待真机验证 |
| 动态照片 | — | — | — | — | 不接收；识别后拒绝 |
| MP4/M4A | △ 容器检查及码流复制 | — | — | — | 已有 demux/remux，待真机矩阵 |
| PDF | △ 属性/深度清理需区分 | △ 页面重建，非无损 | △ 页面重建，非无损 | — | 表单/签名/附件等可能受损 |
| Word/PPT OOXML | ✓ 文档属性层 | — | — | — | ZIP 部件保持；不宣称检查内嵌媒体 |
| Excel OOXML | ✓ 文档属性层 | — | — | — | 公式/宏包保持；不宣称检查内嵌图片人脸/二维码 |

表格的“支持”目前严格限定为工作簿文档属性清理。单元格内容、隐藏工作表、批注、
外部链接、嵌入对象、内嵌图片元数据、人脸/二维码，以及打印水印都是不同能力，尚未
逐项实现前不得显示为已检查或已清理。Excel 本身没有等同图片像素水印的统一、无损
文件级水印语义；未来若增加页眉/背景/形状水印，必须分别验证打印、编辑和宏兼容性。

## Office 文档

| 类型 | 产品分级 |
|---|---|
| DOCX、XLSX、PPTX | 已支持文档属性清理；其他 ZIP 部件保持原压缩数据 |
| DOCM、XLSM、PPTM | 已支持属性清理；根据 Content Types 保持宏版本、扩展名、MIME、UTD |
| DOTX/DOTM、XLTX/XLTM、POTX/POTM、PPSX/PPSM | 已实现 Content Types 精确识别与输出映射；待对应 Office 应用回读 |
| DOC、XLS、PPT 及旧模板/放映格式 | 只读识别；不自动转换 OOXML，不声称无损 |
| 加密、IRM、受权限限制的文档 | 处理前阻止并说明原因 |
| 带数字签名/权限部件的文档 | 已在扫描阶段标记只读并阻止生成副本 |

Office 的“完整支持”当前只指文档属性层。批注、修订、隐藏内容、演讲者备注、
外部链接、嵌入对象及内嵌媒体元数据应作为独立检查层展示，不能混称为已全面检查。

## PDF

- 普通 PDF：目标为在副本上直接添加矢量水印/处理支持的属性，保留页面对象与文档功能。
- 当前页面重建方案属于“深度清理”，可能移除表单、书签、附件、批注、标签结构等，
  不得标为无损。
- 加密、权限受限、数字签名、PDF/A、PDF/X 文件必须先识别；水印可能破坏权限、签名或
  标准符合性，不能默认处理。

## 音频

| 类型 | 目标策略 |
|---|---|
| MP3 | 剥离 ID3v2/ID3v1/APE 标签，保留 MPEG 帧 | 已实现容器级标签清理 |
| FLAC/WAV/OGG/AMR/AAC | 仍仅检查 | 需各自标签写回器后再开放 |
| M4A | remux 复制音频轨 | 已有 |

当前音频只能视为“尽力检查、不能生成已验证清理副本”，不能作为完整支持能力宣传。

## 待办

- [ ] 已由统一能力注册表驱动处理门禁、结果提示和设置支持页；继续在批量列表和分享确认页显示逐文件精确类型。
- [ ] 相册资产识别已覆盖动态照片；继续补静态图 HDR/SDR、序列图和普通视频的显式资产子类型展示。
- [x] JPEG/PNG/HEIF/WebP 建立“仅元数据”无重编码路径；视觉编辑与元数据处理路径分离。
- [x] GIF 容器元数据清理保留动画帧、时序和循环控制。
- [x] JPEG 增加 COM/IPTC/隐私 XMP 检查，并保护 HDR/ICC/MPF/JUMBF/压缩负载。
- [x] PNG/WebP 增加容器 metadata 检查与无重编码清理。
- [x] Classic TIFF/DNG 增加 IFD/GPS/XMP/IPTC 深度清理。
- [x] OOXML 根据 Content Types 保持宏/模板/放映版本，并阻止签名/权限包。
- [x] 动态照片分别处理图片和视频元数据并重新组合；处理器拒绝其水印、人脸和二维码操作。
- [ ] 对每个输出同时复检删除项、替换项、保留项、真实格式和可回读性。
- [ ] OOXML 保持输入扩展名、Content-Type、MIME、UTD 与宏/模板/放映语义。
- [ ] PDF 增加普通保真处理与深度清理两种明确模式。
- [ ] 音频按 M4A、MP3、FLAC、WAV、Ogg、AAC、AMR 分容器实现和验收。
- [ ] 收紧分享入口 UTD；移除未经支持矩阵覆盖的泛 `general.file/general.object` 承诺。
- [ ] 建立华为相册、文件应用、系统分享入口三套真机样本矩阵并保存匿名化验收结果。

## 官方依据（API 24）

- [ImageSource 支持格式与运行时能力查询](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/arkts-apis-image-f)
- [PhotoPickerComponent 的图片子类型、HDR/SDR 与 MIME 信息](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ohos-file-photopickercomponent)
- [动态照片访问、拆分与保存](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/photoaccesshelper-movingphoto-V13)
- [Picture 对 JPEG/HEIF HDR、增益图和辅助图的保留语义](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/image-picture-decoding)
- [预置 UTD 清单](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/uniform-data-type-list-V13)
