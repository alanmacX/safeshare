import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RiskLevel } from '../models/PrivacyModels';
import { MetadataPolicy, MetadataReplacement } from '../metadata/MetadataPolicy';
import { TempFileManager } from '../storage/TempFileManager';
import { FileKind } from './FileTypeRouter';
import { ZipContainer, ZipEntry } from '../metadata/ZipContainer';

/**
 * Diagnostic log helper. Never logs URIs, file names, or any user content —
 * only failure stages and numeric/enum facts.
 */
function logStage(stage: string, detail: string = ''): void {
  // User-free diagnostics only: fixed stage names and numeric/enum facts.
  hilog.info(0x8801, 'SafeShareDoc', `stage=${stage}${detail.length > 0 ? ` ${detail}` : ''}`);
}

/**
 * Dedicated privacy tool for one OOXML family (Word / Excel / PowerPoint).
 * Reads and rewrites only the document-properties parts inside the ZIP
 * container; every other entry is copied byte-for-byte. Findings and copy
 * wording are specific to the office family — never a generic metadata bag.
 */

const CORE_PROPERTIES: string = 'docProps/core.xml';
const APP_PROPERTIES: string = 'docProps/app.xml';
const CUSTOM_PROPERTIES: string = 'docProps/custom.xml';

class CorePropertyDefinition {
  tag: string;
  subtype: string;
  risk: RiskLevel;
  title: string;
  description: string;

  constructor(tag: string, subtype: string, risk: RiskLevel, title: string, description: string) {
    this.tag = tag;
    this.subtype = subtype;
    this.risk = risk;
    this.title = title;
    this.description = description;
  }
}

// dc: creator/description/subject/title, cp: lastModifiedBy/keywords,
// dcterms: created/modified. Only identity-relevant fields are findings.
const CORE_DEFINITIONS: CorePropertyDefinition[] = [
  new CorePropertyDefinition('dc:creator', 'DOCX_AUTHOR', RiskLevel.HIGH, '包含文档作者',
    '作者字段通常记录真实姓名或账号。'),
  new CorePropertyDefinition('cp:lastModifiedBy', 'DOCX_LAST_MODIFIED_BY', RiskLevel.HIGH,
    '包含最后修改者', '修改者字段通常记录真实姓名或账号。'),
  new CorePropertyDefinition('dc:subject', 'DOCX_SUBJECT', RiskLevel.MEDIUM, '包含文档主题',
    '主题可能描述工作内容或项目。'),
  new CorePropertyDefinition('dc:title', 'DOCX_TITLE', RiskLevel.LOW, '包含文档标题',
    '标题可能描述文件内容或项目。'),
  new CorePropertyDefinition('dc:description', 'DOCX_DESCRIPTION', RiskLevel.MEDIUM,
    '包含文档备注', '备注可能包含背景、人名或事务信息。'),
  new CorePropertyDefinition('cp:keywords', 'DOCX_KEYWORDS', RiskLevel.MEDIUM, '包含文档关键词',
    '关键词可能包含人名、客户名或项目代号。'),
  new CorePropertyDefinition('dcterms:created', 'DOCX_CREATE_TIME', RiskLevel.LOW, '包含创建时间',
    '创建时间可能暴露工作规律。'),
  new CorePropertyDefinition('dcterms:modified', 'DOCX_MODIFY_TIME', RiskLevel.LOW, '包含修改时间',
    '修改时间可能暴露近期活动。')
];

const APP_DEFINITION_SUBTYPES: string[] = ['DOCX_COMPANY', 'DOCX_MANAGER', 'DOCX_HYPERLINK_BASE'];

export class OoxmlFamilyTool {
  readonly kind: FileKind;
  readonly familyLabel: string;
  private tempFiles: TempFileManager;
  private sourceName: string = '';

  constructor(kind: FileKind, familyLabel: string, context: common.UIAbilityContext) {
    this.kind = kind;
    this.familyLabel = familyLabel;
    this.tempFiles = new TempFileManager(context);
  }

  async scan(uri: string): Promise<PrivacyScanResult> {
    let bytes: Uint8Array;
    try {
      bytes = await this.readSourceBytes(uri);
    } catch (_) {
      logStage('read_source_failed');
      throw new Error('Unable to read document for scan.');
    }
    const result: PrivacyScanResult = await this.scanBytes(bytes);
    result.uri = uri;
    return result;
  }

