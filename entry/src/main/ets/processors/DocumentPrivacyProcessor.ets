import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pdfService } from '@kit.PDFKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { Font } from '@kit.ArkUI';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RiskLevel } from '../models/PrivacyModels';
import { TempFileManager } from '../storage/TempFileManager';
import { ZipContainer } from '../metadata/ZipContainer';
import { MetadataPolicy, MetadataReplacement } from '../metadata/MetadataPolicy';

function logStage(stage: string, detail: string = ''): void {
  hilog.info(0x8801, 'SafeShareDoc', `pdf stage=${stage}${detail.length > 0 ? ` ${detail}` : ''}`);
}

/**
 * PDF metadata findings via PDF Kit getMetadata(). Sanitization rewrites the
 * document with PDF Kit into a sandbox copy; the producer of that copy is the
 * system PDF service, so the original Info dictionary values are not carried
 * over. Every output is re-scanned and must come back clean (fail closed).
 */
class ResolvedPdfSource {
  // Absolute sandbox path PDF Kit can load directly.
  path: string = '';
  // Set when the source was a granted URI copied into the sandbox; the copy
  // must be removed after use.
  copyPath: string = '';
  sourceName: string = '';
}

class PdfInfoField {
  key: string;
  subtype: string;

  constructor(key: string, subtype: string) {
    this.key = key;
    this.subtype = subtype;
  }
}

export class PdfPrivacyProcessor {
  private tempFiles: TempFileManager;

  static readonly INFO_FIELDS: PdfInfoField[] = [
    new PdfInfoField('Author', 'PDF_AUTHOR'),
    new PdfInfoField('Title', 'PDF_TITLE'),
    new PdfInfoField('Subject', 'PDF_SUBJECT'),
    new PdfInfoField('Keywords', 'PDF_KEYWORDS'),
    new PdfInfoField('Creator', 'PDF_CREATOR'),
    new PdfInfoField('Producer', 'PDF_PRODUCER'),
    new PdfInfoField('CreationDate', 'PDF_CREATE_TIME'),
    new PdfInfoField('ModDate', 'PDF_MODIFY_TIME')
  ];

  constructor(context: common.UIAbilityContext) {
    this.tempFiles = new TempFileManager(context);
  }

  async scan(uri: string): Promise<PrivacyScanResult> {
    const resolved: ResolvedPdfSource = await this.resolveReadablePath(uri);
    const document: pdfService.PdfDocument = new pdfService.PdfDocument();
    const findings: PrivacyFinding[] = [];
    try {
      const parseResult: pdfService.ParseResult = document.loadDocument(resolved.path);
      logStage('load', `r=${parseResult === pdfService.ParseResult.PARSE_SUCCESS ? 1 : 0}`);
      if (parseResult !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error('PDF parse failed.');
      }
      const metadata: pdfService.Metadata = document.getMetadata();
      this.pushFinding(findings, 'PDF_AUTHOR', RiskLevel.MEDIUM, '包含文档作者', '作者字段可能包含姓名。',
        metadata.author);
      this.pushFinding(findings, 'PDF_TITLE', RiskLevel.LOW, '包含文档标题', '标题可能描述文件内容或项目。',
        metadata.title);
      this.pushFinding(findings, 'PDF_SUBJECT', RiskLevel.MEDIUM, '包含文档主题', '主题可能描述工作或事务内容。',
        metadata.subject);
      this.pushFinding(findings, 'PDF_KEYWORDS', RiskLevel.MEDIUM, '包含文档关键词', '关键词可能包含人名、项目或客户名。',
        metadata.keywords);
      this.pushFinding(findings, 'PDF_CREATOR', RiskLevel.LOW, '包含创建程序', '记录最初创建文件的软件。',
        metadata.creator);
      this.pushFinding(findings, 'PDF_PRODUCER', RiskLevel.LOW, '包含生成程序', '记录转换或导出 PDF 的软件。',
        metadata.producer);
      this.pushDateFinding(findings, 'PDF_CREATE_TIME', RiskLevel.LOW, '包含创建时间',
        '创建时间可能暴露工作规律。', metadata.creationDate);
      this.pushDateFinding(findings, 'PDF_MODIFY_TIME', RiskLevel.LOW, '包含修改时间',
        '修改时间可能暴露近期活动。', metadata.modifiedDate);
      return new PrivacyScanResult(uri, findings);
    } finally {
      try {
        document.releaseDocument();
      } catch (_) {
      }
      if (resolved.copyPath.length > 0) {
        await this.tempFiles.remove(resolved.copyPath);
      }
    }
  }

