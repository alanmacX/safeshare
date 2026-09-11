import { FileKind } from '../processors/FileTypeRouter';

export enum SupportGrade {
  IMPLEMENTED = 'IMPLEMENTED',
  LIMITED = 'LIMITED',
  READ_ONLY = 'READ_ONLY',
  UNSUPPORTED = 'UNSUPPORTED'
}

/** One source of truth for routing, operation gates and the support page. */
export class MediaCapability {
  id: string;
  label: string;
  grade: SupportGrade;
  metadataScan: boolean;
  metadataClean: boolean;
  losslessMetadata: boolean;
  textWatermark: boolean;
  imageWatermark: boolean;
  face: boolean;
  qr: boolean;
  note: string;

  constructor(id: string, label: string, grade: SupportGrade, metadataScan: boolean,
    metadataClean: boolean, losslessMetadata: boolean, textWatermark: boolean,
    imageWatermark: boolean, face: boolean, qr: boolean, note: string = '') {
    this.id = id;
    this.label = label;
    this.grade = grade;
    this.metadataScan = metadataScan;
    this.metadataClean = metadataClean;
    this.losslessMetadata = losslessMetadata;
    this.textWatermark = textWatermark;
    this.imageWatermark = imageWatermark;
    this.face = face;
    this.qr = qr;
    this.note = note;
  }
}

export class MediaCapabilityRegistry {
  static forResult(kind: FileKind, mimeType: string = '', isMovingPhoto: boolean = false,
    multiFrame: boolean = false, readOnly: boolean = false): MediaCapability {
    if (isMovingPhoto) return MediaCapabilityRegistry.movingPhoto();
    if (kind === FileKind.IMAGE) return MediaCapabilityRegistry.image(mimeType, multiFrame);
    if (kind === FileKind.PDF) return new MediaCapability('pdf', 'PDF', SupportGrade.LIMITED,
      true, true, false, true, false, false, false, '生成副本会重建页面，表单、签名或附件不处理');
    if (kind === FileKind.WORD) return MediaCapabilityRegistry.office('word', 'Word');
    if (kind === FileKind.EXCEL) return MediaCapabilityRegistry.office('excel', 'Excel');
    if (kind === FileKind.POWERPOINT) return MediaCapabilityRegistry.office('powerpoint', 'PowerPoint');
    if (kind === FileKind.AUDIO_VIDEO) {
      if (readOnly) return new MediaCapability('audio-readonly', '音频', SupportGrade.READ_ONLY,
        true, false, false, false, false, false, false, '当前容器仅检查，不生成清理副本');
      if (mimeType === 'audio/mpeg') {
        return new MediaCapability('mp3', 'MP3', SupportGrade.LIMITED,
          true, true, false, false, false, false, false, '剥离 ID3v2/ID3v1/APE 标签，保留音频帧');
      }
      if (mimeType === 'audio/flac') {
        return new MediaCapability('flac', 'FLAC', SupportGrade.LIMITED,
          true, true, false, false, false, false, false, '保留 STREAMINFO，剥离 Vorbis Comment/封面图');
      }
      if (mimeType === 'audio/wav' || mimeType === 'audio/x-wav') {
        return new MediaCapability('wav', 'WAV', SupportGrade.LIMITED,
          true, true, false, false, false, false, false, '保留 fmt/data，剥离 LIST INFO/bext/iXML');
      }
      return new MediaCapability(mimeType === 'audio/mp4' ? 'm4a' : 'video',
        mimeType === 'audio/mp4' ? 'M4A' : '视频', SupportGrade.LIMITED,
        true, true, false, false, false, false, false, '复制编码轨道并移除容器元数据');
    }
    return new MediaCapability('unknown', '未知格式', SupportGrade.UNSUPPORTED,
      false, false, false, false, false, false, false, '暂不支持');
  }

