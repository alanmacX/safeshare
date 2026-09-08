# AppGallery review debug — 2026-09-06

## Passed locally

- API 24 debug HAP builds and signs successfully.
- API 24 release APP builds with release product, obfuscation and release signing.
- SDK verification passes for the outer APP signature and embedded Provision
  Profile; the profile is release type, normal APL and matches the bundle name.
- Debug HAP installs and starts on the 2880×1920 tablet emulator and the
  1320×2848 phone emulator.
- Tablet document workspace switches between a four-file mixed batch and keeps
  the selected file, per-file finding count and inspector content synchronized.
- PDF `打开文件` enters the system Preview Kit surface successfully.
- Light appearance uses visible card outlines; dark appearance retains readable
  text and controls on the phone emulator.
- `module.json5` declares no runtime permissions; file access is picker/share
  URI scoped.
- Release HAP contains only the two tutorial media assets. Development photos,
  QR samples and test documents are stored outside `entry/src/main`.
- Removed the abandoned in-app document-preview pipeline. Metadata scans no
  longer extract Office body text, embedded thumbnails or PDF page pixels for
  UI purposes; full content preview remains system-owned through Preview Kit.
- System-share titles now use the neutral term “安全副本” for images and
  documents instead of incorrectly calling every output a photo.
- File/ZIP diagnostics log only fixed stage names and numeric facts; native
  exception messages are not forwarded because providers may include paths.
- Packaged foreground/background icon resources are 1024×1024 PNG layers; the
  background alpha is fully opaque. Phone promotional PNGs are 1080×1920 and
  tablet promotional PNGs are 1920×1280, but final UI screenshots still need
  to be recaptured from the submission build.

## Still requires release-gate evidence

- Install/start the release-signed APP on a clean device. Updating over the
  debug-signed build correctly fails with `install sign info inconsistent`;
  no emulator app data was deleted to bypass that safety check.
- Run the complete landscape/portrait, 1:2, 1:1 and 2:1 window matrix on a
  HarmonyOS tablet and one second physical device.
- Verify Share Kit receive/send URI lifetime, Core Vision/Scan Kit model
  availability, real detection coordinates, 10/50-file performance and peak
  memory on physical devices.
- Publish the privacy-policy URL and confirm the permanent bundle name
  `com.safesharep.app` before the first AGC submission.

## Build warnings

The SDK still reports exception-handling warnings around native taskpool, zlib,
AV metadata, `ColorMetrics.resourceColor` and prompt APIs. The affected file,
ZIP and preview paths already fail closed or degrade to user-visible errors, but
these warnings remain recorded and must not be represented as a warning-free
release build.
