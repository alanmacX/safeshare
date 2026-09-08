# SafeShare engineering rules

- Preserve the local-first, privacy-first and non-destructive guarantees.
- Never log user URIs or detected sensitive content.
- Verify installed SDK declarations before using HarmonyOS APIs.
- Keep file and metadata operations out of ArkUI pages.
- Any newly generated share output must live in the app sandbox and have a cleanup path.
- Do not claim OCR, face, QR or object-detection support before real-device verification.
- Build after each capability slice; do not hide compiler failures.
