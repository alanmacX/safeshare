/**
 * File-type routing. Each supported file kind exposes its own dedicated
 * privacy tool (scanner + sanitizer) with type-specific findings and copy —
 * never one generic "metadata bag". Detection is deterministic: extension
 * first, then the shared UTD id when the system provides one.
 */
export enum FileKind {
  IMAGE = 'IMAGE',
  PDF = 'PDF',
  WORD = 'WORD',
  EXCEL = 'EXCEL',
  POWERPOINT = 'POWERPOINT',
  AUDIO_VIDEO = 'AUDIO_VIDEO',
  UNKNOWN = 'UNKNOWN'
}

const PDF_EXTENSIONS: string[] = ['pdf'];
// Macro-enabled and template OOXML variants share the exact same ZIP package
// layout, so the sanitizer can process them identically.
const WORD_EXTENSIONS: string[] = ['docx', 'docm', 'dotx'];
const EXCEL_EXTENSIONS: string[] = ['xlsx', 'xlsm', 'xltx', 'xltm'];
const POWERPOINT_EXTENSIONS: string[] = ['pptx', 'pptm', 'ppsx', 'ppsm', 'potx', 'potm'];
// Legacy binary Office formats are recognized so the UI can name them and
// explain the upgrade path instead of reporting an anonymous unknown file.
const LEGACY_WORD_EXTENSIONS: string[] = ['doc', 'dot'];
const LEGACY_EXCEL_EXTENSIONS: string[] = ['xls', 'xlt'];
const LEGACY_POWERPOINT_EXTENSIONS: string[] = ['ppt', 'pps', 'pot'];
const AV_EXTENSIONS: string[] = ['mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm',
  'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', 'amr'];
const IMAGE_EXTENSIONS: string[] = ['jpg', 'jpeg', 'png', 'heif', 'heic', 'webp', 'gif', 'bmp'];

const PDF_UTD: string = 'com.adobe.pdf';
const WORD_UTD: string = 'org.openxmlformats.wordprocessingml.document';
const EXCEL_UTD: string = 'org.openxmlformats.spreadsheetml.sheet';
const POWERPOINT_UTD: string = 'org.openxmlformats.presentationml.presentation';
// Preset system UTDs for the OOXML template variants (verified against the
// published HarmonyOS Uniform Data Type list).
const WORD_UTDS: string[] = [WORD_UTD, 'org.openxmlformats.wordprocessingml.template'];
const EXCEL_UTDS: string[] = [EXCEL_UTD, 'org.openxmlformats.spreadsheetml.template'];
const POWERPOINT_UTDS: string[] = [POWERPOINT_UTD, 'org.openxmlformats.presentationml.template'];
// Legacy binary Office UTDs are matched for recognition only; the scan then
// degrades honestly because their containers are not OOXML ZIP packages.
const LEGACY_WORD_UTDS: string[] = ['com.microsoft.word.doc', 'com.microsoft.word.dot'];
const LEGACY_EXCEL_UTDS: string[] = ['com.microsoft.excel.xls', 'com.microsoft.excel.xlt'];
const LEGACY_POWERPOINT_UTDS: string[] = ['com.microsoft.powerpoint.ppt',
  'com.microsoft.powerpoint.pps', 'com.microsoft.powerpoint.pot'];
const PDF_UTDS: string[] = [PDF_UTD];
const IMAGE_UTD_PREFIX: string = 'general.image';
const AV_UTD_PREFIXES: string[] = ['general.video', 'general.audio'];

export class FileTypeRouter {
  static detect(uri: string, utd: string = ''): FileKind {
    const extension: string = FileTypeRouter.extensionOf(uri);
    // A concrete filename extension is stronger evidence than a generic UTD.
    // Some system providers label MOV assets as general.image; allowing that
    // UTD to win sent video into the photo/OCR pipeline.
    if (PDF_EXTENSIONS.indexOf(extension) >= 0) return FileKind.PDF;
    if (WORD_EXTENSIONS.indexOf(extension) >= 0) return FileKind.WORD;
    if (EXCEL_EXTENSIONS.indexOf(extension) >= 0) return FileKind.EXCEL;
    if (POWERPOINT_EXTENSIONS.indexOf(extension) >= 0) return FileKind.POWERPOINT;
    if (LEGACY_WORD_EXTENSIONS.indexOf(extension) >= 0) return FileKind.WORD;
    if (LEGACY_EXCEL_EXTENSIONS.indexOf(extension) >= 0) return FileKind.EXCEL;
    if (LEGACY_POWERPOINT_EXTENSIONS.indexOf(extension) >= 0) return FileKind.POWERPOINT;
    if (AV_EXTENSIONS.indexOf(extension) >= 0) return FileKind.AUDIO_VIDEO;
    if (IMAGE_EXTENSIONS.indexOf(extension) >= 0) return FileKind.IMAGE;

    if (PDF_UTDS.indexOf(utd) >= 0) return FileKind.PDF;
    if (WORD_UTDS.indexOf(utd) >= 0) return FileKind.WORD;
    if (EXCEL_UTDS.indexOf(utd) >= 0) return FileKind.EXCEL;
    if (POWERPOINT_UTDS.indexOf(utd) >= 0) return FileKind.POWERPOINT;
    if (LEGACY_WORD_UTDS.indexOf(utd) >= 0) return FileKind.WORD;
    if (LEGACY_EXCEL_UTDS.indexOf(utd) >= 0) return FileKind.EXCEL;
    if (LEGACY_POWERPOINT_UTDS.indexOf(utd) >= 0) return FileKind.POWERPOINT;
    for (let index: number = 0; index < AV_UTD_PREFIXES.length; index++) {
      if (utd.startsWith(AV_UTD_PREFIXES[index])) return FileKind.AUDIO_VIDEO;
    }
    if (utd.startsWith(IMAGE_UTD_PREFIX)) return FileKind.IMAGE;
    // Media-library URIs (photo picker, share panel) often carry no usable
    // extension — the asset id is the last path segment. Route them by their
    // well-known path segments instead of reporting UNKNOWN.
    if (uri.indexOf('media/image/') >= 0 || uri.indexOf('/media/Photo/') >= 0) {
      return FileKind.IMAGE;
    }
    if (uri.indexOf('media/video/') >= 0 || uri.indexOf('media/Audio/') >= 0 ||
      uri.indexOf('/media/Video/') >= 0) {
      return FileKind.AUDIO_VIDEO;
    }
    return FileKind.UNKNOWN;
  }

