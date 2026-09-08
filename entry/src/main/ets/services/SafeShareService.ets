import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { PrivacyScanResult, RedactionAction, SanitizedFile } from '../models/PrivacyModels';
import { ShareSender } from '../share/ShareSender';
import { TempFileManager, WatermarkAsset } from '../storage/TempFileManager';
import { ImagePrivacyProcessor } from '../processors/ImagePrivacyProcessor';
import { PdfPrivacyProcessor, PdfWatermarkOptions } from '../processors/DocumentPrivacyProcessor';
import { OoxmlFamilyTool } from '../processors/OoxmlPrivacyProcessor';
import { AvPrivacyTool } from '../processors/AvPrivacyProcessor';
import { FileKind, FileTypeRouter } from '../processors/FileTypeRouter';
import { FileSignatureRouter } from '../processors/FileSignatureRouter';
import { MetadataPolicy } from '../metadata/MetadataPolicy';
import { filePreview } from '@kit.PreviewKit';

import { hilog } from '@kit.PerformanceAnalysisKit';

function flowLog(stage: string, detail: string = ''): void {
  hilog.error(0x8801, 'SafeShareFlow', `stage=${stage}${detail.length > 0 ? ` ${detail}` : ''}`);
}

/**
 * Type dispatcher. Every file kind gets its own dedicated tool instance; the
 * service only routes and never mixes tool semantics. SanitizedFile carries
 * the kind so the share sheet titles stay type-specific.
 */