  async sanitize(uri: string, policy: MetadataPolicy = new MetadataPolicy(),
    watermark?: PdfWatermarkOptions): Promise<PdfSanitizeOutcome> {
    const resolved: ResolvedPdfSource = await this.resolveReadablePath(uri);
    const outputPath: string = this.tempFiles.createOutputPath(
      resolved.sourceName.length > 0 ? resolved.sourceName : uri, 'pdf');
    // Byte-identical ASCII-named twin used for the PDF Kit verification round
    // trip; published to outputPath only after the verification passes.
    const verifyPath: string = this.tempFiles.createPath('pdf');
    // Rebuild the document through PDF Kit itself: pages are imported into a
    // fresh document whose metadata starts empty, so every source property —
    // /Info values, XMP, and anything byte surgery could not reach — is left
    // behind in the source file. Attachments and document-level extras do not
    // travel with pages, which is the desired privacy behavior.
    const source: pdfService.PdfDocument = new pdfService.PdfDocument();
    const target: pdfService.PdfDocument = new pdfService.PdfDocument();
    let sourceMetadata: pdfService.Metadata | undefined = undefined;
    try {
      if (source.loadDocument(resolved.path) !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error('PDF_COPY_FAILED:SOURCE_PARSE');
      }
      sourceMetadata = source.getMetadata();
      const pageCount: number = source.getPageCount();
      if (pageCount <= 0) {
        throw new Error('PDF_COPY_FAILED:EMPTY_DOCUMENT');
      }
      const pageWidth: number = source.getPage(0).getWidth();
      const pageHeight: number = source.getPage(0).getHeight();
      if (!target.createDocument(pageWidth, pageHeight)) {
        throw new Error('PDF_COPY_FAILED:CREATE_DOCUMENT');
      }
      target.insertPageFromDocument(source, 0, pageCount, 0);
      // createDocument starts with one blank page; drop whatever remains
      // behind the imported pages.
      const afterInsert: number = target.getPageCount();
      if (afterInsert > pageCount) {
        target.deletePage(afterInsert - 1, afterInsert - pageCount);
      }
      if (watermark !== undefined) {
        logStage('wm_request', `ok=${PdfWatermarkOptions.valid(watermark) ? 1 : 0}`);
      }
      if (PdfWatermarkOptions.valid(watermark) && pageCount > 0) {
        // Text watermark MUST carry a real font path, otherwise PDF Kit
        // renders nothing (official guide pattern). Resolved once, reused for
        // every placement.
        const fontInfo: pdfService.FontInfo = new pdfService.FontInfo();
        try {
          const font: Font = new Font();
          fontInfo.fontPath = font.getFontByName('HarmonyOS Sans').path;
        } catch (_) {
          logStage('wm_font', 'r=0');
        }
        if (fontInfo.fontPath === undefined || fontInfo.fontPath.length === 0) {
          logStage('wm_font', 'r=0');
        }
        // The API places ONE instance per call (alignment + offset). A 3x3
        // alignment grid gives the tiled look; spaces stay at the documented
        // near-edge value like the official sample.
        const request: PdfWatermarkOptions = watermark as PdfWatermarkOptions;
        // Dense full-page grid: exact per-cell placement via LEFT/TOP
        // alignment + pixel offsets (the API positions one instance per
        // call). Cell size adapts to the rendered text footprint so short
        // and long strings tile with comparable density; rotated text needs
        // extra vertical room for its diagonal extent.
        const text: string = request.text.trim().slice(0, 60);
        const requestedSize: number = Math.max(12, Math.min(160, request.textSize));
        let charWidthSum: number = 0;
        for (let i = 0; i < text.length; i++) {
          charWidthSum += text.charCodeAt(i) > 0x2E7F ? requestedSize : requestedSize * 0.58;
        }
        const charWidthPerPt: number = charWidthSum / requestedSize;
        // Density first: the grid divides the page into at least 3x4 cells;
        // long strings shrink their per-cell font size instead of collapsing
        // the grid (floor 12pt keeps every instance readable).
        let cols: number = Math.floor(pageWidth /
          Math.max(charWidthSum * 1.15, pageWidth / 6));
        let rows: number = Math.floor(pageHeight /
          Math.max(requestedSize * 2.4, pageHeight / 8));
        cols = Math.max(3, Math.min(8, cols));
        rows = Math.max(4, Math.min(10, rows));
        if (cols * rows > 48) {
          const shrink: number = Math.sqrt(48 / (cols * rows));
          cols = Math.max(3, Math.floor(cols * shrink));
          rows = Math.max(4, Math.floor(rows * shrink));
        }
        const cellStepX: number = pageWidth / cols;
        const cellStepY: number = pageHeight / rows;
        const textSize: number = Math.max(12, Math.floor(Math.min(requestedSize,
          cellStepX * 0.92 / charWidthPerPt, cellStepY / 2.4)));
        const textWidth: number = charWidthPerPt * textSize;
        for (let r = 0; r < rows; r++) {
          for (let c = 0; c < cols; c++) {
            // Empirically (02:32 run) the space fields are NOT pixels: values
            // above ~1 render off-page while the official sample's 1.0 sits
            // exactly at the edge — i.e. a multiplier where 1.0 = edge and
            // larger values scale linearly across the page. Map each cell
            // center to 1 + fraction of the page, always inside [1, 2].
            const offsetX: number = 1 + Math.min(0.98, Math.max(0,
              (c + 0.5) / cols - 0.5 * textWidth / pageWidth));
            const offsetY: number = 1 + Math.min(0.98, Math.max(0,
              (r + 0.5) / rows - 0.5 * textSize / pageHeight));
            const info: pdfService.TextWatermarkInfo = {
              watermarkType: pdfService.WatermarkType.WATERMARK_TEXT,
              content: text,
              rotation: request.rotation,
              opacity: Math.max(0.05, Math.min(0.9, request.opacity)),
              scale: 1,
              isOnTop: true,
              horizontalAlignment: pdfService.WatermarkAlignment.WATERMARK_ALIGNMENT_LEFT,
              verticalAlignment: pdfService.WatermarkAlignment.WATERMARK_ALIGNMENT_TOP,
              horizontalSpace: offsetX,
              verticalSpace: offsetY,
              textSize: textSize,
              textColor: request.darkText ? 0x000000 : 0xFFFFFF,
              fontInfo: fontInfo
            };
            target.addWatermark(info, 0, pageCount - 1, true, true);
          }
        }
        logStage('watermark',
          `pages=${pageCount} grid=${cols}x${rows} font=${fontInfo.fontPath !== undefined ? 1 : 0}`);
        await this.logWatermarkVisibility(source, target);
      }
      if (!target.saveDocument(verifyPath)) {
        throw new Error('PDF_COPY_FAILED:SAVE_DOCUMENT');
      }
      logStage('rebuild', `pages=${pageCount}`);
    } catch (error) {
      const stage: string = ((error as Error).message ?? '').startsWith('PDF_COPY_FAILED') ?
        ((error as Error).message ?? '') : 'PDF_COPY_FAILED:REBUILD';
      logStage('write_failed', `err=${stage.slice(0, 60)}`);
      await this.tempFiles.remove(verifyPath);
      await this.tempFiles.remove(outputPath);
      throw new Error(stage);
    } finally {
      try { target.releaseDocument(); } catch (_) {}
      try { source.releaseDocument(); } catch (_) {}
      if (resolved.copyPath.length > 0) {
        await this.tempFiles.remove(resolved.copyPath);
      }
    }
    // Apply requested replacement values on the rebuilt file. PDF Kit exposes
    // no metadata setter, and its own output is a plain classic serialization
    // whose /Info object edits in place; deletions were already handled by the
    // rebuild, so only replacements are edited here.
    const replacementEdits: InfoEdit[] = [];
    for (let index = 0; index < PdfPrivacyProcessor.INFO_FIELDS.length; index++) {
      const field: PdfInfoField = PdfPrivacyProcessor.INFO_FIELDS[index];
      const replacement: string | undefined =
        PdfPrivacyProcessor.replacementFor(policy.replacements, field.subtype);
      if (replacement !== undefined) {
        replacementEdits.push(new InfoEdit(field.key,
          PdfPrivacyProcessor.pdfDateValue(field.subtype, replacement)));
      }
    }
    if (replacementEdits.length > 0) {
      try {
        const rebuilt: Uint8Array = await ZipContainer.readFileBytes(verifyPath);
        const edited: Uint8Array | undefined =
          PdfPrivacyProcessor.editInfoEntries(rebuilt, replacementEdits);
        if (edited === undefined) {
          throw new Error('PDF_COPY_FAILED:REPLACE_LAYOUT');
        }
        await ZipContainer.writeFileBytes(verifyPath, edited);
        logStage('replace', `n=${replacementEdits.length}`);
      } catch (error) {
        await this.tempFiles.remove(verifyPath);
        await this.tempFiles.remove(outputPath);
        const message: string = (error as Error).message ?? '';
        throw new Error(message.startsWith('PDF_COPY_FAILED') ? message :
          'PDF_COPY_FAILED:REPLACE_LAYOUT');
      }
    }
    // Verify via PDF Kit itself on the ASCII-named twin. A deleted field is
    // clean when absent OR when it no longer carries the source's original
    // value (PDF Kit may stamp its own producer/date fields); a replacement
    // must round-trip to the exact requested value.
    let verification: PrivacyScanResult;
    try {
      verification = await this.scan(this.outputUri(verifyPath));
    } catch (error) {
      logStage('verify_threw', `err=${((error as Error).message ?? '').slice(0, 80)}`);
      await this.tempFiles.remove(verifyPath);
      await this.tempFiles.remove(outputPath);
      throw error as Error;
    }
    const sourceValues: string[] = [];
    for (let index = 0; index < PdfPrivacyProcessor.INFO_FIELDS.length; index++) {
      const field: PdfInfoField = PdfPrivacyProcessor.INFO_FIELDS[index];
      sourceValues.push(PdfPrivacyProcessor.metadataValue(sourceMetadata as pdfService.Metadata,
        field.subtype));
    }
    let leaked = 0;
    const names: string[] = [];
    for (let index = 0; index < verification.findings.length; index++) {
      const finding: PrivacyFinding = verification.findings[index];
      const replacement: string | undefined =
        PdfPrivacyProcessor.replacementFor(policy.replacements, finding.subtype);
      if (replacement !== undefined) {
        if (finding.rawValue !== replacement) leaked++;
        continue;
      }
      if (policy.preserveSubtypes.indexOf(finding.subtype) >= 0) continue;
      const fieldIndex: number = PdfPrivacyProcessor.infoFieldIndex(finding.subtype);
      if (fieldIndex >= 0 && sourceValues[fieldIndex].length > 0 &&
        finding.rawValue === sourceValues[fieldIndex]) {
        leaked++;
        if (names.indexOf(finding.subtype) < 0) names.push(finding.subtype);
      }
    }
    logStage(leaked > 0 ? 'verify_leak' : 'verify_ok',
      leaked > 0 ? `leaked=${leaked} of=${names.join('|').slice(0, 90)}` : 'r=1');
    if (leaked > 0) {
      await this.tempFiles.remove(verifyPath);
      await this.tempFiles.remove(outputPath);
      throw new Error('Sanitized PDF metadata verification failed.');
    }
    // Verified under the ASCII name — publish under the display name.
    try {
      await fileIo.moveFile(verifyPath, outputPath);
    } catch (_) {
      await fileIo.copyFile(verifyPath, outputPath);
      await this.tempFiles.remove(verifyPath);
    }
    const outcome: PdfSanitizeOutcome = {
      outputPath: outputPath,
      verification: verification
    };
    return outcome;
  }