  static label(kind: FileKind): string {
    if (kind === FileKind.PDF) return 'PDF 文档';
    if (kind === FileKind.WORD) return 'Word 文档';
    if (kind === FileKind.EXCEL) return 'Excel 表格';
    if (kind === FileKind.POWERPOINT) return 'PPT 演示文稿';
    if (kind === FileKind.AUDIO_VIDEO) return '音视频文件';
    if (kind === FileKind.IMAGE) return '图片';
    return '文件';
  }

  static utdFor(kind: FileKind): string {
    if (kind === FileKind.PDF) return PDF_UTD;
    if (kind === FileKind.WORD) return WORD_UTD;
    if (kind === FileKind.EXCEL) return EXCEL_UTD;
    if (kind === FileKind.POWERPOINT) return POWERPOINT_UTD;
    if (kind === FileKind.AUDIO_VIDEO) return 'general.video';
    return 'general.image';
  }

  static mimeTypeFor(kind: FileKind): string {
    if (kind === FileKind.PDF) return 'application/pdf';
    if (kind === FileKind.WORD) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (kind === FileKind.EXCEL) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (kind === FileKind.POWERPOINT) {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
    if (kind === FileKind.AUDIO_VIDEO) return 'video/mp4';
    return 'image/jpeg';
  }

  static mimeTypeForUri(uri: string, kind: FileKind = FileKind.UNKNOWN): string {
    const detected: FileKind = kind === FileKind.UNKNOWN ? FileTypeRouter.detect(uri) : kind;
    const extension: string = FileTypeRouter.extensionOf(uri);
    if (extension === 'mov') return 'video/quicktime';
    if (extension === 'm4v') return 'video/x-m4v';
    if (extension === '3gp') return 'video/3gpp';
    if (extension === 'mkv') return 'video/x-matroska';
    if (extension === 'webm') return 'video/webm';
    if (extension === 'mp3') return 'audio/mpeg';
    if (extension === 'm4a') return 'audio/mp4';
    if (extension === 'wav') return 'audio/wav';
    if (extension === 'aac') return 'audio/aac';
    if (extension === 'flac') return 'audio/flac';
    if (extension === 'ogg') return 'audio/ogg';
    if (extension === 'amr') return 'audio/amr';
    return FileTypeRouter.mimeTypeFor(detected);
  }

  static isVideoUri(uri: string): boolean {
    const extension: string = FileTypeRouter.extensionOf(uri);
    return ['mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm'].indexOf(extension) >= 0 ||
      uri.indexOf('media/video/') >= 0 || uri.indexOf('/media/Video/') >= 0;
  }

  static isAudioUri(uri: string): boolean {
    const extension: string = FileTypeRouter.extensionOf(uri);
    return ['mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', 'amr'].indexOf(extension) >= 0 ||
      uri.indexOf('media/Audio/') >= 0;
  }

  static extensionFor(kind: FileKind): string {
    if (kind === FileKind.PDF) return 'pdf';
    if (kind === FileKind.WORD) return 'docx';
    if (kind === FileKind.EXCEL) return 'xlsx';
    if (kind === FileKind.POWERPOINT) return 'pptx';
    return 'jpg';
  }

  /** True when the URI names a legacy binary Office document (.doc/.xls/.ppt family). */
  static isLegacyOfficeUri(uri: string): boolean {
    const extension: string = FileTypeRouter.extensionOf(uri);
    return LEGACY_WORD_EXTENSIONS.indexOf(extension) >= 0 ||
      LEGACY_EXCEL_EXTENSIONS.indexOf(extension) >= 0 ||
      LEGACY_POWERPOINT_EXTENSIONS.indexOf(extension) >= 0;
  }

  static extensionOf(uri: string): string {
    let path: string = uri;
    const schemeEnd: number = path.indexOf('://');
    if (schemeEnd >= 0) {
      path = path.substring(schemeEnd + 3);
      const queryStart: number = path.indexOf('?');
      if (queryStart >= 0) {
        path = path.substring(0, queryStart);
      }
    }
    try { path = decodeURIComponent(path); } catch (_) {}
    const dotIndex: number = path.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex === path.length - 1) {
      return '';
    }
    return path.substring(dotIndex + 1).toLowerCase();
  }
}
