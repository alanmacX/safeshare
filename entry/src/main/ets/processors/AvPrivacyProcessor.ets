import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RiskLevel, SanitizedFile } from '../models/PrivacyModels';
import { TempFileManager } from '../storage/TempFileManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileTypeRouter } from './FileTypeRouter';
import { IsoBmffMetadataReader, IsoMetadataItem } from './IsoBmffMetadataReader';
import { NativeMediaRemuxer, NativeRemuxResult } from './NativeMediaRemuxer';

/**
 * Privacy checker for audio/video containers. Video cleanup uses a native
 * demux/remux pipeline and then verifies the generated sandbox copy. M4A uses
 * the same encoded-track copy path; other audio containers stay scan-only.
 */
export class AvPrivacyTool {
  private tempFiles: TempFileManager;

  constructor(context: common.UIAbilityContext) {
    this.tempFiles = new TempFileManager(context);
  }

  async scan(uri: string): Promise<PrivacyScanResult> {
    // The platform owns its descriptor after fdSrc is set. Keep container
    // fallback reads on a separate descriptor so its seek position and I/O
    // never interfere with AVMetadataExtractor.
    const containerSource: fileIo.File = await this.openReadOnly(uri);
    let extractorSource: fileIo.File | undefined = undefined;
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    const findings: PrivacyFinding[] = [];
    const warnings: string[] = [];
    let containerMetadata: IsoMetadataItem[] = [];
    let detectedMimeType: string = '';
    let byteLength: number = 0;
    let containerReadable: boolean = false;
    let videoContent: boolean = FileTypeRouter.isVideoUri(uri);
    let pixelWidth: number = 0;
    let pixelHeight: number = 0;
    try {
      extractorSource = await this.openReadOnly(uri);
      extractor = await media.createAVMetadataExtractor();
      // AVFileDescriptor describes a continuous byte range. Passing -1 is
      // rejected by some system extractors (notably for QuickTime/MOV), even
      // when the container itself is otherwise supported.
      byteLength = fileIo.statSync(containerSource.fd).size;
      if (byteLength <= 0) {
        warnings.push('这个音视频文件为空，无法读取元数据');
        return this.result(uri, findings, warnings);
      }
      // Some Huawei Camera files keep useful fields in ISO-BMFF boxes that
      // AVMetadataExtractor does not promote to AVMetadata. Read only moov —
      // never mdat — before asking the platform for its richer media view.
      containerMetadata = IsoBmffMetadataReader.read(containerSource.fd, byteLength);
      containerReadable = IsoBmffMetadataReader.isReadableContainer(containerSource.fd, byteLength);
      const containerMimeType: string = IsoBmffMetadataReader.containerMimeType(containerSource.fd, byteLength);
      if (containerMimeType.length > 0) detectedMimeType = containerMimeType;
      extractor.fdSrc = { fd: extractorSource.fd, offset: 0, length: byteLength };
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
      if (metadata.mimeType !== undefined && metadata.mimeType.length > 0) {
        detectedMimeType = metadata.mimeType;
      }
      videoContent = this.containsVideo(metadata, uri);
      pixelWidth = this.positiveInt(metadata.videoWidth);
      pixelHeight = this.positiveInt(metadata.videoHeight);
      if (metadata.location !== undefined) {
        const finding = new PrivacyFinding('av-LOCATION', 'AV_LOCATION', RiskLevel.HIGH,
          '包含拍摄/录制位置', '媒体文件记录了精确经纬度，接收方可直接读取。',
          '生成副本时删除', true,
          `${metadata.location.latitude.toFixed(5)}, ${metadata.location.longitude.toFixed(5)}`);
        finding.category = FindingCategory.METADATA;
        findings.push(finding);
      }
      const recordedAt: string | undefined = this.firstValue(metadata.dateTimeFormat, metadata.dateTime);
      if (recordedAt !== undefined) {
        const finding = new PrivacyFinding('av-DATETIME', 'AV_DATETIME', RiskLevel.MEDIUM,
          '包含录制时间', '录制时间可能暴露活动规律。', '生成副本时删除', true,
          recordedAt.slice(0, 60));
        finding.category = FindingCategory.METADATA;
        findings.push(finding);
      }
      this.pushIfPresent(findings, 'AV_AUTHOR', RiskLevel.MEDIUM, '包含作者信息',
        '作者字段可能包含姓名。', metadata.author);
      this.pushIfPresent(findings, 'AV_ARTIST', RiskLevel.LOW, '包含艺术家信息',
        '艺术家字段可能包含姓名。', metadata.artist);
      this.pushIfPresent(findings, 'AV_COMPOSER', RiskLevel.LOW, '包含作曲者信息',
        '作曲者字段可能包含姓名。', metadata.composer);
      this.pushIfPresent(findings, 'AV_ALBUM_ARTIST', RiskLevel.LOW, '包含专辑艺术家',
        '专辑艺术家字段可能包含姓名。', metadata.albumArtist);
      this.pushIfPresent(findings, 'AV_TITLE', RiskLevel.LOW, '包含标题',
        '标题可能描述内容或场景。', metadata.title);
      this.pushIfPresent(findings, 'AV_DESCRIPTION', RiskLevel.MEDIUM, '包含描述',
        '描述可能包含地点、姓名或事务信息。', metadata.description);
      this.pushIfPresent(findings, 'AV_GENRE', RiskLevel.LOW, '包含流派',
        '流派信息可能反映个人偏好。', metadata.genre);
      // Huawei Camera and other native recorders commonly store identity and
      // location fields in moov.meta.list instead of the small set of standard
      // AVMetadata properties. API 24 exposes those entries through
      // customInfo; ignoring it made valid Huawei-shot videos look empty.
      this.collectCustomInfo(findings, metadata.customInfo);
      // Prefer normalized platform properties. Container fields fill only the
      // gaps left by AVMetadataExtractor and preserve support for QuickTime
      // keys that the device does not promote.
      this.collectIsoMetadata(findings, containerMetadata);

    } catch (error) {
      // The bounded moov reader is independent of codec support, so retain
      // its findings even when the platform extractor or thumbnail fails.
      this.collectIsoMetadata(findings, containerMetadata);
      const code: number = (error as BusinessError).code;
      if (findings.length > 0 || containerReadable) {
        // The container fallback succeeded. Platform codec/preview failure
        // must not erase metadata that was already read. A readable, clean
        // ISO container is also a completed container scan even when the
        // higher-level extractor exposes no optional metadata fields.
      } else if (this.isMov(uri) && code === 5400106) {
        warnings.push('已识别为 MOV，但当前设备的系统媒体解析器不支持该文件的容器或编码组合。可换真机检查，或转为 MP4 后重试');
      } else if (code === 5400106) {
        warnings.push('当前设备的系统媒体解析器不支持这个音视频文件的容器或编码组合');
      } else if (this.isMov(uri)) {
        warnings.push('已识别为 MOV，但当前设备未能读取其容器元数据。文件可能未完整写入，也可能使用了当前设备不支持的编码组合');
      } else {
        warnings.push('当前设备未能读取该音视频文件的容器元数据');
      }
    } finally {
      try {
        if (extractor !== undefined) await extractor.release();
      } catch (_) {
      }
      try {
        fileIo.closeSync(containerSource);
      } catch (_) {
      }
      try {
        if (extractorSource !== undefined) fileIo.closeSync(extractorSource);
      } catch (_) {
      }
    }
    const result: PrivacyScanResult = this.result(uri, findings, warnings,
      videoContent || detectedMimeType.startsWith('video/'), detectedMimeType === 'audio/mp4');
    result.mimeType = detectedMimeType;
    result.pixelWidth = pixelWidth;
    result.pixelHeight = pixelHeight;
    // Thumbnail extraction is independent of metadata extraction. Previously
    // one extractor exception skipped AVImageGenerator entirely, producing a
    // blank preview even for a playable, metadata-clean output.
    if (videoContent && byteLength > 0) {
      try {
        result.previewPixelMap = await this.fetchVideoPreview(uri, byteLength);
      } catch (_) {
        // System Preview remains available; absence of a thumbnail does not
        // make a successful container scan fail.
      }
    }
    return result;
  }

