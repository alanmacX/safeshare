# AppGallery submission draft

Updated: 2026-09-07

This file is the single copy source for the first HarmonyOS release. Text in
square brackets is a release blocker and must not be uploaded unchanged.

## Identity

- App name: 净享SafeShare
- Bundle name: `com.safesharep.app`
- Version: `1.0.0` (`1000001`)
- Supported devices: phone, tablet
- Category: 工具
- Charging model: 免费，不含应用内购买或广告

Before creating the first production app in AGC, explicitly confirm the bundle
name spelling. It becomes a durable application identity and must match the
release profile and uploaded package.

## Short description

清理照片与文件隐私，安心分享

## Full description

净享 SafeShare 是一款本地照片与文件隐私处理及水印工具。你可以查看照片携带的拍摄时间、位置、设备等元数据，并逐项选择保留、删除或替换；也可以检查 PDF、Word、Excel、PowerPoint 文件中的作者、公司、创建时间等文档属性，并生成清理后的副本；还可以为照片添加文字或图片水印，预览后生成副本分享。所有处理均在设备本地完成，不修改原照片或原文件。

Do not add face or QR detection/redaction to this listing until the remaining
real-device orientation, coordinate and scan-resistance gates are recorded as
passed. Do not advertise OCR, document-content scanning or object detection.

## What's new

- 支持照片、PDF 与常用 Office 文件的本地元数据检查。
- 新增手机和平板自适应结果页，平板横屏采用文件列表与检查器双栏布局。
- 优化浅色模式卡片边界、系统文件预览入口与临时副本清理流程。

## Privacy declarations

- Account: none.
- Requested runtime permissions: none. The packaged `module.json` has no
  `requestPermissions` section.
- Network upload: none; source contains no network request client.
- File access: user-initiated PhotoViewPicker, DocumentViewPicker or a scoped
  URI granted by the system share flow.
- Processing location: on device.
- Original files: read-only.
- Generated data: temporary copies in app cache with failure, cancel, replace,
  share completion/dismissal and next-launch cleanup paths.
- Third-party production SDKs: none. Hypium is development-only and is not a
  runtime dependency.
- Privacy-policy URL: `[PUBLISH AND ENTER HTTPS URL]`.
- Developer/controller name: `[LEGAL ENTITY OR DEVELOPER NAME]`.
- Contact channel: `[WORKING EMAIL OR OTHER PUBLISHED CONTACT]`.
- Effective date: `[YYYY-MM-DD]`.
- Children/minors statement and storage region/retention wording must be filled
  in the hosted policy according to the actual target audience and publisher.

The AGC privacy-policy permission list must remain empty for this build and
must exactly match the uploaded package. Recheck transitive package permissions
after every dependency change.

### AGC privacy-policy form copy

- Service: `在设备本地处理图片元数据、遮盖人脸与二维码、添加水印并生成分享副本`
- Purpose and processing description:

  用于读取并展示您主动选择的图片及其元数据，按照您的选择删除、保留或替换拍摄位置、设备序列号、作者等信息，添加文字或图片水印，并生成预览及分享副本。上述信息仅在您的设备本地处理，不会上传至我们运营的服务器；除您主动保存或分享外，我们不会对外提供处理结果。

- Cross-border destination: `用户设备本地，不会传输至我们运营的服务器`
- Developer chapter title: `本地处理与原图保护`
- Developer chapter content:

  本应用在用户设备本地完成图片读取、元数据检查、隐私区域分析和水印生成，不会将用户选择的图片、图片元数据或处理结果上传至我们的服务器。处理结果以新的图片副本生成，原始图片不会被修改。只有在用户主动点击保存或分享后，处理结果才会按照用户的选择交由系统图库、文件应用或分享目标处理。

## Reviewer notes

No login or test account is required. Suggested review path:

1. Open the app and use the system picker to choose a non-sensitive JPEG with
   EXIF metadata, or share it to “净享·隐私处理”.
2. Confirm that the original is not modified, choose metadata items, generate
   a safety copy and open the system share panel.
3. From the Files tab choose a docx/xlsx/pptx or PDF with document properties.
   Confirm that the app shows only actual properties, generates a sandbox copy,
   and the copy still opens through the system/installed preview app.
4. Choose an audio/video fixture and confirm the UI reports metadata read-only
   without offering a false cleaned copy.
5. On a tablet, rotate between portrait and landscape and verify the compact
   single-column and expanded master-detail layouts.

## Asset and package gate

- 1024 px icon: `docs/store/app-icon-1024.png`. The packaged foreground and
  background are separate 1024×1024 PNG resources; the background has no
  transparent pixels, as required by the HarmonyOS layered-icon specification.
- Phone screenshots: replace generated promotional composites with final,
  current-version device captures if AGC asks for interface screenshots.
- Tablet screenshots: capture the actual tablet layout; do not stretch phone
  images. Include one landscape document result screen.
- Screenshots and copy must not show a capability still blocked by real-device
  verification.
- Upload an APP assembled with the production certificate/profile. A
  release-mode HAP signed by a debug profile is not an AppGallery release.
- Increment `versionCode` for every uploaded build and preserve release symbol
  and source-map outputs.
- Run AGC package detection and Cloud Test (compatibility, stability,
  performance, power and UX) before submission, then use an open/invite test to
  validate the market install/update path.

## External blockers

- `[ ]` Confirm or change `com.safesharep.app` before first production identity.
- `[ ]` Confirm the verified release certificate/Profile are linked to the
  intended AGC production app; rebuild the final APP after all gates pass.
- `[ ]` Publish and enter the privacy-policy URL with controller/contact/date.
- `[ ]` Complete remaining physical-device QR and format/batch matrices.
- `[ ]` Run AGC package detection and Cloud Test; archive reports.
- `[ ]` Capture current phone/tablet screenshots and verify all text against this file.
- `[ ]` Confirm required China-mainland qualifications, APP filing and software
  copyright documents for the chosen publisher/category with the current AGC checklist.

## Official references checked

- Huawei AppGallery review policy: <https://developer.huawei.com/consumer/cn/doc/app/50104>
- Submit a HarmonyOS app: <https://developer.huawei.com/consumer/cn/app/submit>
- Configure a HarmonyOS privacy policy: <https://developer.huawei.com/consumer/cn/doc/doccenter-submission/agc-help-privacy-policy-app-0000002282162168>
- App privacy protection principles: <https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/bpta-app-privacy-protection>
- AGC Cloud Test: <https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-cloudtest-introduction-0000001083002880>
- HarmonyOS application icon specification: <https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/application-icon-0000001953444009>

These pages change over time. Reopen the current versions immediately before
submission instead of treating this draft as a substitute for AGC validation.
