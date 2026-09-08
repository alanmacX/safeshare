import { fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RedactionAction } from '../models/PrivacyModels';
import { MetadataScanner } from '../metadata/MetadataScanner';
import { FaceScanner } from '../vision/FaceScanner';
import { QRScanner } from '../vision/QRScanner';
import { TempFileManager } from '../storage/TempFileManager';

const DETECTION_MAX_EDGE: number = 1600;

export class PrivacyScanner {
  private metadataScanner: MetadataScanner = new MetadataScanner();
  private faceScanner: FaceScanner = new FaceScanner();
  private qrScanner: QRScanner = new QRScanner();
  private tempFiles: TempFileManager;

  constructor(context: common.UIAbilityContext) {
    this.tempFiles = new TempFileManager(context);
  }

  async scan(uri: string): Promise<PrivacyScanResult> {
    const metadata: PrivacyScanResult = await this.metadataScanner.scan(uri);
    const findings: PrivacyFinding[] = metadata.findings.slice();
    const warnings: string[] = [];
    let pixelWidth: number = 0;
    let pixelHeight: number = 0;
    let mimeType: string = '';
    let multiFrame: boolean = false;

    let sourceFile: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let detectionMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(sourceFile.fd);
      const sourceInfo: image.ImageInfo = await source.getImageInfo();
      mimeType = sourceInfo.mimeType;
      try { multiFrame = await source.getFrameCount() > 1; } catch (_) {}
      if (multiFrame) warnings.push('已识别为多帧图片；当前版本只检查首帧，不会生成可能丢失动画的副本');
      pixelWidth = sourceInfo.size.width;
      pixelHeight = sourceInfo.size.height;
      const desired: image.Size = this.detectionSize(sourceInfo.size);
      detectionMap = await source.createPixelMap({
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: desired
      });
      const detectionInfo: image.ImageInfo = await detectionMap.getImageInfo();
      // getImageInfo() reports the raw container size, while the UI Image
      // component renders EXIF-oriented pixels. Orientations 5-8 transpose
      // width/height, so the reported dimensions (and every consumer that
      // maps overlay geometry or redaction regions) must swap them too.
      const rawWidth: number = sourceInfo.size.width;
      const rawHeight: number = sourceInfo.size.height;
      let transposed: boolean = false;
      try {
        const orientation: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
        transposed = ['5', '6', '7', '8'].indexOf(orientation.trim()) >= 0;
      } catch (_) {
        // No EXIF orientation: the container size is already the display size.
      }
      pixelWidth = transposed ? rawHeight : rawWidth;
      pixelHeight = transposed ? rawWidth : rawHeight;
      const scaleX: number = pixelWidth / detectionInfo.size.width;
      const scaleY: number = pixelHeight / detectionInfo.size.height;

      try {
        findings.push(...await this.scanQrFromDetectionMap(detectionMap, scaleX, scaleY));
      } catch (_) {
        warnings.push('当前设备未完成二维码与条码检查');
      }

      if (canIUse('SystemCapability.AI.Face.Detector')) {
        try {
          findings.push(...await this.faceScanner.scan(detectionMap, scaleX, scaleY));
        } catch (_) {
          warnings.push('人脸检测模型未就绪或本次检查失败');
        }
      }

      // Object detection is intentionally not in the default path. It is expensive and a screen/document
      // rectangle is not itself proof of private information. Dedicated document modes can opt in later.
    } catch (_) {
      warnings.push('未能建立端侧视觉检查图像');
    } finally {
      if (detectionMap !== undefined) detectionMap.release();
      if (source !== undefined) source.release();
      if (sourceFile !== undefined) {
        try { fileIo.closeSync(sourceFile); } catch (_) {}
      }
    }

