# SafeShare 可用格式清单（Available List）

判定标准：**只改 metadata、不动编码内容**（无损），并能在沙箱生成已复检副本。

## 一、华为相册媒体

华为相机/图库常见资产（含截图、录屏、慢动作、延时；动态照片除外）：

| 相册类型 | 常见封装 | 无损 metadata | 水印/人脸 | 状态 |
|---|---|---|---|---|
| 普通照片 | JPEG / HEIC（相机默认 HEIF） | ✓ | JPEG 可 | 可用 |
| 截图 | PNG / JPEG | ✓ | ✓ | 可用 |
| HDR 照片 | JPEG / HEIF + 增益图 | ✓ 原容器 | — | 可用（待 HDR 真机回读） |
| 专业 RAW | DNG / TIFF | ✓ 容器 IFD/GPS | — | 可用 |
| 动图 | GIF / 动画 WebP | ✓ 保留动画 | — | 可用 |
| 普通/慢动作/延时视频 | MP4 / MOV | ✓ remux 复制码流 | — | 可用 |
| 动态照片 | JPEG/HEIF + 视频 | — | — | **不支持**（权限与写回 API） |
| 连拍 | HEIF 序列 / JPEG 序列 | △ 序列图 | — | 序列元数据路径；视觉操作阻止 |

## 二、常见音频（无损清标签）

| 格式 | 策略 | 音频帧 |
|---|---|---|
| MP3 | 剥 ID3v2 / ID3v1 / APEv2 | 逐字节保留 |
| M4A | ISO-BMFF remux，复制音频轨 | 码流复制 |
| FLAC | 保留 STREAMINFO；删 Vorbis Comment / PICTURE / APPLICATION | 帧区原样 |
| WAV | 保留 `fmt ` + `data`；删 LIST INFO / bext / iXML 等 | 采样原样 |
| OGG / Opus / AAC / AMR | 仅检查 | — 暂不生成副本 |

## 三、文档

| 格式 | 无损范围 |
|---|---|
| DOCX / XLSX / PPTX（及宏/模板/放映变体） | ZIP 部件原样，只重写 docProps |
| PDF | 属性可清；当前副本为页面重建，**非无损** |
| 旧版 DOC / XLS / PPT（Office 97–2003） | 只读识别，不自动转换 |

## 四、明确不支持

- 动态照片（Moving Photo）
- AVIF/AVIS（API 26）
- SVG / ICO / WBMP
- 加密 / 签名 / 权限受限文档

## 五、门禁说明

- 源文件只读；输出仅写应用沙箱 `safeshare-*`
- 元数据路径不重编码像素/音视频帧
- 复检失败删除副本并阻止分享
- 真机格式矩阵未完成前，商店文案不得写“全部无损”

## 六、与 mat2（参考实现）对照

mat2 支持更广的桌面格式；手机场景我们优先覆盖相册 + Office + 常见音视频。

| mat2 | 我们 | 下一步可改进 |
|---|---|---|
| ODF odt/ods/odp | 无 | 复用 ZipContainer 清 `meta.xml` |
| SVG/SVGZ | 拒绝 | 剥离 metadata/title/XMP |
| EPUB | 无 | ZIP + OPF/dc |
| ZIP/TAR | 无 | 注释/额外字段/时间戳 |
| OGG/Opus/AAC | 仅检查 | comment 写回 |
| AVI/WMV | 无 | 同类 remux |
| PDF | 页面重建（非无损） | 优先保真 Info 定点清 |
| JPEG/PNG/TIFF/GIF/WebP/FLAC/WAV/MP3/M4A/MP4/OOXML | 已覆盖主路径 | 保持 |

mat2「不改数据 / lightweight」与我们「元数据路径无损」同一思路；我们额外有视觉打码与水印（仅 JPEG/PNG/WebP 静图）。