export class SafeShareService {
  private context: common.UIAbilityContext;
  private imageProcessor: ImagePrivacyProcessor;
  private pdfTool: PdfPrivacyProcessor;
  private wordTool: OoxmlFamilyTool;
  private excelTool: OoxmlFamilyTool;
  private powerpointTool: OoxmlFamilyTool;
  private avTool: AvPrivacyTool;
  private sender: ShareSender;
  private tempFiles: TempFileManager;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.imageProcessor = new ImagePrivacyProcessor(context);
    this.pdfTool = new PdfPrivacyProcessor(context);
    this.wordTool = new OoxmlFamilyTool(FileKind.WORD, 'Word 文档', context);
    this.excelTool = new OoxmlFamilyTool(FileKind.EXCEL, 'Excel 表格', context);
    this.powerpointTool = new OoxmlFamilyTool(FileKind.POWERPOINT, 'PPT 演示文稿', context);
    this.avTool = new AvPrivacyTool(context);
    this.sender = new ShareSender(context);
    this.tempFiles = new TempFileManager(context);
  }

  /**
   * Opens the system-owned preview surface without copying or modifying the
   * selected file. The UI layer never needs to inspect or resolve the URI.
   */
  async openFilePreview(uri: string, detectedMimeType: string = ''): Promise<boolean> {
    if (!(await filePreview.canPreview(this.context, uri))) return false;
    const kind: FileKind = FileTypeRouter.detect(uri);
    await filePreview.openPreview(this.context, {
      uri: uri,
      mimeType: detectedMimeType.length > 0 ? detectedMimeType : FileTypeRouter.mimeTypeForUri(uri, kind)
    });
    return true;
  }

  renderPdfFirstPage(uri: string): Promise<image.PixelMap | undefined> {
    return this.pdfTool.renderFirstPage(uri);
  }

  kindOf(uri: string, utd: string = ''): FileKind {
    return FileTypeRouter.detect(uri, utd);
  }

  labelOf(kind: FileKind): string {
    return FileTypeRouter.label(kind);
  }

  canHandle(uri: string): boolean {
    return FileTypeRouter.detect(uri) !== FileKind.UNKNOWN;
  }

  async resolveKind(uri: string, utd: string = ''): Promise<FileKind> {
    // URI path fragments are provider implementation details and may contain
    // a misleading suffix. Prefer the opened file's signature/display name;
    // use the supplied per-record UTD and URI only when probing is unavailable.
    const signatureKind: FileKind = await FileSignatureRouter.detect(uri);
    if (signatureKind !== FileKind.UNKNOWN) {
      return signatureKind;
    }
    return FileTypeRouter.detect(uri, utd);
  }

  async scanPrivacy(uri: string, utd: string = '',
    resolvedKind: FileKind = FileKind.UNKNOWN): Promise<PrivacyScanResult> {
    const kind: FileKind = resolvedKind === FileKind.UNKNOWN ? await this.resolveKind(uri, utd) : resolvedKind;
    if (kind === FileKind.IMAGE) {
      const result: PrivacyScanResult = await this.imageProcessor.scan(uri);
      result.fileKind = FileKind.IMAGE;
      return result;
    }
    if (kind === FileKind.PDF) {
      const result: PrivacyScanResult = await this.pdfTool.scan(uri);
      result.fileKind = FileKind.PDF;
      return result;
    }
    if (kind === FileKind.WORD) {
      const result: PrivacyScanResult = await this.wordTool.scan(uri);
      result.fileKind = FileKind.WORD;
      return result;
    }
    if (kind === FileKind.EXCEL) {
      const result: PrivacyScanResult = await this.excelTool.scan(uri);
      result.fileKind = FileKind.EXCEL;
      return result;
    }
    if (kind === FileKind.POWERPOINT) {
      const result: PrivacyScanResult = await this.powerpointTool.scan(uri);
      result.fileKind = FileKind.POWERPOINT;
      return result;
    }
    if (kind === FileKind.AUDIO_VIDEO) {
      const result: PrivacyScanResult = await this.avTool.scan(uri);
      result.fileKind = FileKind.AUDIO_VIDEO;
      return result;
    }
    throw new Error('Unsupported file type.');
  }

  /** Images, documents and video each keep a dedicated sanitize pipeline. */
  async sanitizeFile(uri: string, actions: RedactionAction[] = [],
    policy: MetadataPolicy = new MetadataPolicy(), utd: string = '',
    resolvedKind: FileKind = FileKind.UNKNOWN,
    pdfWatermark?: PdfWatermarkOptions): Promise<SanitizedFile> {
    const kind: FileKind = resolvedKind === FileKind.UNKNOWN ? await this.resolveKind(uri, utd) : resolvedKind;
    if (kind === FileKind.IMAGE) {
      const file: SanitizedFile = await this.imageProcessor.sanitize(uri, actions, policy);
      file.fileKind = FileKind.IMAGE;
      return file;
    }
    if (kind === FileKind.PDF) {
      const outcome = await this.pdfTool.sanitize(uri, policy, pdfWatermark);
      return this.documentOutput(outcome.outputPath, outcome.verification, FileKind.PDF);
    }
    if (kind === FileKind.WORD || kind === FileKind.EXCEL || kind === FileKind.POWERPOINT) {
      const tool: OoxmlFamilyTool = this.ooxmlToolFor(kind);
      const outcome = await tool.sanitize(uri, policy);
      return this.documentOutput(outcome.outputPath, outcome.verification, kind);
    }
    if (kind === FileKind.AUDIO_VIDEO) {
      return await this.avTool.sanitize(uri);
    }
    throw new Error('This file type does not support sanitized copies.');
  }

  async sanitizeFiles(uris: string[], actionsByFile: RedactionAction[][] = [],
    policy: MetadataPolicy = new MetadataPolicy(),
    policiesByFile: MetadataPolicy[] = [],
    utdsByFile: string[] = [],
    kindsByFile: FileKind[] = [],
    readOnlyByFile: boolean[] = [],
    onProgress?: (completed: number, total: number) => Promise<void>,
    pdfWatermark?: PdfWatermarkOptions): Promise<SanitizedFile[]> {
    const files: SanitizedFile[] = [];
    const resolvedKinds: FileKind[] = [];
    let supportedTotal: number = 0;
    for (let index: number = 0; index < uris.length; index++) {
      const utd: string = index < utdsByFile.length ? utdsByFile[index] : '';
      const suppliedKind: FileKind = index < kindsByFile.length ? kindsByFile[index] : FileKind.UNKNOWN;
      const kind: FileKind = suppliedKind === FileKind.UNKNOWN ? await this.resolveKind(uris[index], utd) : suppliedKind;
      resolvedKinds.push(kind);
      const readOnly: boolean = index < readOnlyByFile.length ? readOnlyByFile[index] :
        (kind === FileKind.AUDIO_VIDEO && FileTypeRouter.isAudioUri(uris[index]));
      if (kind !== FileKind.UNKNOWN && !readOnly) supportedTotal++;
    }
    let completed: number = 0;
    flowLog('sanitize_files_begin', `n=${uris.length} supported=${supportedTotal}`);
    try {
      for (let index: number = 0; index < uris.length; index++) {
        const actions: RedactionAction[] = index < actionsByFile.length ? actionsByFile[index] : [];
        const filePolicy: MetadataPolicy = index < policiesByFile.length ? policiesByFile[index] : policy;
        const utd: string = index < utdsByFile.length ? utdsByFile[index] : '';
        // Mixed incoming shares are valid. Per-file scan results decide which
        // entries are sanitizable; audio remains scan-only.
        const kind: FileKind = resolvedKinds[index];
        const readOnly: boolean = index < readOnlyByFile.length ? readOnlyByFile[index] :
          (kind === FileKind.AUDIO_VIDEO && FileTypeRouter.isAudioUri(uris[index]));
        if (kind === FileKind.UNKNOWN || readOnly) continue;
        flowLog('sanitize_file_begin', `i=${index} kind=${kind}`);
        const fileWatermark: PdfWatermarkOptions | undefined =
          kind === FileKind.PDF ? pdfWatermark : undefined;
        const sanitized: SanitizedFile =
          await this.sanitizeFile(uris[index], actions, filePolicy, utd, kind, fileWatermark);
        flowLog('sanitize_file_done', `i=${index}`);
        sanitized.sourceIndex = index;
        files.push(sanitized);
        completed++;
        if (onProgress !== undefined) {
          await onProgress(completed, supportedTotal);
        }
      }
      return files;
    } catch (error) {
      for (let index: number = 0; index < files.length; index++) {
        await this.tempFiles.remove(files[index].path);
      }
      const stage: string = (error as Error).message;
      // Stage-coded failures keep their specific message so the UI can show
      // the honest cause (video pipeline codes, PDF revision failures).
      if (stage.startsWith('VIDEO_') || stage.startsWith('AUDIO_') || stage.startsWith('PDF_COPY_FAILED:') ||
        stage === 'LEGACY_OFFICE_FORMAT') throw error as Error;
      throw new Error('Unable to create all verified sanitized copies.');
    }
  }

  shareSanitized(files: SanitizedFile[]): Promise<void> {
    return this.sender.share(files);
  }

  importWatermarkAsset(uri: string): Promise<WatermarkAsset> {
    return this.tempFiles.importWatermark(uri);
  }

  removeTemporaryPath(path: string): Promise<void> {
    return this.tempFiles.remove(path);
  }

  async discardSanitized(files: SanitizedFile[]): Promise<void> {
    for (let index: number = 0; index < files.length; index++) {
      await this.tempFiles.remove(files[index].path);
    }
  }

  dispose(): Promise<void> {
    return this.imageProcessor.dispose();
  }

  private ooxmlToolFor(kind: FileKind): OoxmlFamilyTool {
    if (kind === FileKind.EXCEL) return this.excelTool;
    if (kind === FileKind.POWERPOINT) return this.powerpointTool;
    return this.wordTool;
  }

  private documentOutput(copyPath: string, verification: PrivacyScanResult,
    kind: FileKind): SanitizedFile {
    const file: SanitizedFile = new SanitizedFile(copyPath, fileUri.getUriFromPath(copyPath),
      verification, FileTypeRouter.utdForUri(copyPath, kind), FileTypeRouter.mimeTypeForUri(copyPath, kind));
    file.fileKind = kind;
    try {
      file.byteSize = fileIo.statSync(copyPath).size;
    } catch (_) {
      file.byteSize = 0;
    }
    return file;
  }
}