    const result = new PrivacyScanResult(uri, findings);
    result.capabilityWarnings = warnings;
    result.pixelWidth = pixelWidth;
    result.pixelHeight = pixelHeight;
    result.mimeType = mimeType;
    result.readOnlyTool = multiFrame;
    return result;
  }

  async verifyVisual(uri: string, actions: RedactionAction[]): Promise<PrivacyFinding[]> {
    let needsQr: boolean = false;
    let needsFace: boolean = false;
    for (let index: number = 0; index < actions.length; index++) {
      needsQr = needsQr || actions[index].category === FindingCategory.QR;
      needsFace = needsFace || actions[index].category === FindingCategory.FACE;
    }
    const remaining: PrivacyFinding[] = [];
    if (!needsQr && !needsFace) return remaining;

    let file: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let map: image.PixelMap | undefined = undefined;
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      const fullInfo: image.ImageInfo = await source.getImageInfo();
      map = await source.createPixelMap({ editable: false, desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: this.detectionSize(fullInfo.size) });
      const mapInfo: image.ImageInfo = await map.getImageInfo();
      const scaleX: number = fullInfo.size.width / mapInfo.size.width;
      const scaleY: number = fullInfo.size.height / mapInfo.size.height;
      if (needsQr) {
        remaining.push(...await this.scanQrFromDetectionMap(map, scaleX, scaleY));
      }
      if (needsFace && canIUse('SystemCapability.AI.Face.Detector')) {
        remaining.push(...await this.faceScanner.scan(map, scaleX, scaleY));
      }
      return this.onlyOverlapping(remaining, actions);
    } catch (_) {
      throw new Error('Unable to verify the selected visual redactions.');
    } finally {
      if (map !== undefined) map.release();
      if (source !== undefined) source.release();
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_) {}
      }
    }
  }

  private onlyOverlapping(findings: PrivacyFinding[], actions: RedactionAction[]): PrivacyFinding[] {
    const overlapping: PrivacyFinding[] = [];
    for (let findingIndex: number = 0; findingIndex < findings.length; findingIndex++) {
      const finding: PrivacyFinding = findings[findingIndex];
      if (finding.region === undefined) continue;
      for (let actionIndex: number = 0; actionIndex < actions.length; actionIndex++) {
        if (actionIndex < actions.length && actionIndex >= 0 &&
          finding.category === actions[actionIndex].category &&
          this.overlap(finding.region.left, finding.region.top, finding.region.width, finding.region.height,
            actions[actionIndex].region.left, actions[actionIndex].region.top,
            actions[actionIndex].region.width, actions[actionIndex].region.height) > 0.2) {
          overlapping.push(finding);
          break;
        }
      }
    }
    return overlapping;
  }

  private overlap(leftA: number, topA: number, widthA: number, heightA: number,
    leftB: number, topB: number, widthB: number, heightB: number): number {
    const left: number = Math.max(leftA, leftB);
    const top: number = Math.max(topA, topB);
    const right: number = Math.min(leftA + widthA, leftB + widthB);
    const bottom: number = Math.min(topA + heightA, topB + heightB);
    if (right <= left || bottom <= top) return 0;
    const intersection: number = (right - left) * (bottom - top);
    const smaller: number = Math.min(widthA * heightA, widthB * heightB);
    return smaller > 0 ? intersection / smaller : 0;
  }

  private detectionSize(size: image.Size): image.Size {
    const maxEdge: number = Math.max(size.width, size.height);
    if (maxEdge <= DETECTION_MAX_EDGE) return { width: size.width, height: size.height };
    const ratio: number = DETECTION_MAX_EDGE / maxEdge;
    return { width: Math.max(1, Math.round(size.width * ratio)),
      height: Math.max(1, Math.round(size.height * ratio)) };
  }

  private async scanQrFromDetectionMap(pixelMap: image.PixelMap,
    scaleX: number, scaleY: number): Promise<PrivacyFinding[]> {
    const path: string = this.tempFiles.createPath('jpg');
    let output: fileIo.File | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      output = await fileIo.open(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      packer = image.createImagePacker();
      await packer.packToFile(pixelMap, output.fd, { format: 'image/jpeg', quality: 90 });
      fileIo.closeSync(output);
      output = undefined;
      return await this.qrScanner.scan(fileUri.getUriFromPath(path), scaleX, scaleY);
    } catch (_) {
      throw new Error('Unable to scan normalized barcode image.');
    } finally {
      if (output !== undefined) {
        try { fileIo.closeSync(output); } catch (_) {}
      }
      if (packer !== undefined) packer.release();
      await this.tempFiles.remove(path);
    }
  }

  async dispose(): Promise<void> {
    await this.faceScanner.dispose();
  }
}
