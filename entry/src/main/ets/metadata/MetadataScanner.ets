import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RiskLevel } from '../models/PrivacyModels';
import { GifMetadata, GifMetadataSummary } from './GifMetadata';
import { ContainerMetadata, ContainerMetadataSummary } from './ContainerMetadata';
import { JpegMetadata, JpegMetadataSummary } from './JpegMetadata';
import { TiffMetadata, TiffMetadataSummary } from './TiffMetadata';

class MetadataDefinition {
  key: image.PropertyKey;
  subtype: string;
  risk: RiskLevel;
  title: string;
  description: string;
  recommendation: string;
  recommended: boolean;

  constructor(key: image.PropertyKey, subtype: string, risk: RiskLevel, title: string,
    description: string, recommendation: string, recommended: boolean) {
    this.key = key;
    this.subtype = subtype;
    this.risk = risk;
    this.title = title;
    this.description = description;
    this.recommendation = recommendation;
    this.recommended = recommended;
  }
}

const DEFINITIONS: MetadataDefinition[] = [
  new MetadataDefinition(image.PropertyKey.GPS_DATE_STAMP, 'GPS_DATE', RiskLevel.MEDIUM,
    '包含定位日期', '定位记录中保留了日期。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.DATE_TIME_ORIGINAL, 'CAPTURE_TIME', RiskLevel.MEDIUM,
    '包含拍摄时间', '精确时间可能暴露活动规律。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.DATE_TIME, 'MODIFY_TIME', RiskLevel.LOW,
    '包含修改时间', '文件记录了最后修改时间。', '可清除', true),
  new MetadataDefinition(image.PropertyKey.DATE_TIME_DIGITIZED, 'DIGITIZED_TIME', RiskLevel.LOW,
    '包含数字化时间', '图片记录了数字化处理时间。', '可清除', true),
  new MetadataDefinition(image.PropertyKey.MODEL, 'DEVICE_MODEL', RiskLevel.MEDIUM,
    '包含拍摄设备', '图片记录了设备型号。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.MAKE, 'DEVICE_MAKE', RiskLevel.LOW,
    '包含设备品牌', '图片记录了设备品牌。', '可清除', true),
  new MetadataDefinition(image.PropertyKey.SOFTWARE, 'SOFTWARE', RiskLevel.LOW,
    '包含处理软件', '图片记录了生成或编辑软件。', '可清除', true),
  new MetadataDefinition(image.PropertyKey.ARTIST, 'AUTHOR', RiskLevel.MEDIUM,
    '包含作者信息', '作者字段可能包含姓名。', '建议检查并清除', true),
  new MetadataDefinition(image.PropertyKey.COPYRIGHT, 'COPYRIGHT', RiskLevel.LOW,
    '包含版权信息', '版权字段可能包含身份信息。', '按需清除', false),
  new MetadataDefinition(image.PropertyKey.USER_COMMENT, 'COMMENT', RiskLevel.MEDIUM,
    '包含图片备注', '备注可能包含未预期的文字。', '建议检查并清除', true),
  new MetadataDefinition(image.PropertyKey.IMAGE_DESCRIPTION, 'DESCRIPTION', RiskLevel.MEDIUM,
    '包含图片描述', '描述字段可能包含地点、姓名或工作信息。', '建议检查并清除', true),
  new MetadataDefinition(image.PropertyKey.CAMERA_OWNER_NAME, 'CAMERA_OWNER', RiskLevel.HIGH,
    '包含设备所有者', '设备所有者字段可能直接暴露身份。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.BODY_SERIAL_NUMBER, 'BODY_SERIAL', RiskLevel.HIGH,
    '包含机身序列号', '唯一序列号可用于关联设备。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.LENS_SERIAL_NUMBER, 'LENS_SERIAL', RiskLevel.HIGH,
    '包含镜头序列号', '唯一序列号可用于关联设备。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.LENS_MODEL, 'LENS_MODEL', RiskLevel.LOW,
    '包含镜头型号', '图片记录了拍摄镜头型号。', '可清除', true),
  new MetadataDefinition(image.PropertyKey.GPS_ALTITUDE, 'GPS_ALTITUDE', RiskLevel.MEDIUM,
    '包含拍摄海拔', '海拔信息可能进一步缩小拍摄地点。', '建议清除', true),
  new MetadataDefinition(image.PropertyKey.GPS_PROCESSING_METHOD, 'GPS_METHOD', RiskLevel.LOW,
    '包含定位方式', '图片记录了定位信息的生成方式。', '可清除', true),
  new MetadataDefinition(image.PropertyKey.GPS_AREA_INFORMATION, 'GPS_AREA', RiskLevel.HIGH,
    '包含定位区域信息', '定位区域字段可能直接暴露地点。', '建议清除', true)
];