  private async scanBytes(bytes: Uint8Array): Promise<PrivacyScanResult> {
    let entries: ZipEntry[];
    try {
      entries = ZipContainer.readEntries(bytes);
    } catch (_) {
      logStage('parse_zip_failed', `size=${bytes.length}`);
      if (this.isLegacyOfficeBytes(bytes)) {
        // Legacy binary Office containers cannot be cleaned by the OOXML
        // property rewriter; surface that distinctly instead of a generic
        // parse failure.
        throw new Error('LEGACY_OFFICE_FORMAT');
      }
      throw new Error('Unable to parse document container.');
    }
    logStage('entries', `count=${entries.length}`);
    const findings: PrivacyFinding[] = [];
    const coreIndex: number = this.indexOfEntry(entries, CORE_PROPERTIES);
    if (coreIndex >= 0) {
      const xml: string = await this.entryXml(entries[coreIndex], bytes);
      this.collectCoreFindings(findings, xml);
    }
    const appIndex: number = this.indexOfEntry(entries, APP_PROPERTIES);
    if (appIndex >= 0) {
      const xml: string = await this.entryXml(entries[appIndex], bytes);
      this.collectAppFindings(findings, xml);
    }
    const customIndex: number = this.indexOfEntry(entries, CUSTOM_PROPERTIES);
    if (customIndex >= 0) {
      const xml: string = await this.entryXml(entries[customIndex], bytes);
      this.collectCustomFindings(findings, xml);
    }
    return new PrivacyScanResult('', findings);
  }

  /**
   * Produces the sanitized copy by rewriting only document-properties parts.
   * The verification scan runs on the written copy and must return zero
   * findings (fail closed), otherwise the output is deleted.
   */
  async sanitize(uri: string, policy: MetadataPolicy = new MetadataPolicy()):
    Promise<OoxmlSanitizeOutcome> {
    const bytes: Uint8Array = await this.readSourceBytes(uri);
    const entries: ZipEntry[] = ZipContainer.readEntries(bytes);
    const rewritten: Map<string, Uint8Array> = new Map();
    // Findings the user kept in the result page arrive as preserveSubtypes;
    // those properties must survive into the sanitized copy.
    const preserved: string[] = policy.preserveSubtypes;

    const coreIndex: number = this.indexOfEntry(entries, CORE_PROPERTIES);
    if (coreIndex >= 0) {
      const xml: string = await this.entryXml(entries[coreIndex], bytes);
      const cleaned: string = this.rewriteCoreProperties(xml, preserved, policy.replacements);
      if (cleaned.length > 0) {
        rewritten.set(CORE_PROPERTIES, this.encodeUtf8(cleaned));
      }
    }
    const appIndex: number = this.indexOfEntry(entries, APP_PROPERTIES);
    if (appIndex >= 0) {
      const xml: string = await this.entryXml(entries[appIndex], bytes);
      const cleaned: string = this.rewriteAppProperties(xml, preserved, policy.replacements);
      if (cleaned.length > 0) {
        rewritten.set(APP_PROPERTIES, this.encodeUtf8(cleaned));
      }
    }
    const customIndex: number = this.indexOfEntry(entries, CUSTOM_PROPERTIES);
    if (customIndex >= 0 && preserved.indexOf('DOCX_CUSTOM_PROPS') < 0) {
      rewritten.set(CUSTOM_PROPERTIES, this.encodeUtf8(this.emptyCustomProperties()));
    }

    // Nothing selected for removal/replacement (user kept every finding):
    // still produce the copy as a byte-faithful container rebuild so one
    // fully-kept document never fails an otherwise valid batch.
    const outputBytes: Uint8Array = ZipContainer.assemble(bytes, entries, rewritten);
    const outputPath: string = this.tempFiles.createOutputPath(
      this.sourceName.length > 0 ? this.sourceName : uri, this.extensionForKind());
    let verification: PrivacyScanResult;
    try {
      await ZipContainer.writeFileBytes(outputPath, outputBytes);
      // Verify by reading the bytes we own directly — no URI round-trip, so
      // verification cannot fail on URI form differences. Only removed
      // subtypes must be gone; preserved properties are expected findings.
      verification = await this.scanBytes(outputBytes);
      let leaked = 0;
      for (let index = 0; index < verification.findings.length; index++) {
        const finding: PrivacyFinding = verification.findings[index];
        const replacement: string | undefined = this.replacementFor(policy.replacements, finding.subtype);
        if (preserved.indexOf(finding.subtype) < 0 &&
          (replacement === undefined || finding.rawValue !== replacement)) leaked++;
      }
      logStage('verify', `total=${verification.findings.length} leaked=${leaked}`);
      if (leaked > 0) {
        throw new Error('Sanitized document properties verification failed.');
      }
    } catch (error) {
      // Fail closed: a thrown verification must never leave a partial copy behind.
      await this.tempFiles.remove(outputPath);
      throw error as Error;
    }
    logStage('docx_sanitize_ok', `out=${outputPath.length > 0 ? 1 : 0}`);
    const outcome: OoxmlSanitizeOutcome = {
      outputPath: outputPath,
      verification: verification
    };
    return outcome;
  }

