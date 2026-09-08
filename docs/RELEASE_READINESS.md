# Release readiness

Updated: 2026-09-07

## Verified locally

- Bundle name is `com.safesharep.app`; the user-facing name remains 净享 / SafeShare.
- App and the single system share entry use the same 1024 px layered shield/share-arrow artwork.
  The background is opaque RGB and the foreground keeps transparency for system depth effects.
- Debug HAP and release APP compile, package and sign successfully with SDK 6.1.1 (API 24).
- The release APP and embedded Provision Profile pass the SDK signing tool's
  verification. The profile is release type, uses `normal` APL and matches
  `com.safesharep.app`.
- Release mode enables ArkTS obfuscation.
- The module declares no runtime permissions and project source contains no network request code.
- No production third-party dependencies are packaged; Hypium is development-only.
- No application logging of file URIs, detected content or coordinates is present.
- The system share sheet exposes one SafeShare receiver for images, supported documents,
  audio and video. Each record retains its own UTD, so mixed batches route independently;
  read-only media is never passed into an image or document sanitizer.
- MP4/MOV scanning first uses the platform extractor and now falls back to a bounded,
  read-only `moov` parser for creation time and common QuickTime location/device fields.
- Inputs are opened read-only; generated files use the application cache and have failure, replacement, return, share-complete, share-dismiss and next-launch cleanup paths.
- Share-panel wording is neutral for both privacy-cleaned and watermarked outputs.
- Primary icon-only controls expose accessibility text.
- MatePad Mini real-device smoke test passed for cold launch, native photo picker, metadata scan,
  independent persistence of the face/QR defaults, safe-copy generation, metadata recheck and the
  system share panel.
- A clear-face fixture produced an aligned face region on the original-resolution preview; the
  generated 1600 x 2560 JPEG visibly pixelated that region and the post-export visual recheck passed.

## Must be completed before submission

1. Confirm that the verified release certificate/Profile belong to the intended
   AGC production application and are the credentials to use for the first upload.
2. Increment `versionCode` for every uploaded build and confirm version name/release notes.
3. Publish a reachable privacy-policy URL matching `docs/PRIVACY.md`, and complete AppGallery's privacy/data labels consistently: no account, no network upload, no requested permissions, on-device image processing, temporary cache output.
4. Complete the remaining real-device regression using non-sensitive fixtures: cold/hot share-in,
   drag-and-drop, metadata keep/delete/replace, date picker, QR coordinates plus scan resistance,
   watermark preview/output, cancel/dismiss cleanup and the full batch path. Face detection and
   export have a passing single-fixture smoke test but still need rotated and multi-face fixtures.
5. Verify JPEG, PNG transparency, HEIF/HEIC, WebP, EXIF orientation, large/corrupt images, batches of 10 and 50, low-memory behavior, light/dark mode, large fonts, portrait/landscape, split screen and freeform windows.
6. Prepare AppGallery listing assets: 1024 px icon, phone/tablet screenshots, concise description, release notes, reviewer steps and any market-specific qualification/copyright documents.
7. Add meaningful automated tests. The current Hypium test file is only a placeholder, so successful builds do not imply logic coverage.
8. The project currently declares a `code-linter.json5`, but this SDK/project exposes no
   `codeLinter` hvigor task. Configure the matching lint plugin/task before treating lint as a release gate.

## Claims gate

Do not advertise QR redaction as verified until a real-device fixture demonstrates that the returned
coordinates align after orientation/scaling and that another device cannot scan the covered output.
Face preview/export has one passing real-device fixture, but should remain described as
device-dependent preview assistance until rotated, multi-face and failure-path coverage is complete.