export class MetadataScanner {
  async scan(uri: string): Promise<PrivacyScanResult> {
    let source: image.ImageSource | undefined = undefined;
    let sourceFile: fileIo.File | undefined = undefined;
    const findings: PrivacyFinding[] = [];
    try {
      sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(sourceFile.fd);
      if (stat.size >= 6) {
        const headerBuffer: ArrayBuffer = new ArrayBuffer(6);
        const headerRead: number = fileIo.readSync(sourceFile.fd, headerBuffer, { length: 6 });
        const header: Uint8Array = new Uint8Array(headerBuffer, 0, Math.max(0, headerRead));
        fileIo.lseek(sourceFile.fd, 0, fileIo.WhenceType.SEEK_SET);
        if (GifMetadata.isGif(header)) {
          const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
          const read: number = await fileIo.read(sourceFile.fd, buffer);
          if (read !== stat.size) throw new Error('Unable to read the complete GIF.');
          const summary: GifMetadataSummary = GifMetadata.inspect(new Uint8Array(buffer));
          if (summary.commentCount > 0) {
            const finding = new PrivacyFinding('metadata-GIF_COMMENT', 'GIF_COMMENT', RiskLevel.MEDIUM,
              '包含 GIF 注释', 'GIF 注释可能包含姓名、地点或生成工具信息。', '建议清除', true,
              `${summary.commentCount} 个注释块`);
            finding.category = FindingCategory.METADATA;
            findings.push(finding);
          }
          if (summary.applicationMetadataCount > 0) {
            const finding = new PrivacyFinding('metadata-GIF_APPLICATION', 'GIF_APPLICATION', RiskLevel.MEDIUM,
              '包含 GIF 应用元数据', '应用扩展可能包含 XMP、色彩配置或厂商私有信息。', '建议清除', true,
              `${summary.applicationMetadataCount} 个应用扩展`);
            finding.category = FindingCategory.METADATA;
            findings.push(finding);
          }
          return new PrivacyScanResult(uri, findings);
        }
        if (ContainerMetadata.isPng(header) || stat.size >= 12) {
          const containerBuffer: ArrayBuffer = new ArrayBuffer(stat.size);
          const containerRead: number = await fileIo.read(sourceFile.fd, containerBuffer);
          if (containerRead !== stat.size) throw new Error('Unable to read the complete image container.');
          const containerBytes: Uint8Array = new Uint8Array(containerBuffer);
          if (JpegMetadata.isJpeg(containerBytes)) {
            const jpeg: JpegMetadataSummary = JpegMetadata.inspect(containerBytes);
            if (jpeg.commentCount > 0 || jpeg.iptcCount > 0 || jpeg.privateXmpCount > 0) {
              const finding = new PrivacyFinding('metadata-JPEG_CONTAINER', 'JPEG_CONTAINER', RiskLevel.HIGH,
                '包含 JPEG 扩展元数据', '注释、IPTC 或 XMP 可能携带身份、位置、时间和编辑信息。',
                '建议清除', true,
                `${jpeg.commentCount} 个注释，${jpeg.iptcCount} 个 IPTC，${jpeg.privateXmpCount} 个隐私 XMP 字段`);
              finding.category = FindingCategory.METADATA;
              findings.push(finding);
            }
          } else if (ContainerMetadata.isPng(containerBytes)) {
            const png: ContainerMetadataSummary = ContainerMetadata.inspectPng(containerBytes);
            if (png.textCount > 0) {
              const finding = new PrivacyFinding('metadata-PNG_TEXT', 'PNG_TEXT', RiskLevel.MEDIUM,
                '包含 PNG 文本元数据', '文本块可能包含作者、软件、位置、时间或自由备注。',
                '建议清除', true, `${png.textCount} 个文本块`);
              finding.category = FindingCategory.METADATA;
              findings.push(finding);
            }
          } else if (ContainerMetadata.isWebp(containerBytes)) {
            const webp: ContainerMetadataSummary = ContainerMetadata.inspectWebp(containerBytes);
            if (webp.exifCount > 0 || webp.xmpCount > 0) {
              const finding = new PrivacyFinding('metadata-WEBP_CONTAINER', 'WEBP_CONTAINER', RiskLevel.HIGH,
                '包含 WebP 元数据', 'WebP 容器包含 EXIF 或 XMP，可能携带位置、设备和身份信息。',
                '建议深度清除', true, `${webp.exifCount} 个 EXIF，${webp.xmpCount} 个 XMP`);
              finding.category = FindingCategory.METADATA;
              findings.push(finding);
            }
            return new PrivacyScanResult(uri, findings);
          } else if (TiffMetadata.isClassicTiff(containerBytes)) {
            const tiff: TiffMetadataSummary = TiffMetadata.inspect(containerBytes);
            if (tiff.privacyTagCount > 0 || tiff.gpsDirectoryCount > 0 || tiff.xmpIptcCount > 0) {
              const finding = new PrivacyFinding('metadata-TIFF_CONTAINER', 'TIFF_CONTAINER', RiskLevel.HIGH,
                '包含 TIFF/DNG 元数据', 'IFD、GPS、XMP 或 IPTC 可能携带位置、设备和身份信息。',
                '建议清除', true,
                `${tiff.privacyTagCount} 个隐私标签，${tiff.gpsDirectoryCount} 个 GPS 目录，${tiff.xmpIptcCount} 个 XMP/IPTC`);
              finding.category = FindingCategory.METADATA;
              findings.push(finding);
            }
            return new PrivacyScanResult(uri, findings);
          }
          fileIo.lseek(sourceFile.fd, 0, fileIo.WhenceType.SEEK_SET);
        }
        fileIo.lseek(sourceFile.fd, 0, fileIo.WhenceType.SEEK_SET);
      }
      source = image.createImageSource(sourceFile.fd);
      try {
        const latitude: string = await source.getImageProperty(image.PropertyKey.GPS_LATITUDE);
        const longitude: string = await source.getImageProperty(image.PropertyKey.GPS_LONGITUDE);
        if (latitude.length > 0 && longitude.length > 0) {
          const location = new PrivacyFinding('metadata-GPS', 'GPS', RiskLevel.HIGH,
            '包含精确拍摄位置', '坐标可能暴露住所或行程。', '建议清除', true,
            `${latitude} | ${longitude}`);
          location.category = FindingCategory.METADATA;
          findings.push(location);
        }
      } catch (_) {
        // A missing coordinate pair is expected for images without location metadata.
      }
      for (let index: number = 0; index < DEFINITIONS.length; index++) {
        const definition: MetadataDefinition = DEFINITIONS[index];
        try {
          const value: string = await source.getImageProperty(definition.key);
          if (value.length > 0 && value !== 'undefined' && value !== 'Unknown') {
            const finding = new PrivacyFinding(`metadata-${definition.subtype}`, definition.subtype,
              definition.risk, definition.title, definition.description, definition.recommendation,
              definition.recommended, value);
            finding.category = FindingCategory.METADATA;
            findings.push(finding);
          }
        } catch (_) {
          // Missing EXIF properties are expected and are not scan failures.
        }
      }
      return new PrivacyScanResult(uri, findings);
    } catch (_) {
      throw new Error('Unable to open or scan the selected image.');
    } finally {
      if (source !== undefined) {
        source.release();
      }
      if (sourceFile !== undefined) {
        try {
          fileIo.closeSync(sourceFile);
        } catch (_) {
        }
      }
    }
  }
}
