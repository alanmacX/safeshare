import { faceDetector } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { FindingCategory, PrivacyFinding, RiskLevel, SensitiveRegion } from '../models/PrivacyModels';

export class FaceScanner {
  private initialized: boolean = false;

  private async ensureInitialized(): Promise<void> {
    if (!this.initialized) {
      this.initialized = await faceDetector.init();
    }
    if (!this.initialized) {
      throw new Error('Face detection is unavailable on this device.');
    }
  }

  async scan(pixelMap: image.PixelMap, scaleX: number = 1, scaleY: number = 1): Promise<PrivacyFinding[]> {
    try {
      await this.ensureInitialized();
      const faces: faceDetector.Face[] = await faceDetector.detect({ pixelMap: pixelMap });
      const findings: PrivacyFinding[] = [];
      for (let index: number = 0; index < faces.length; index++) {
        const face: faceDetector.Face = faces[index];
        const finding = new PrivacyFinding(`face-${index}`, 'FACE', RiskLevel.MEDIUM,
          faces.length === 1 ? '图片中检测到人脸' : `图片中检测到人脸 ${index + 1}/${faces.length}`,
          '公开分享可能暴露人物身份。', '选择遮盖或保留', true, '已检测到人脸');
        finding.category = FindingCategory.FACE;
        finding.region = new SensitiveRegion(face.rect.left * scaleX, face.rect.top * scaleY,
          face.rect.width * scaleX, face.rect.height * scaleY);
        findings.push(finding);
      }
      return findings;
    } catch (_) {
      throw new Error('Unable to complete on-device face detection.');
    }
  }

  async dispose(): Promise<void> {
    if (this.initialized) {
      try {
        await faceDetector.release();
      } catch (_) {
      }
      this.initialized = false;
    }
  }
}