  private extensionForKind(): string {
    if (this.kind === FileKind.EXCEL) return 'xlsx';
    if (this.kind === FileKind.POWERPOINT) return 'pptx';
    return 'docx';
  }

  private async readSourceBytes(uri: string): Promise<Uint8Array> {
    // Always copy through fileIo's URI routing into an ASCII-named sandbox
    // file. The old raw-path shortcut for file:// sandbox URIs broke on
    // devices/emulators whose sandbox path forms differ (Word self-share
    // failed with read_source_failed); fileIo resolves every URI form the
    // same way, and the display name only survives through source.name.
    const copyPath: string = this.tempFiles.createPath('src');
    let source: fileIo.File | undefined = undefined;
    let target: fileIo.File | undefined = undefined;
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      try { this.sourceName = source.name; } catch (_) { this.sourceName = ''; }
      target = await fileIo.open(copyPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await fileIo.copyFile(source.fd, target.fd);
    } catch (error) {
      logStage('copy_granted_uri', `err=${((error as BusinessError).code ?? 0)}`);
      await this.tempFiles.remove(copyPath);
      throw new Error(`Unable to read the shared ${this.familyLabel}.`);
    } finally {
      if (source !== undefined) {
        try { fileIo.closeSync(source); } catch (_) {
        }
      }
      if (target !== undefined) {
        try { fileIo.closeSync(target); } catch (_) {
        }
      }
    }
    try {
      return await ZipContainer.readFileBytes(copyPath);
    } finally {
      await this.tempFiles.remove(copyPath);
    }
  }

  private isLegacyOfficeBytes(bytes: Uint8Array): boolean {
    return bytes.length >= 8 && bytes[0] === 0xD0 && bytes[1] === 0xCF &&
      bytes[2] === 0x11 && bytes[3] === 0xE0 && bytes[4] === 0xA1 &&
      bytes[5] === 0xB1 && bytes[6] === 0x1A && bytes[7] === 0xE1;
  }

  private indexOfEntry(entries: ZipEntry[], name: string): number {
    for (let index: number = 0; index < entries.length; index++) {
      if (entries[index].name === name) {
        return index;
      }
    }
    return -1;
  }

  private async entryXml(entry: ZipEntry, bytes: Uint8Array): Promise<string> {
    return this.decodeUtf8(await this.entryBytes(entry, bytes));
  }

  private async entryBytes(entry: ZipEntry, bytes: Uint8Array): Promise<Uint8Array> {
    const raw: Uint8Array = bytes.subarray(entry.dataOffset,
      entry.dataOffset + entry.compressedSize);
    let plain: Uint8Array;
    if (entry.method === 0) {
      plain = new Uint8Array(raw);
    } else if (entry.method === 8) {
      try {
        plain = await ZipContainer.inflateRaw(raw, entry.uncompressedSize);
      } catch (_) {
        logStage('inflate_failed', `method=8 csize=${entry.compressedSize}`);
        throw new Error('Deflate decompression failed.');
      }
    } else {
      logStage('unsupported_method', `method=${entry.method}`);
      throw new Error('Unsupported ZIP compression method.');
    }
    // Fail closed on any data corruption: the decompressed bytes must match
    // the CRC the ZIP container declared for this entry.
    if (ZipContainer.crc32(plain) !== entry.crc32) {
      logStage('crc_mismatch', `entry=${entry.name.length}usize=${plain.length}`);
      throw new Error('Entry CRC mismatch after decompression.');
    }
    return plain;
  }

  private collectCoreFindings(findings: PrivacyFinding[], xml: string): void {
    for (let index: number = 0; index < CORE_DEFINITIONS.length; index++) {
      const definition: CorePropertyDefinition = CORE_DEFINITIONS[index];
      const value: string = this.extractTagValue(xml, definition.tag);
      if (value.length === 0) continue;
      const finding = new PrivacyFinding(`ooxml-${definition.subtype}`, definition.subtype,
        definition.risk, definition.title, definition.description, '建议清除', true,
        value.slice(0, 200));
      finding.category = FindingCategory.METADATA;
      findings.push(finding);
    }
  }