  /**
   * Renders page 1 of source and target and counts pixels that changed.
   * Any watermark placement produces changed pixels; a silent no-op (bad
   * font, off-page offsets) shows as an empty diff. Runs after the watermark
   * is applied and only for the first page.
   */
  private async logWatermarkVisibility(source: pdfService.PdfDocument,
    target: pdfService.PdfDocument): Promise<void> {
    try {
      if (source.getPageCount() <= 0 || target.getPageCount() <= 0) return;
      const before: image.PixelMap = source.getPage(0).getPagePixelMap();
      let after: image.PixelMap | undefined = undefined;
      try {
        after = target.getPage(0).getPagePixelMap();
        const info: image.ImageInfo = await before.getImageInfo();
        const w: number = Math.min(200, info.size.width);
        const h: number = Math.min(200, info.size.height);
        const stride: number = w * 4;
        const bufA: ArrayBuffer = new ArrayBuffer(stride * h);
        const bufB: ArrayBuffer = new ArrayBuffer(stride * h);
        before.readPixels({ pixels: bufA, offset: 0, stride: stride,
          region: { x: 0, y: 0, size: { width: w, height: h } } });
        after.readPixels({ pixels: bufB, offset: 0, stride: stride,
          region: { x: 0, y: 0, size: { width: w, height: h } } });
        const a: Uint8Array = new Uint8Array(bufA);
        const b: Uint8Array = new Uint8Array(bufB);
        let changed: number = 0;
        const samples: number = w * h;
        for (let i = 0; i < samples; i++) {
          if (Math.abs(a[i * 4] - b[i * 4]) > 12) changed++;
        }
        logStage('wm_visible', `ratio=${(changed / samples).toFixed(3)}`);
      } finally {
        try { after?.release(); } catch (_) {}
        try { before.release(); } catch (_) {}
      }
    } catch (_) {
      logStage('wm_visible', 'err');
    }
  }