  /**
   * Produces a new MP4 by copying encoded tracks only. Source-level container
   * metadata is deliberately not passed to AVMuxer. The source stays read-only
   * and the generated sandbox file is scanned again before it is returned.
   */
  async sanitize(uri: string): Promise<SanitizedFile> {
    let outputPath: string = '';
    let input: fileIo.File | undefined = undefined;
    let output: fileIo.File | undefined = undefined;
    try {
      input = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const inputLength: number = fileIo.statSync(input.fd).size;
      if (inputLength <= 0) throw new Error('EMPTY_MEDIA');
      let sourceName: string = uri;
      try { sourceName = input.name; } catch (_) {}
      const containerMimeType: string = IsoBmffMetadataReader.containerMimeType(input.fd, inputLength);
      const audioOnly: boolean = this.isM4a(sourceName) || this.isM4a(uri) ||
        containerMimeType === 'audio/mp4';
      outputPath = this.tempFiles.createOutputPath(sourceName, audioOnly ? 'm4a' : 'mp4');
      output = await fileIo.open(outputPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const nativeResult: NativeRemuxResult = await NativeMediaRemuxer.remuxToMp4(input, inputLength, output);
      if (nativeResult.trackCount <= 0 || nativeResult.sampleCount <= 0 ||
        (audioOnly ? nativeResult.videoTrackCount !== 0 : nativeResult.videoTrackCount <= 0)) {
        throw new Error('EMPTY_REMUX');
      }
      fileIo.closeSync(output);
      output = undefined;
      fileIo.closeSync(input);
      input = undefined;
      const outputUri: string = fileUri.getUriFromPath(outputPath);
      const verification: PrivacyScanResult = await this.scan(outputUri);
      if (verification.findings.length > 0) {
        throw new Error('METADATA_REMAINS');
      }
      const sanitized = new SanitizedFile(outputPath, outputUri, verification,
        audioOnly ? 'general.mpeg-4-audio' : 'general.mpeg-4',
        audioOnly ? 'audio/mp4' : 'video/mp4');
      sanitized.fileKind = 'AUDIO_VIDEO';
      sanitized.byteSize = fileIo.statSync(outputPath).size;
      return sanitized;
    } catch (error) {
      if (outputPath.length > 0) await this.tempFiles.remove(outputPath);
      const stage: string = (error as Error).message;
      // Only fixed native stage codes are propagated; never include a URI,
      // file name, or detected metadata value.
      const prefix: string = this.isM4a(uri) ? 'AUDIO_' : 'VIDEO_';
      throw new Error(stage.startsWith(prefix) ? stage : `${prefix}${stage}`);
    } finally {
      try { if (output !== undefined) fileIo.closeSync(output); } catch (_) {}
      try { if (input !== undefined) fileIo.closeSync(input); } catch (_) {}
    }
  }

  private containsVideo(metadata: media.AVMetadata, uri: string): boolean {
    return metadata.hasVideo === 'yes' || metadata.hasVideo === 'true' ||
      metadata.videoWidth !== undefined || FileTypeRouter.isVideoUri(uri);
  }

  private async fetchVideoPreview(uri: string, byteLength: number): Promise<image.PixelMap> {
    // AVImageGenerator is the system's dedicated thumbnail API. Keep it on a
    // third descriptor: HarmonyOS explicitly forbids sharing an fd between
    // AVMetadataExtractor and AVImageGenerator.
    const source: fileIo.File = await this.openReadOnly(uri);
    let generator: media.AVImageGenerator | undefined = undefined;
    try {
      generator = await media.createAVImageGenerator();
      generator.fdSrc = { fd: source.fd, offset: 0, length: byteLength };
      const params: media.PixelMapParams = { width: 720, height: 720 };
      return await generator.fetchFrameByTime(0,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, params);
    } finally {
      try { if (generator !== undefined) await generator.release(); } catch (_) {}
      try { fileIo.closeSync(source); } catch (_) {}
    }
  }

  private positiveInt(value: string | undefined): number {
    if (value === undefined) return 0;
    const parsed: number = Number.parseInt(value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  }

  private firstValue(first: string | undefined, second: string | undefined): string | undefined {
    if (first !== undefined && first.trim().length > 0) return first;
    if (second !== undefined && second.trim().length > 0) return second;
    return undefined;
  }

  private collectCustomInfo(findings: PrivacyFinding[], info: Record<string, string> | undefined): void {
    if (info === undefined) return;
    const keys: string[] = Object.keys(info);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const value: string | undefined = info[key];
      if (value === undefined || value.trim().length === 0) continue;
      const normalized: string = key.toLowerCase();
      if (this.hasAny(normalized, ['location', 'latitude', 'longitude', 'gps', 'iso6709'])) {
        this.pushCustom(findings, key, 'AV_CUSTOM_LOCATION', RiskLevel.HIGH,
          '包含录制位置', '视频扩展元数据包含位置或坐标信息。', value);
      } else if (this.hasAny(normalized, ['manufacturer', 'make', 'vendor'])) {
        this.pushCustom(findings, key, 'AV_DEVICE_MAKE', RiskLevel.LOW,
          '包含设备品牌', '扩展元数据记录了拍摄设备品牌。', value);
      } else if (this.hasAny(normalized, ['model', 'device'])) {
        this.pushCustom(findings, key, 'AV_DEVICE_MODEL', RiskLevel.MEDIUM,
          '包含设备型号', '扩展元数据记录了拍摄设备型号。', value);
      } else if (this.hasAny(normalized, ['creation', 'created', 'datetime', 'date', 'time'])) {
        this.pushCustom(findings, key, 'AV_CUSTOM_DATETIME', RiskLevel.MEDIUM,
          '包含录制时间', '视频扩展元数据包含创建或录制时间。', value);
      } else if (this.hasAny(normalized, ['author', 'artist', 'owner', 'copyright'])) {
        this.pushCustom(findings, key, 'AV_CUSTOM_AUTHOR', RiskLevel.MEDIUM,
          '包含署名信息', '视频扩展元数据可能包含姓名或账号。', value);
      } else if (this.hasAny(normalized, ['comment', 'description', 'title'])) {
        this.pushCustom(findings, key, 'AV_CUSTOM_DESCRIPTION', RiskLevel.MEDIUM,
          '包含文字描述', '视频扩展元数据包含标题、备注或描述。', value);
      } else if (this.hasAny(normalized, ['software', 'encoder', 'encoding_tool'])) {
        this.pushCustom(findings, key, 'AV_SOFTWARE', RiskLevel.LOW,
          '包含处理软件', '扩展元数据记录了拍摄、剪辑或编码软件。', value);
      }
    }
  }

  private collectIsoMetadata(findings: PrivacyFinding[], items: IsoMetadataItem[]): void {
    for (let index: number = 0; index < items.length; index++) {
      const item: IsoMetadataItem = items[index];
      const normalized: string = item.key.toLowerCase();
      if (this.hasAny(normalized, ['location.accuracy', 'gps.accuracy'])) {
        this.pushCustom(findings, item.key, 'AV_LOCATION_ACCURACY', RiskLevel.LOW,
          '包含位置精度', '视频容器记录了定位精度。', item.value);
      } else if (this.hasAny(normalized, ['location', 'latitude', 'longitude', 'gps', 'iso6709', '\u00a9xyz'])) {
        this.pushCustom(findings, item.key, 'AV_CUSTOM_LOCATION', RiskLevel.HIGH,
          '包含录制位置', '视频容器记录了位置或坐标信息。', item.value);
      } else if (this.hasAny(normalized, ['manufacturer', 'make', 'vendor', '\u00a9mak'])) {
        this.pushCustom(findings, item.key, 'AV_DEVICE_MAKE', RiskLevel.LOW,
          '包含设备品牌', '视频容器记录了拍摄设备品牌。', item.value);
      } else if (this.hasAny(normalized, ['model', 'device', '\u00a9mod'])) {
        this.pushCustom(findings, item.key, 'AV_DEVICE_MODEL', RiskLevel.MEDIUM,
          '包含设备型号', '视频容器记录了拍摄设备型号。', item.value);
      } else if (this.hasAny(normalized,
        ['creation', 'created', 'datetime', 'date', 'time', '\u00a9day'])) {
        this.pushCustom(findings, item.key, 'AV_CUSTOM_DATETIME', RiskLevel.MEDIUM,
          '包含录制时间', '视频容器记录了创建或录制时间。', item.value);
      } else if (this.hasAny(normalized, ['author', 'artist', 'owner', 'copyright', '\u00a9art'])) {
        this.pushCustom(findings, item.key, 'AV_CUSTOM_AUTHOR', RiskLevel.MEDIUM,
          '包含署名信息', '视频容器可能记录姓名或账号。', item.value);
      } else if (this.hasAny(normalized, ['comment', 'description', 'title', '\u00a9nam', '\u00a9cmt'])) {
        this.pushCustom(findings, item.key, 'AV_CUSTOM_DESCRIPTION', RiskLevel.MEDIUM,
          '包含文字描述', '视频容器记录了标题、备注或描述。', item.value);
      } else if (this.hasAny(normalized, ['software', 'encoder', 'encoding_tool', '\u00a9swr'])) {
        this.pushCustom(findings, item.key, 'AV_SOFTWARE', RiskLevel.LOW,
          '包含处理软件', '视频容器记录了拍摄、剪辑或编码软件。', item.value);
      }
    }
  }

  private hasAny(value: string, needles: string[]): boolean {
    for (let index: number = 0; index < needles.length; index++) {
      if (value.indexOf(needles[index]) >= 0) return true;
    }
    return false;
  }

  private pushCustom(findings: PrivacyFinding[], key: string, subtype: string, risk: RiskLevel,
    title: string, description: string, value: string): void {
    // Avoid showing the same semantic field twice when the extractor also
    // promoted it into a standard AVMetadata property.
    for (let index: number = 0; index < findings.length; index++) {
      if (subtype === 'AV_CUSTOM_LOCATION' && findings[index].subtype === 'AV_LOCATION') return;
      if (subtype === 'AV_CUSTOM_DATETIME' && findings[index].subtype === 'AV_DATETIME') return;
      if (findings[index].subtype === subtype || findings[index].rawValue === value) return;
    }
    const finding = new PrivacyFinding(`av-custom-${key}`, subtype, risk, title, description,
      '生成副本时删除', true, value.slice(0, 200));
    finding.category = FindingCategory.METADATA;
    findings.push(finding);
  }

  private result(uri: string, findings: PrivacyFinding[], warnings: string[], isVideo: boolean = false,
    isM4aContent: boolean = false): PrivacyScanResult {
    const result: PrivacyScanResult = new PrivacyScanResult(uri, findings);
    result.capabilityWarnings = warnings;
    result.scanFailed = findings.length === 0 && warnings.length > 0;
    // ISO-BMFF audio (M4A) can use the same encoded-track copy path. Other
    // audio containers require their own tag/container writers.
    result.readOnlyTool = !isVideo && !isM4aContent && !this.isM4a(uri);
    return result;
  }

  private isMov(uri: string): boolean {
    const normalized: string = uri.toLowerCase();
    return normalized.indexOf('.mov') >= 0 || normalized.indexOf('video/quicktime') >= 0;
  }

  private isM4a(uri: string): boolean {
    const normalized: string = uri.toLowerCase();
    return normalized.indexOf('.m4a') >= 0 || normalized.indexOf('audio/mp4') >= 0 ||
      normalized.indexOf('mpeg-4-audio') >= 0;
  }

  private pushIfPresent(findings: PrivacyFinding[], subtype: string, risk: RiskLevel,
    title: string, description: string, value: string | undefined): void {
    if (value === undefined || value.length === 0) return;
    const finding = new PrivacyFinding(`av-${subtype}`, subtype, risk, title, description,
      '生成副本时删除', true, value.slice(0, 200));
    finding.category = FindingCategory.METADATA;
    findings.push(finding);
  }

  private async openReadOnly(uri: string): Promise<fileIo.File> {
    try {
      return await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    } catch (_) {
      throw new Error('Unable to open the shared media file.');
    }
  }
}
