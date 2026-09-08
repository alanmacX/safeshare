# 界面文案修改入口

目前用户可见文案主要位于以下文件。修改后运行 Debug 构建即可检查是否存在 ArkTS 语法问题。

## 品牌名与系统展示

- `AppScope/resources/base/element/string.json`：桌面应用名称。
- `entry/src/main/resources/base/element/string.json`：模块描述、Ability 名称及系统入口描述。
- `AppScope/app.json5`：版本号、厂商与应用级资源引用；这里不直接写页面文案。

## 首页、设置、处理页和水印页

- `entry/src/main/ets/pages/Index.ets`：绝大多数界面文案，包括首页标题与引导、两个功能入口、选图提示、扫描/处理状态、元数据操作、设置项、预览按钮、水印设置、错误提示和分享按钮。
- 文件顶部的 `METADATA_DEFAULT_OPTIONS`：设置页中各元数据字段的中文名称。
- `watermarkSlots` 初始值：三个默认水印槽位；用户已保存的值来自本地 Preferences，不会因修改代码自动覆盖。

## 检测结果文案

- `entry/src/main/ets/metadata/MetadataScanner.ets`：GPS、时间、设备、作者等元数据发现项的标题、说明与建议。
- `entry/src/main/ets/vision/FaceScanner.ets`：人脸发现项标题、隐私说明和操作建议。
- `entry/src/main/ets/vision/QRScanner.ets`：二维码/条码发现项标题、隐私说明和操作建议。
- `entry/src/main/ets/privacy/PrivacyScanner.ets`：设备能力不可用、模型未就绪等降级提示。

## 系统分享面板和异常

- `entry/src/main/ets/share/ShareSender.ets`：系统分享面板标题与副本说明。
- `entry/src/main/ets/entryability/EntryAbility.ets`：从系统分享入口接收内容时的错误提示。
- `entry/src/main/ets/services/SafeShareService.ets`、`entry/src/main/ets/processors/ImagePrivacyProcessor.ets`：处理或复检失败时抛出的错误；多数最终会由页面转换成更友好的提示。

## 商店与审核文案

- `README.md`：项目公开介绍。
- `docs/PRIVACY.md`：隐私政策正文基础稿。
- `docs/REVIEW.md`：审核人员操作说明。
- `docs/RELEASE_READINESS.md`：上线阻断项，不属于 App 内文案。

## 后续整理建议

正式定稿时应把 `Index.ets`、扫描器和分享服务中的用户可见字符串迁移至资源文件，并增加英文或其他目标市场翻译。当前先保留在对应功能附近，便于快速迭代产品措辞。