  static image(mimeType: string, multiFrame: boolean): MediaCapability {
    const mime: string = mimeType.toLowerCase();
    if (mime === 'image/gif') return new MediaCapability('gif', 'GIF', SupportGrade.LIMITED,
      true, true, true, false, false, false, false, '保留动画；仅处理元数据');
    if (mime === 'image/webp' && multiFrame) return new MediaCapability('webp-animated', '动态 WebP',
      SupportGrade.LIMITED, true, true, true, false, false, false, false, '保留动画；仅处理元数据');
    if ((mime === 'image/heif' || mime === 'image/heic') && multiFrame) {
      return new MediaCapability('heif-sequence', 'HEIF 序列', SupportGrade.LIMITED,
        true, true, true, false, false, false, false, '保留序列与辅助图；仅处理元数据');
    }
    if (mime === 'image/tiff' || mime === 'image/x-adobe-dng' || mime === 'image/dng') {
      return new MediaCapability(mime.indexOf('dng') >= 0 ? 'dng' : 'tiff',
        mime.indexOf('dng') >= 0 ? 'DNG' : 'TIFF', SupportGrade.LIMITED,
        true, true, true, false, false, false, false, '仅处理元数据');
    }
    if (mime === 'image/heif' || mime === 'image/heic') {
      return new MediaCapability('heif', 'HEIF/HEIC', SupportGrade.LIMITED,
        true, true, true, false, false, false, false,
        '清 HEIF Exif/XMP item 并写回替换值；为保留 HDR/辅助图不重编码');
    }
    if (mime === 'image/jpeg') return new MediaCapability('jpeg', 'JPEG', SupportGrade.IMPLEMENTED,
      true, true, true, true, true, true, true);
    if (mime === 'image/png') return new MediaCapability('png', 'PNG', SupportGrade.IMPLEMENTED,
      true, true, true, true, true, true, true);
    if (mime === 'image/webp') return new MediaCapability('webp', 'WebP', SupportGrade.LIMITED,
      true, true, true, true, true, true, true, '视觉处理会重新编码');
    if (mime === 'image/bmp') return new MediaCapability('bmp', 'BMP', SupportGrade.LIMITED,
      true, true, true, false, false, false, false, '保留原文件；不开放视觉处理');
    return new MediaCapability('image-unknown', '图片', SupportGrade.READ_ONLY,
      true, false, false, false, false, false, false, '格式能力未确认，仅显示检查结果');
  }

  static movingPhoto(): MediaCapability {
    return new MediaCapability('moving-photo', '动态照片', SupportGrade.UNSUPPORTED,
      false, false, false, false, false, false, false, '暂不支持动态照片，请选择普通静态图片');
  }

  static supportCatalog(): MediaCapability[] {
    return [
      MediaCapabilityRegistry.image('image/jpeg', false),
      MediaCapabilityRegistry.image('image/png', false),
      MediaCapabilityRegistry.image('image/heif', false),
      MediaCapabilityRegistry.image('image/gif', true),
      MediaCapabilityRegistry.image('image/webp', true),
      MediaCapabilityRegistry.image('image/tiff', false),
      MediaCapabilityRegistry.forResult(FileKind.AUDIO_VIDEO, 'video/mp4'),
      MediaCapabilityRegistry.forResult(FileKind.AUDIO_VIDEO, 'audio/mpeg', false, false, true),
      MediaCapabilityRegistry.forResult(FileKind.PDF),
      MediaCapabilityRegistry.office('office', 'Office OOXML')
    ];
  }

  static compactOperations(capability: MediaCapability): string {
    const values: string[] = [];
    if (capability.metadataClean) values.push('元数据');
    else if (capability.metadataScan) values.push('仅检查');
    if (capability.textWatermark || capability.imageWatermark) values.push('水印');
    if (capability.face || capability.qr) values.push('隐私打码');
    return values.length > 0 ? values.join(' · ') : '不支持';
  }

  private static office(id: string, label: string): MediaCapability {
    return new MediaCapability(id, label, SupportGrade.LIMITED,
      true, true, true, false, false, false, false, '仅处理文档属性；内嵌内容不检查');
  }
}