  private collectAppFindings(findings: PrivacyFinding[], xml: string): void {
    const company: string = this.extractTagValue(xml, 'Company');
    if (company.length > 0) {
      const finding = new PrivacyFinding('ooxml-DOCX_COMPANY', 'DOCX_COMPANY', RiskLevel.HIGH,
        '包含公司名称', '公司字段直接暴露所属组织。', '建议清除', true, company.slice(0, 200));
      finding.category = FindingCategory.METADATA;
      findings.push(finding);
    }
    const manager: string = this.extractTagValue(xml, 'Manager');
    if (manager.length > 0) {
      const finding = new PrivacyFinding('ooxml-DOCX_MANAGER', 'DOCX_MANAGER', RiskLevel.HIGH,
        '包含经理姓名', '经理字段可能直接暴露姓名。', '建议清除', true, manager.slice(0, 200));
      finding.category = FindingCategory.METADATA;
      findings.push(finding);
    }
    const hyperlinkBase: string = this.extractTagValue(xml, 'HyperlinkBase');
    if (hyperlinkBase.length > 0) {
      const finding = new PrivacyFinding('ooxml-DOCX_HYPERLINK_BASE', 'DOCX_HYPERLINK_BASE',
        RiskLevel.MEDIUM, '包含内部链接基址', '链接基址可能暴露内部系统地址。',
        '建议清除', true, hyperlinkBase.slice(0, 200));
      finding.category = FindingCategory.METADATA;
      findings.push(finding);
    }
  }

  private collectCustomFindings(findings: PrivacyFinding[], xml: string): void {
    const names: string[] = this.extractCustomPropertyNames(xml);
    if (names.length === 0) return;
    const finding = new PrivacyFinding('ooxml-DOCX_CUSTOM_PROPS', 'DOCX_CUSTOM_PROPS',
      RiskLevel.MEDIUM, `包含 ${names.length} 项自定义属性`, '自定义属性可能记录部门、模板或业务系统信息。',
      '建议清除', true, names.slice(0, 6).join('、').slice(0, 200));
    finding.category = FindingCategory.METADATA;
    findings.push(finding);
  }

  private rewriteCoreProperties(xml: string, preserved: string[], replacements: MetadataReplacement[]): string {
    let result: string = xml;
    for (let index: number = 0; index < CORE_DEFINITIONS.length; index++) {
      const definition: CorePropertyDefinition = CORE_DEFINITIONS[index];
      const replacement: string | undefined = this.replacementFor(replacements, definition.subtype);
      if (replacement !== undefined) {
        result = this.replaceTagContent(result, definition.tag, replacement);
        continue;
      }
      if (preserved.indexOf(definition.subtype) >= 0) continue;
      result = this.removeTagContent(result, definition.tag);
    }
    return result;
  }

  private rewriteAppProperties(xml: string, preserved: string[], replacements: MetadataReplacement[]): string {
    let result: string = xml;
    const appFields: string[][] = [
      ['DOCX_COMPANY', 'Company'], ['DOCX_MANAGER', 'Manager'],
      ['DOCX_HYPERLINK_BASE', 'HyperlinkBase']
    ];
    for (let index: number = 0; index < appFields.length; index++) {
      const subtype: string = appFields[index][0];
      const tag: string = appFields[index][1];
      const replacement: string | undefined = this.replacementFor(replacements, subtype);
      if (replacement !== undefined) {
        result = this.replaceTagContent(result, tag, replacement);
      } else if (preserved.indexOf(subtype) < 0) {
        result = this.removeTagContent(result, tag);
      }
    }
    return result;
  }

  private replacementFor(replacements: MetadataReplacement[], subtype: string): string | undefined {
    for (let index: number = 0; index < replacements.length; index++) {
      if (replacements[index].subtype === subtype && replacements[index].value.length > 0) {
        return replacements[index].value;
      }
    }
    return undefined;
  }

  private replaceTagContent(xml: string, tag: string, value: string): string {
    const pattern: RegExp = new RegExp(`(<(?:[A-Za-z0-9]+:)?${tag}(?:\\s[^>]*)?>)([\\s\\S]*?)(</(?:[A-Za-z0-9]+:)?${tag}>)`, 'g');
    return xml.replace(pattern, `$1${this.encodeXmlEntities(value)}$3`);
  }

