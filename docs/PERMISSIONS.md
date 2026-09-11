# Permissions

`module.json5` **不声明** `ohos.permission.READ_IMAGEVIDEO`。

AppGallery 已驳回该受限权限申请：仅允许数据克隆备份、相册整理、智能视频生成等场景，「分享前隐私清理」不符合。因此：

- 分享入口 **不再声明** `openharmony.moving-photo`
- 识别到动态照片（UTD / 复合文件 / `PHOTO_SUBTYPE`）后 **直接拒绝**，不进入处理
- 产品范围只覆盖普通静态图、PDF、Office、音视频

| 能力 | 权限 | 说明 |
|---|---|---|
| 接收分享 | 无 | Share Kit/Wanted URI 临时授权 |
| 主动选图 | 无 | PhotoViewPicker（动态照片会被跳过） |
| 文档/音视频选择 | 无 | DocumentViewPicker |
| 图片/PDF/Office 元数据 | 无 | 只读源 URI，写沙箱副本 |
| 端侧视觉 | 无 | Core Vision / Scan Kit，失败降级 |
| 分享副本 | 无 | Share Kit |
