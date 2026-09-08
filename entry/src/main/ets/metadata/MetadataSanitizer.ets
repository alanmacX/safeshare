import { image } from '@kit.ImageKit';
import { common2D, drawing } from '@kit.ArkGraphics2D';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { FindingCategory, PrivacyFinding, RedactionAction, RedactionStyle, SanitizedFile,
  SensitiveRegion } from '../models/PrivacyModels';
import { MetadataScanner } from './MetadataScanner';
import { TempFileManager } from '../storage/TempFileManager';
import { MetadataMode, MetadataPolicy } from './MetadataPolicy';
import { PurposeWatermark } from '../privacy/PurposeWatermark';

import { runRedaction } from '../privacy/RedactionTask';
import { hilog } from '@kit.PerformanceAnalysisKit';

function flowLog(stage: string, detail: string = ''): void {
  hilog.error(0x8801, 'SafeShareFlow', `stage=${stage}${detail.length > 0 ? ` ${detail}` : ''}`);
}

class MetadataValue {
  key: image.PropertyKey;
  value: string;

  constructor(key: image.PropertyKey, value: string) {
    this.key = key;
    this.value = value;
  }
}

export class MetadataSanitizer {
  private context: common.UIAbilityContext;
  private scanner: MetadataScanner = new MetadataScanner();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async sanitize(uri: string, actions: RedactionAction[] = [],
    policy: MetadataPolicy = new MetadataPolicy()): Promise<SanitizedFile> {
    const manager: TempFileManager = new TempFileManager(this.context);
    let outputPath: string = '';
    let outputMimeType: string = 'image/jpeg';
    let outputUtd: string = 'general.jpeg';
    let source: image.ImageSource | undefined = undefined;
    let sourceFile: fileIo.File | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let output: fileIo.File | undefined = undefined;
    const preserved: MetadataValue[] = [];
    try {
      sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      flowLog('img_open_source');
      source = image.createImageSource(sourceFile.fd);
      const sourceInfo: image.ImageInfo = await source.getImageInfo();
      flowLog('img_source_info');
      await this.collectPreservedMetadata(source, policy, preserved);
      flowLog('img_collect_props');
      packer = image.createImagePacker();
      outputMimeType = this.chooseOutputMimeType(sourceInfo.mimeType, packer.supportedFormats);
      outputUtd = this.utdForMimeType(outputMimeType);
      let sourceName: string = uri;
      try { sourceName = sourceFile.name; } catch (_) {}
      outputPath = manager.createOutputPath(sourceName, this.extensionForMimeType(outputMimeType));
      pixelMap = await source.createPixelMap({
        editable: actions.length > 0 || policy.purposeWatermark.trim().length > 0 ||
          policy.imageWatermarkUri.length > 0,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      flowLog('img_decode_done');
      if (actions.length > 0) {
        await this.redactSensitiveRegions(pixelMap, actions);
        flowLog('img_redact_done');
      }
      if (policy.purposeWatermark.trim().length > 0) {
        PurposeWatermark.apply(pixelMap, policy.purposeWatermark, policy.watermarkOpacity,
          policy.watermarkAngle, policy.watermarkScale, policy.watermarkSpacing, policy.watermarkColor);
      }
      if (policy.imageWatermarkUri.length > 0) {
        await this.applyImageWatermark(pixelMap, policy);
        flowLog('img_watermark_done');
      }
      output = await fileIo.open(outputPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await packer.packToFile(pixelMap, output.fd, { format: outputMimeType, quality: 95 });
      flowLog('img_pack_done');
      fileIo.closeSync(output);
      output = undefined;

      if (policy.mode !== MetadataMode.DEEP_CLEAN && preserved.length > 0) {
        await this.restoreSafeMetadata(outputPath, preserved);
      }

      // Re-encoding the decoded pixels creates a new file without source EXIF/XMP blocks.
      const outputUri: string = fileUri.getUriFromPath(outputPath);
      const verification = await this.scanner.scan(outputUri);
      flowLog('img_verify_done', `findings=${verification.findings.length}`);
      if (this.hasUnexpectedMetadata(verification.findings, policy) ||
        !this.hasRequestedReplacements(verification.findings, policy)) {
        throw new Error('Sanitized copy metadata does not match the selected policy.');
      }
      const sanitized: SanitizedFile = new SanitizedFile(outputPath, outputUri, verification,
        outputUtd, outputMimeType);
      // Report the oriented dimensions of the decoded pixels (the decoder
      // applies EXIF orientation), not the raw container size.
      const outputInfo: image.ImageInfo = await pixelMap.getImageInfo();
      sanitized.pixelWidth = outputInfo.size.width;
      sanitized.pixelHeight = outputInfo.size.height;
      try {
        sanitized.byteSize = fileIo.statSync(outputPath).size;
      } catch (_) {
        sanitized.byteSize = 0;
      }
      return sanitized;
    } catch (_) {
      if (output !== undefined) {
        try {
          fileIo.closeSync(output);
        } catch (_) {
          // Continue cleanup if the descriptor was already closed.
        }
      }
      if (outputPath.length > 0) {
        await manager.remove(outputPath);
      }
      throw new Error('Unable to create a verified sanitized copy.');
    } finally {
      if (packer !== undefined) {
        packer.release();
      }
      if (pixelMap !== undefined) {
        pixelMap.release();
      }
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

  private hasUnexpectedMetadata(findings: PrivacyFinding[],
    policy: MetadataPolicy): boolean {
    for (let index: number = 0; index < findings.length; index++) {
      const subtype: string = findings[index].subtype;
      if (policy.mode === MetadataMode.CUSTOM) {
        if (policy.preserveSubtypes.indexOf(subtype) >= 0 ||
          policy.replacements.some((replacement) => replacement.subtype === subtype)) continue;
        if ((policy.preserveCaptureTime || policy.captureTime.length > 0) && subtype === 'CAPTURE_TIME') continue;
        if ((policy.preserveCameraInfo || policy.cameraMake.length > 0 || policy.cameraModel.length > 0) &&
          (subtype === 'DEVICE_MODEL' || subtype === 'DEVICE_MAKE' ||
          subtype === 'LENS_MODEL')) continue;
        if (policy.author.length > 0 && subtype === 'AUTHOR') continue;
        if (policy.copyright.length > 0 && subtype === 'COPYRIGHT') continue;
        if (policy.description.length > 0 && subtype === 'DESCRIPTION') continue;
        if (policy.gpsLatitude.length > 0 && policy.gpsLongitude.length > 0 &&
          (subtype === 'GPS' || subtype.startsWith('GPS_'))) continue;
      }
      return true;
    }
    return false;
  }

  private hasRequestedReplacements(findings: PrivacyFinding[], policy: MetadataPolicy): boolean {
    if (policy.mode !== MetadataMode.CUSTOM) return true;
    if (!(this.replacementMatches(findings, 'CAPTURE_TIME', policy.captureTime) &&
      this.replacementMatches(findings, 'DEVICE_MAKE', policy.cameraMake) &&
      this.replacementMatches(findings, 'DEVICE_MODEL', policy.cameraModel) &&
      this.replacementMatches(findings, 'AUTHOR', policy.author) &&
      this.replacementMatches(findings, 'COPYRIGHT', policy.copyright) &&
      this.replacementMatches(findings, 'DESCRIPTION', policy.description) &&
      this.gpsReplacementMatches(findings, policy))) return false;
    for (let index: number = 0; index < policy.replacements.length; index++) {
      if (!this.replacementMatches(findings, policy.replacements[index].subtype,
        policy.replacements[index].value)) return false;
    }
    return true;
  }

  private gpsReplacementMatches(findings: PrivacyFinding[], policy: MetadataPolicy): boolean {
    if (policy.gpsLatitude.trim().length === 0 || policy.gpsLongitude.trim().length === 0) return true;
    const requestedLatitude: number = this.parseDegrees(policy.gpsLatitude);
    const requestedLongitude: number = this.parseDegrees(policy.gpsLongitude);
    for (let index: number = 0; index < findings.length; index++) {
      if (findings[index].subtype !== 'GPS') continue;
      const parts: string[] = findings[index].rawValue.split('|');
      if (parts.length !== 2) continue;
      const readLatitude: number = this.parseDegrees(parts[0]);
      const readLongitude: number = this.parseDegrees(parts[1]);
      // The EXIF container stores degrees/minutes/seconds, so the read-back
      // text is almost never byte-identical to the requested decimal string.
      // Compare the angles instead; anything else reports a false failure and
      // deletes an already-clean output.
      if (Math.abs(readLatitude - Math.abs(requestedLatitude)) <= 0.0002 &&
        Math.abs(readLongitude - Math.abs(requestedLongitude)) <= 0.0002) {
        return true;
      }
    }
    return false;
  }

  /** Parses "31.2486" or EXIF-style "31,14,55.32" into decimal degrees. */
  private parseDegrees(value: string): number {
    const parts: string[] = value.trim().split(',');
    let degrees: number = 0;
    let scale: number = 1;
    for (let index: number = 0; index < parts.length && index < 3; index++) {
      degrees += Math.abs(Number.parseFloat(parts[index]) || 0) / scale;
      scale *= 60;
    }
    return degrees;
  }

  private replacementMatches(findings: PrivacyFinding[], subtype: string, requested: string): boolean {
    const expected: string = requested.trim().slice(0, 120);
    if (expected.length === 0) return true;
    for (let index: number = 0; index < findings.length; index++) {
      if (findings[index].subtype === subtype && findings[index].rawValue === expected) return true;
    }
    return false;
  }

  private async collectPreservedMetadata(source: image.ImageSource, policy: MetadataPolicy,
    preserved: MetadataValue[]): Promise<void> {
    if (policy.mode === MetadataMode.DEEP_CLEAN) return;
    if (policy.mode === MetadataMode.CUSTOM) {
      if (policy.captureTime.trim().length > 0) {
        this.appendReplacement(preserved, image.PropertyKey.DATE_TIME_ORIGINAL, policy.captureTime);
      } else if (policy.preserveCaptureTime) {
        await this.collectProperty(source, image.PropertyKey.DATE_TIME_ORIGINAL, preserved);
      }
    }
    if (policy.mode === MetadataMode.CUSTOM && policy.preserveCameraInfo) {
      await this.collectProperty(source, image.PropertyKey.MAKE, preserved);
      await this.collectProperty(source, image.PropertyKey.MODEL, preserved);
      await this.collectProperty(source, image.PropertyKey.LENS_MODEL, preserved);
    }
    if (policy.mode === MetadataMode.RECOMMENDED || policy.preservePhotographyInfo) {
      await this.collectProperty(source, image.PropertyKey.F_NUMBER, preserved);
      await this.collectProperty(source, image.PropertyKey.EXPOSURE_TIME, preserved);
      await this.collectProperty(source, image.PropertyKey.ISO_SPEED_RATINGS, preserved);
      await this.collectProperty(source, image.PropertyKey.FOCAL_LENGTH, preserved);
    }
    if (policy.mode === MetadataMode.CUSTOM) {
      for (let index: number = 0; index < policy.preserveSubtypes.length; index++) {
        await this.collectSubtype(source, policy.preserveSubtypes[index], preserved);
      }
      for (let index: number = 0; index < policy.replacements.length; index++) {
        this.appendSubtypeReplacement(preserved, policy.replacements[index].subtype,
          policy.replacements[index].value);
      }
      this.appendReplacement(preserved, image.PropertyKey.MAKE, policy.cameraMake);
      this.appendReplacement(preserved, image.PropertyKey.MODEL, policy.cameraModel);
      this.appendReplacement(preserved, image.PropertyKey.ARTIST, policy.author);
      this.appendReplacement(preserved, image.PropertyKey.COPYRIGHT, policy.copyright);
      this.appendReplacement(preserved, image.PropertyKey.IMAGE_DESCRIPTION, policy.description);
      if (policy.gpsLatitude.trim().length > 0 && policy.gpsLongitude.trim().length > 0) {
        const latitude: string = policy.gpsLatitude.trim();
        const longitude: string = policy.gpsLongitude.trim();
        this.appendReplacement(preserved, image.PropertyKey.GPS_LATITUDE, latitude.replace('-', ''));
        this.appendReplacement(preserved, image.PropertyKey.GPS_LATITUDE_REF, latitude.startsWith('-') ? 'S' : 'N');
        this.appendReplacement(preserved, image.PropertyKey.GPS_LONGITUDE, longitude.replace('-', ''));
        this.appendReplacement(preserved, image.PropertyKey.GPS_LONGITUDE_REF, longitude.startsWith('-') ? 'W' : 'E');
      }
    }
  }

  private propertyKeyForSubtype(subtype: string): image.PropertyKey | undefined {
    if (subtype === 'GPS_DATE') return image.PropertyKey.GPS_DATE_STAMP;
    if (subtype === 'CAPTURE_TIME') return image.PropertyKey.DATE_TIME_ORIGINAL;
    if (subtype === 'MODIFY_TIME') return image.PropertyKey.DATE_TIME;
    if (subtype === 'DIGITIZED_TIME') return image.PropertyKey.DATE_TIME_DIGITIZED;
    if (subtype === 'DEVICE_MODEL') return image.PropertyKey.MODEL;
    if (subtype === 'DEVICE_MAKE') return image.PropertyKey.MAKE;
    if (subtype === 'SOFTWARE') return image.PropertyKey.SOFTWARE;
    if (subtype === 'AUTHOR') return image.PropertyKey.ARTIST;
    if (subtype === 'COPYRIGHT') return image.PropertyKey.COPYRIGHT;
    if (subtype === 'COMMENT') return image.PropertyKey.USER_COMMENT;
    if (subtype === 'DESCRIPTION') return image.PropertyKey.IMAGE_DESCRIPTION;
    if (subtype === 'CAMERA_OWNER') return image.PropertyKey.CAMERA_OWNER_NAME;
    if (subtype === 'BODY_SERIAL') return image.PropertyKey.BODY_SERIAL_NUMBER;
    if (subtype === 'LENS_SERIAL') return image.PropertyKey.LENS_SERIAL_NUMBER;
    if (subtype === 'LENS_MODEL') return image.PropertyKey.LENS_MODEL;
    if (subtype === 'GPS_ALTITUDE') return image.PropertyKey.GPS_ALTITUDE;
    if (subtype === 'GPS_METHOD') return image.PropertyKey.GPS_PROCESSING_METHOD;
    if (subtype === 'GPS_AREA') return image.PropertyKey.GPS_AREA_INFORMATION;
    return undefined;
  }

  private async collectSubtype(source: image.ImageSource, subtype: string,
    preserved: MetadataValue[]): Promise<void> {
    if (subtype === 'GPS') {
      await this.collectProperty(source, image.PropertyKey.GPS_LATITUDE, preserved);
      await this.collectProperty(source, image.PropertyKey.GPS_LATITUDE_REF, preserved);
      await this.collectProperty(source, image.PropertyKey.GPS_LONGITUDE, preserved);
      await this.collectProperty(source, image.PropertyKey.GPS_LONGITUDE_REF, preserved);
      return;
    }
    const key: image.PropertyKey | undefined = this.propertyKeyForSubtype(subtype);
    if (key !== undefined) await this.collectProperty(source, key, preserved);
  }

  private appendSubtypeReplacement(values: MetadataValue[], subtype: string, value: string): void {
    if (subtype === 'GPS') {
      const coordinates: string[] = value.split('|');
      if (coordinates.length !== 2) return;
      const latitude: string = coordinates[0].trim();
      const longitude: string = coordinates[1].trim();
      this.appendReplacement(values, image.PropertyKey.GPS_LATITUDE, latitude.replace('-', ''));
      this.appendReplacement(values, image.PropertyKey.GPS_LATITUDE_REF, latitude.startsWith('-') ? 'S' : 'N');
      this.appendReplacement(values, image.PropertyKey.GPS_LONGITUDE, longitude.replace('-', ''));
      this.appendReplacement(values, image.PropertyKey.GPS_LONGITUDE_REF, longitude.startsWith('-') ? 'W' : 'E');
      return;
    }
    const key: image.PropertyKey | undefined = this.propertyKeyForSubtype(subtype);
    if (key !== undefined) this.appendReplacement(values, key, value);
  }

  private async collectProperty(source: image.ImageSource, key: image.PropertyKey,
    preserved: MetadataValue[]): Promise<void> {
    try {
      const value: string = await source.getImageProperty(key);
      if (value.length > 0 && value !== 'undefined' && value !== 'Unknown') {
        preserved.push(new MetadataValue(key, value));
      }
    } catch (_) {
    }
  }

  private appendReplacement(values: MetadataValue[], key: image.PropertyKey, value: string): void {
    const sanitized: string = value.trim().slice(0, 120);
    if (sanitized.length > 0) values.push(new MetadataValue(key, sanitized));
  }

  private async restoreSafeMetadata(path: string, values: MetadataValue[]): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    let outputSource: image.ImageSource | undefined = undefined;
    try {
      file = await fileIo.open(path, fileIo.OpenMode.READ_WRITE);
      outputSource = image.createImageSource(file.fd);
      for (let index: number = 0; index < values.length; index++) {
        try {
          await outputSource.modifyImageProperty(values[index].key, values[index].value);
        } catch (_) {
          // Some formats do not provide a writable EXIF container. Privacy still fails closed:
          // the value remains absent rather than copying an unsafe source metadata block.
        }
      }
    } catch (_) {
      // Restoring optional values must never weaken cleaning or invalidate the safe copy.
    } finally {
      if (outputSource !== undefined) outputSource.release();
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_) {}
      }
    }
  }

  private chooseOutputMimeType(sourceMimeType: string, supportedFormats: string[]): string {
    if (sourceMimeType === 'image/png' && supportedFormats.indexOf('image/png') >= 0) {
      return 'image/png';
    }
    if ((sourceMimeType === 'image/heif' || sourceMimeType === 'image/heic') &&
      supportedFormats.indexOf('image/heif') >= 0) {
      return 'image/heif';
    }
    if (sourceMimeType === 'image/webp' && supportedFormats.indexOf('image/webp') >= 0) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  private extensionForMimeType(mimeType: string): string {
    if (mimeType === 'image/png') {
      return 'png';
    }
    if (mimeType === 'image/heif') {
      return 'heif';
    }
    if (mimeType === 'image/webp') {
      return 'webp';
    }
    return 'jpg';
  }

  private utdForMimeType(mimeType: string): string {
    if (mimeType === 'image/png') {
      return 'general.png';
    }
    return mimeType === 'image/jpeg' ? 'general.jpeg' : 'general.image';
  }

  private async redactSensitiveRegions(pixelMap: image.PixelMap, actions: RedactionAction[]): Promise<void> {
    const info: image.ImageInfo = await pixelMap.getImageInfo();
    const width: number = info.size.width;
    const height: number = info.size.height;

    for (let index: number = 0; index < actions.length; index++) {
      const region: SensitiveRegion = actions[index].region;
      const paddingRatio: number = actions[index].category === FindingCategory.QR ? 0.18 :
        (actions[index].category === FindingCategory.FACE ? 0.12 : 0.08);
      const padding: number = Math.max(8, Math.round(Math.max(region.width, region.height) * paddingRatio));
      const left: number = Math.max(0, Math.floor(region.left) - padding);
      const top: number = Math.max(0, Math.floor(region.top) - padding);
      const right: number = Math.min(width, Math.ceil(region.left + region.width) + padding);
      const bottom: number = Math.min(height, Math.ceil(region.top + region.height) + padding);
      if (right <= left || bottom <= top) {
        continue;
      }

      const regionWidth: number = right - left;
      const regionHeight: number = bottom - top;
      const regionStride: number = regionWidth * 4;
      const buffer: ArrayBuffer = new ArrayBuffer(regionStride * regionHeight);
      const area: image.PositionArea = {
        pixels: buffer,
        offset: 0,
        stride: regionStride,
        region: { x: left, y: top, size: { width: regionWidth, height: regionHeight } }
      };
      await pixelMap.readPixels(area);
      // Heavy per-pixel math runs off the main thread; the worker returns a
      // fresh buffer that replaces the one read above.
      const style: number = actions[index].style === RedactionStyle.PIXELATE ? 1 :
        actions[index].style === RedactionStyle.BLUR ? 2 : 0;
      const processed: ArrayBuffer = await runRedaction(buffer, regionStride,
        regionWidth, regionHeight, style);
      area.pixels = processed;
      await pixelMap.writePixels(area);
    }
  }

  private async applyImageWatermark(target: image.PixelMap, policy: MetadataPolicy): Promise<void> {
    let sourceFile: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let watermark: image.PixelMap | undefined = undefined;
    try {
      sourceFile = await fileIo.open(policy.imageWatermarkUri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(sourceFile.fd);
      watermark = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      const targetInfo: image.ImageInfo = target.getImageInfoSync();
      const watermarkInfo: image.ImageInfo = watermark.getImageInfoSync();
      const targetWidth: number = targetInfo.size.width;
      const targetHeight: number = targetInfo.size.height;
      const sourceWidth: number = Math.max(1, watermarkInfo.size.width);
      const sourceHeight: number = Math.max(1, watermarkInfo.size.height);
      const targetMarkSize: number = Math.max(48, Math.min(Math.min(targetWidth, targetHeight) * 0.8,
        Math.min(targetWidth, targetHeight) * Math.max(0.08, Math.min(0.55, policy.imageWatermarkScale))));
      const aspect: number = sourceWidth / sourceHeight;
      const targetMarkWidth: number = aspect >= 1 ? targetMarkSize : targetMarkSize * aspect;
      const targetMarkHeight: number = aspect >= 1 ? targetMarkSize / aspect : targetMarkSize;
      const margin: number = Math.max(0, Math.min(targetWidth, targetHeight) *
        Math.max(0, Math.min(0.12, policy.imageWatermarkMargin)));
      const canvas: drawing.Canvas = new drawing.Canvas(target);
      const brush: drawing.Brush = new drawing.Brush();
      brush.setAlpha(Math.round(Math.max(0.08, Math.min(1, policy.imageWatermarkOpacity)) * 255));
      const layer: common2D.Rect = { left: 0, top: 0, right: targetWidth, bottom: targetHeight };
      canvas.saveLayer(layer, brush);
      if (policy.imageWatermarkTiled) {
        const stepX: number = targetMarkWidth * 1.65;
        const stepY: number = targetMarkHeight * 1.65;
        for (let y: number = -targetMarkHeight; y < targetHeight + targetMarkHeight; y += stepY) {
          for (let x: number = -targetMarkWidth; x < targetWidth + targetMarkWidth; x += stepX) {
            this.drawWatermarkImage(canvas, watermark, x, y, targetMarkWidth, targetMarkHeight,
              policy.imageWatermarkAngle);
          }
        }
      } else {
        const column: number = policy.imageWatermarkPosition % 3;
        const row: number = Math.floor(policy.imageWatermarkPosition / 3);
        const x: number = column === 0 ? margin :
          (column === 1 ? (targetWidth - targetMarkWidth) / 2 : targetWidth - targetMarkWidth - margin);
        const y: number = row === 0 ? margin :
          (row === 1 ? (targetHeight - targetMarkHeight) / 2 : targetHeight - targetMarkHeight - margin);
        this.drawWatermarkImage(canvas, watermark, x, y, targetMarkWidth, targetMarkHeight,
          policy.imageWatermarkAngle);
      }
      canvas.restore();
    } catch (_) {
      throw new Error('Unable to render image watermark.');
    } finally {
      if (watermark !== undefined) watermark.release();
      if (source !== undefined) source.release();
      if (sourceFile !== undefined) {
        try { fileIo.closeSync(sourceFile); } catch (_) {}
      }
    }
  }

  private drawWatermarkImage(canvas: drawing.Canvas, watermark: image.PixelMap, x: number, y: number,
    width: number, height: number, angle: number): void {
    canvas.save();
    canvas.rotate(Math.max(-180, Math.min(180, angle)), x + width / 2, y + height / 2);
    const destination: common2D.Rect = { left: x, top: y, right: x + width, bottom: y + height };
    canvas.drawImageRect(watermark, destination);
    canvas.restore();
  }
}