  /**
   * Removes the value text of a namespaced tag while keeping the element so
   * the XML schema of the document stays valid for Word/Excel/PowerPoint.
   */
  private removeTagContent(xml: string, tag: string): string {
    const openPattern: RegExp = new RegExp(`(<(?:[A-Za-z0-9]+:)?${tag}(?:\\s[^>]*)?>)([\\s\\S]*?)(</(?:[A-Za-z0-9]+:)?${tag}>)`, 'g');
    return xml.replace(openPattern, '$1$3');
  }

  private extractTagValue(xml: string, tag: string): string {
    const pattern: RegExp = new RegExp(`<(?:[A-Za-z0-9]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9]+:)?${tag}>`, 'g');
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      if (match.length >= 2) {
        const value: string = this.decodeXmlEntities(match[1].trim());
        if (value.length > 0) return value;
      }
      match = pattern.exec(xml);
    }
    return '';
  }

  private extractCustomPropertyNames(xml: string): string[] {
    const names: string[] = [];
    const pattern: RegExp = /<property[^>]*name="([^"]*)"[^>]*>/g;
    let match: RegExpMatchArray | null = xml.match(pattern);
    if (match === null) return names;
    for (let index: number = 0; index < match.length; index++) {
      const nameMatch: RegExpMatchArray | null = match[index].match(/name="([^"]*)"/);
      if (nameMatch !== null && nameMatch[1].length > 0) {
        names.push(nameMatch[1]);
      }
    }
    return names;
  }

  private emptyCustomProperties(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n' +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" ' +
      'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"></Properties>';
  }

  private decodeXmlEntities(value: string): string {
    return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&apos;/g, '\'').replace(/&amp;/g, '&');
  }

  private encodeXmlEntities(value: string): string {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  private decodeUtf8(raw: Uint8Array): string {
    let result: string = '';
    let index: number = 0;
    while (index < raw.length) {
      const byte: number = raw[index];
      if (byte < 0x80) {
        result += String.fromCharCode(byte);
        index += 1;
      } else if (byte < 0xe0 && index + 1 < raw.length) {
        result += String.fromCharCode(((byte & 0x1f) << 6) | (raw[index + 1] & 0x3f));
        index += 2;
      } else if (byte < 0xf0 && index + 2 < raw.length) {
        result += String.fromCharCode(((byte & 0x0f) << 12) |
          ((raw[index + 1] & 0x3f) << 6) | (raw[index + 2] & 0x3f));
        index += 3;
      } else if (index + 3 < raw.length) {
        // Four-byte sequence: emit a real surrogate pair so code points above
        // BMP (emoji, rare CJK) survive decode/re-encode round-trips.
        const codePoint: number = ((byte & 0x07) << 18) | ((raw[index + 1] & 0x3f) << 12) |
          ((raw[index + 2] & 0x3f) << 6) | (raw[index + 3] & 0x3f);
        result += String.fromCharCode(0xd800 + ((codePoint - 0x10000) >> 10),
          0xdc00 + ((codePoint - 0x10000) & 0x3ff));
        index += 4;
      } else {
        // Truncated sequence at end of input: stop rather than read out of bounds.
        index = raw.length;
      }
    }
    return result;
  }

  private encodeUtf8(value: string): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(value.length * 3);
    let length: number = 0;
    for (let index: number = 0; index < value.length; index++) {
      const code: number = value.charCodeAt(index);
      if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
        // Surrogate pair: recombine into the code point and emit four bytes.
        const low: number = value.charCodeAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          const codePoint: number = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
          bytes[length++] = 0xf0 | (codePoint >> 18);
          bytes[length++] = 0x80 | ((codePoint >> 12) & 0x3f);
          bytes[length++] = 0x80 | ((codePoint >> 6) & 0x3f);
          bytes[length++] = 0x80 | (codePoint & 0x3f);
          index++;
          continue;
        }
      }
      if (code < 0x80) {
        bytes[length++] = code;
      } else if (code < 0x800) {
        bytes[length++] = 0xc0 | (code >> 6);
        bytes[length++] = 0x80 | (code & 0x3f);
      } else {
        bytes[length++] = 0xe0 | (code >> 12);
        bytes[length++] = 0x80 | ((code >> 6) & 0x3f);
        bytes[length++] = 0x80 | (code & 0x3f);
      }
    }
    return bytes.subarray(0, length);
  }
}

export class OoxmlSanitizeOutcome {
  outputPath: string = '';
  verification: PrivacyScanResult = new PrivacyScanResult('', []);
}