  private static infoFieldIndex(subtype: string): number {
    for (let index = 0; index < PdfPrivacyProcessor.INFO_FIELDS.length; index++) {
      if (PdfPrivacyProcessor.INFO_FIELDS[index].subtype === subtype) return index;
    }
    return -1;
  }

  private readMetadata(path: string): pdfService.Metadata {
    const document: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      if (document.loadDocument(path) !== pdfService.ParseResult.PARSE_SUCCESS) {
        throw new Error('PDF parse failed.');
      }
      return document.getMetadata();
    } finally {
      try { document.releaseDocument(); } catch (_) {}
    }
  }

  private static replacementFor(replacements: MetadataReplacement[], subtype: string): string | undefined {
    for (let index = 0; index < replacements.length; index++) {
      if (replacements[index].subtype === subtype && replacements[index].value.length > 0) {
        return replacements[index].value;
      }
    }
    return undefined;
  }

  private static metadataValue(metadata: pdfService.Metadata, subtype: string): string {
    if (subtype === 'PDF_AUTHOR') return metadata.author;
    if (subtype === 'PDF_TITLE') return metadata.title;
    if (subtype === 'PDF_SUBJECT') return metadata.subject;
    if (subtype === 'PDF_KEYWORDS') return metadata.keywords;
    if (subtype === 'PDF_CREATOR') return metadata.creator;
    if (subtype === 'PDF_PRODUCER') return metadata.producer;
    if (subtype === 'PDF_CREATE_TIME') return PdfPrivacyProcessor.validIso(metadata.creationDate);
    if (subtype === 'PDF_MODIFY_TIME') return PdfPrivacyProcessor.validIso(metadata.modifiedDate);
    return '';
  }

  private static validIso(value: Date): string {
    return value === undefined || value === null || Number.isNaN(value.getTime()) ? '' : value.toISOString();
  }

  private static pdfDateValue(subtype: string, value: string): string {
    if (subtype !== 'PDF_CREATE_TIME' && subtype !== 'PDF_MODIFY_TIME') return value;
    const parsed: Date = new Date(value);
    if (Number.isNaN(parsed.getTime())) return value;
    return `D:${parsed.getUTCFullYear()}${PdfPrivacyProcessor.two(parsed.getUTCMonth() + 1)}` +
      `${PdfPrivacyProcessor.two(parsed.getUTCDate())}${PdfPrivacyProcessor.two(parsed.getUTCHours())}` +
      `${PdfPrivacyProcessor.two(parsed.getUTCMinutes())}${PdfPrivacyProcessor.two(parsed.getUTCSeconds())}Z`;
  }

  private static two(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /**
   * One-token encoding for an in-place /Info value: dates stay plain
   * "D:YYYYMMDDHHmmSSZ" literals; everything else becomes a UTF-16BE hex
   * string so any byte sequence survives without escape handling.
   */
  private static encodedInfoToken(key: string, value: string): string {
    if (key === 'CreationDate' || key === 'ModDate') {
      return `(${value})`;
    }
    return PdfPrivacyProcessor.utf16HexString(value);
  }

  private static utf16HexString(value: string): string {
    let hex = 'FEFF';
    for (let index = 0; index < value.length; index++) {
      hex += value.charCodeAt(index).toString(16).toUpperCase().padStart(4, '0');
    }
    return `<${hex}>`;
  }

  private static asciiText(bytes: Uint8Array, start: number, end: number): string {
    let result = '';
    const chunkSize = 8192;
    for (let chunkStart = start; chunkStart < end; chunkStart += chunkSize) {
      const chunkEnd: number = Math.min(end, chunkStart + chunkSize);
      for (let index = chunkStart; index < chunkEnd; index++) {
        result += String.fromCharCode(bytes[index]);
      }
    }
    return result;
  }

  private static numberAfter(text: string, start: number): number {
    let cursor = start;
    while (cursor < text.length && (text[cursor] === ' ' || text[cursor] === '\r' || text[cursor] === '\n')) cursor++;
    let value = 0;
    let digits = 0;
    while (cursor < text.length && text.charCodeAt(cursor) >= 48 && text.charCodeAt(cursor) <= 57) {
      value = value * 10 + text.charCodeAt(cursor) - 48;
      digits++;
      cursor++;
    }
    return digits === 0 ? -1 : value;
  }

  private static lastNumber(text: string, key: string): number {
    const at: number = text.lastIndexOf(key);
    return at < 0 ? -1 : PdfPrivacyProcessor.numberAfter(text, at + key.length);
  }

  private static lastReference(text: string, key: string): string {
    let from = text.length;
    while (from > 0) {
      const at: number = text.lastIndexOf(key, from - 1);
      if (at < 0) return '';
      let cursor = at + key.length;
      const first: number = PdfPrivacyProcessor.numberAfter(text, cursor);
      if (first >= 0) {
        while (cursor < text.length && (text[cursor] < '0' || text[cursor] > '9')) cursor++;
        while (cursor < text.length && text[cursor] >= '0' && text[cursor] <= '9') cursor++;
        const generation: number = PdfPrivacyProcessor.numberAfter(text, cursor);
        if (generation >= 0) return `${first} ${generation} R`;
      }
      from = at;
    }
    return '';
  }

  /**
   * Edits /Info dictionary values in place inside every Info object. An empty
   * edit value blanks the whole "/Key …" span; a non-empty value is written as
   * one token at the span start and padded with spaces — byte offsets never
   * move, so the parser sees the identical structure. Returns undefined when
   * the layout cannot be edited deterministically or a token does not fit.
   */
  private static editInfoEntries(bytes: Uint8Array, edits: InfoEdit[]): Uint8Array | undefined {
    if (edits.length === 0) return bytes;
    const output: Uint8Array = bytes.slice();
    const infoIds: number[] = PdfPrivacyProcessor.findInfoObjectIds(output);
    if (infoIds.length === 0) {
      return undefined;
    }
    for (let index = 0; index < infoIds.length; index++) {
      const objHead: number[] = PdfPrivacyProcessor.ascii(`${infoIds[index]} 0 obj`);
      const objEndMarker: number[] = PdfPrivacyProcessor.ascii('endobj');
      let dictStart: number = -1;
      let searchFrom = 0;
      for (;;) {
        const at: number = PdfPrivacyProcessor.indexOf(output, objHead, searchFrom);
        if (at < 0) {
          return undefined;
        }
        const objEnd: number = PdfPrivacyProcessor.indexOf(output, objEndMarker, at);
        if (objEnd < 0) {
          return undefined;
        }
        // The match may be a suffix of a longer id ("1 0 obj" inside
        // "11 0 obj"); require the preceding byte to be a non-digit.
        if (at === 0 || output[at - 1] < 0x30 || output[at - 1] > 0x39) {
          dictStart = at;
          break;
        }
        searchFrom = at + 1;
      }
      const dictOpen: number = PdfPrivacyProcessor.indexOf(output,
        PdfPrivacyProcessor.ascii('<<'), dictStart);
      const objClose: number = PdfPrivacyProcessor.indexOf(output,
        PdfPrivacyProcessor.ascii('endobj'), dictStart);
      if (dictOpen < 0 || objClose < 0 || dictOpen > objClose) {
        return undefined;
      }
      // Match nested << >> pairs to find this dictionary's true end.
      let depth = 0;
      let cursor = dictOpen;
      let dictEnd = -1;
      while (cursor + 1 < objClose) {
        if (output[cursor] === 0x3c && output[cursor + 1] === 0x3c) {
          depth++;
          cursor += 2;
        } else if (output[cursor] === 0x3e && output[cursor + 1] === 0x3e) {
          depth--;
          cursor += 2;
          if (depth === 0) {
            dictEnd = cursor;
            break;
          }
        } else {
          cursor++;
        }
      }
      if (dictEnd < 0) {
        return undefined;
      }
      for (let k = 0; k < edits.length; k++) {
        const edit: InfoEdit = edits[k];
        const keyPattern: number[] = PdfPrivacyProcessor.ascii(`/${edit.key}`);
        let keyFrom = dictOpen + 2;
        for (;;) {
          const keyAt: number = PdfPrivacyProcessor.indexOf(output, keyPattern, keyFrom);
          if (keyAt < 0 || keyAt >= dictEnd - 2) break;
          // Span covers the key name AND its value up to the next top-level
          // "/Key" or the dictionary end.
          let nextKey = PdfPrivacyProcessor.indexOf(output,
            PdfPrivacyProcessor.ascii(' /'), keyAt + keyPattern.length);
          if (nextKey < 0 || nextKey > dictEnd - 2) nextKey = dictEnd - 2;
          if (edit.value.length === 0) {
            for (let b = keyAt; b < nextKey; b++) {
              if (output[b] !== 0x0a && output[b] !== 0x0d) output[b] = 0x20;
            }
          } else {
            const token: string =
              PdfPrivacyProcessor.encodedInfoToken(edit.key, edit.value);
            if (token.length > nextKey - keyAt) {
              return undefined;
            }
            for (let b = keyAt; b < nextKey; b++) output[b] = 0x20;
            for (let c = 0; c < token.length; c++) output[keyAt + c] = token.charCodeAt(c) & 0xff;
          }
          keyFrom = nextKey;
        }
      }
    }
    return output;
  }

  private static findInfoObjectIds(bytes: Uint8Array): number[] {
    const ids: number[] = [];
    const marker: number[] = PdfPrivacyProcessor.ascii('/Info');
    let from = 0;
    for (;;) {
      const at: number = PdfPrivacyProcessor.indexOf(bytes, marker, from);
      if (at < 0) {
        return ids;
      }
      from = at + marker.length;
      // Parse "/Info N 0 R".
      let cursor = from;
      while (cursor < bytes.length && (bytes[cursor] === 0x20 || bytes[cursor] === 0x09)) {
        cursor++;
      }
      let value = 0;
      let digits = 0;
      while (cursor < bytes.length && bytes[cursor] >= 0x30 && bytes[cursor] <= 0x39) {
        value = value * 10 + (bytes[cursor] - 0x30);
        digits++;
        cursor++;
      }
      if (digits > 0 && digits < 10) {
        ids.push(value);
      }
      from = cursor;
    }
  }

  private static ascii(text: string): number[] {
    const out: number[] = [];
    for (let index = 0; index < text.length; index++) {
      out.push(text.charCodeAt(index) & 0xff);
    }
    return out;
  }

  private static indexOf(bytes: Uint8Array, pattern: number[], from: number): number {
    if (pattern.length === 0 || from >= bytes.length) {
      return -1;
    }
    for (let start = Math.max(0, from); start <= bytes.length - pattern.length; start++) {
      let matched = true;
      for (let index = 0; index < pattern.length; index++) {
        if (bytes[start + index] !== pattern[index]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return start;
      }
    }
    return -1;
  }

  async outputPathFor(uri: string): Promise<string> {
    const resolved: ResolvedPdfSource = await this.resolveReadablePath(uri);
    if (resolved.copyPath.length > 0) {
      await this.tempFiles.remove(resolved.copyPath);
    }
    return resolved.path;
  }

  createOutputPath(): string {
    return this.tempFiles.createPath('pdf');
  }

  outputUri(path: string): string {
    // App-scoped file URI form that both fileIo and the share panel resolve.
    return fileUri.getUriFromPath(path);
  }

  private async resolveReadablePath(uri: string): Promise<ResolvedPdfSource> {
    const resolved: ResolvedPdfSource = new ResolvedPdfSource();
    // Every path handed to PDF Kit must be ASCII: loadDocument fails on
    // non-ASCII display names (self-shared copies keep the original name), so
    // sandbox URIs are copied to an ASCII-named file like every other source.
    // No raw-path shortcut — the display name would reach PDF Kit untouched.
    if (uri.startsWith('file://')) {
      const candidate: string = uri.substring('file://'.length);
      const markerIndex: number = candidate.indexOf(this.tempFiles.sandboxDir());
      if (markerIndex >= 0) {
        resolved.sourceName = candidate.substring(markerIndex)
          .substring(candidate.substring(markerIndex).lastIndexOf('/') + 1);
      }
    }
    // Picker/share URIs (file://docs/..., datashare://, file://media/...) are
    // copied into the sandbox read-only so PDF Kit, which needs a plain path,
    // never touches the original and can only resolve the temporary grant
    // through fileIo's URI routing.
    const copyPath: string = this.tempFiles.createPath('pdfsrc');
    let source: fileIo.File | undefined = undefined;
    let target: fileIo.File | undefined = undefined;
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      try { resolved.sourceName = source.name; } catch (_) {}
      target = await fileIo.open(copyPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await fileIo.copyFile(source.fd, target.fd);
    } catch (_) {
      await this.tempFiles.remove(copyPath);
      throw new Error('Unable to read the shared PDF.');
    } finally {
      if (source !== undefined) {
        try { fileIo.closeSync(source); } catch (_) {}
      }
      if (target !== undefined) {
        try { fileIo.closeSync(target); } catch (_) {}
      }
    }
    resolved.path = copyPath;
    resolved.copyPath = copyPath;
    return resolved;
  }

  /**
   * Renders page 1 for the watermark preview. Read-only; the caller owns and
   * releases the returned pixelmap.
   */
  async renderFirstPage(uri: string): Promise<image.PixelMap | undefined> {
    let resolved: ResolvedPdfSource | undefined = undefined;
    const document: pdfService.PdfDocument = new pdfService.PdfDocument();
    try {
      resolved = await this.resolveReadablePath(uri);
      if (document.loadDocument(resolved.path) !== pdfService.ParseResult.PARSE_SUCCESS) {
        return undefined;
      }
      if (document.getPageCount() <= 0) {
        return undefined;
      }
      return document.getPage(0).getPagePixelMap();
    } catch (_) {
      return undefined;
    } finally {
      try { document.releaseDocument(); } catch (_) {}
      if (resolved !== undefined && resolved.copyPath.length > 0) {
        await this.tempFiles.remove(resolved.copyPath);
      }
    }
  }

  private pushFinding(findings: PrivacyFinding[], subtype: string, risk: RiskLevel, title: string,
    description: string, value: string): void {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) return;
    const finding = new PrivacyFinding(`doc-${subtype}`, subtype, risk, title, description,
      '建议清除', true, trimmed.slice(0, 200));
    finding.category = FindingCategory.METADATA;
    findings.push(finding);
  }

  private pushDateFinding(findings: PrivacyFinding[], subtype: string, risk: RiskLevel, title: string,
    description: string, date: Date): void {
    if (date === undefined || date === null || Number.isNaN(date.getTime())) return;
    this.pushFinding(findings, subtype, risk, title, description, date.toISOString());
  }
}

class InfoEdit {
  key: string;
  value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/**
 * Session-scoped PDF watermark request (审核合规/用途水印). Completely
 * separate from the photo watermark settings; applied by PDF Kit itself
 * during the rebuild, so the watermark is part of the verified copy.
 */
export class PdfWatermarkOptions {
  text: string = '';
  opacity: number = 0.22;
  rotation: number = -24;
  textSize: number = 48;
  darkText: boolean = false;

  constructor(text: string) {
    this.text = text;
  }

  static valid(request: PdfWatermarkOptions | undefined): boolean {
    return request !== undefined && request.text.trim().length > 0;
  }
}

export class PdfSanitizeOutcome {
  outputPath: string = '';
  verification: PrivacyScanResult = new PrivacyScanResult('', []);
}
