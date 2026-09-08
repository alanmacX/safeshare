import { detectBarcode, scanBarcode } from '@kit.ScanKit';
import { FindingCategory, PrivacyFinding, RiskLevel, SensitiveRegion } from '../models/PrivacyModels';

export class QRScanner {
  async scan(uri: string, scaleX: number = 1, scaleY: number = 1): Promise<PrivacyFinding[]> {
    let results: scanBarcode.ScanResult[] = [];
    try {
      results = await detectBarcode.decode({ uri: uri });
    } catch (_) {
      throw new Error('Unable to complete on-device barcode detection.');
    }
    const findings: PrivacyFinding[] = [];
    for (let index: number = 0; index < results.length; index++) {
      const result: scanBarcode.ScanResult = results[index];
      const finding = new PrivacyFinding(`qr-${index}`, 'QR', RiskLevel.MEDIUM,
        results.length === 1 ? '图片中检测到可扫描二维码' : `图片中检测到可扫描二维码 ${index + 1}/${results.length}`,
        '二维码或条码可能包含链接、账号或其他可复制信息。', '选择遮盖或保留', true,
        '二维码内容已隐藏');
      finding.category = FindingCategory.QR;
      if (result.cornerPoints !== undefined && result.cornerPoints.length > 0) {
        let left: number = result.cornerPoints[0].x;
        let right: number = result.cornerPoints[0].x;
        let top: number = result.cornerPoints[0].y;
        let bottom: number = result.cornerPoints[0].y;
        for (let pointIndex: number = 1; pointIndex < result.cornerPoints.length; pointIndex++) {
          left = Math.min(left, result.cornerPoints[pointIndex].x);
          right = Math.max(right, result.cornerPoints[pointIndex].x);
          top = Math.min(top, result.cornerPoints[pointIndex].y);
          bottom = Math.max(bottom, result.cornerPoints[pointIndex].y);
        }
        finding.region = new SensitiveRegion(left * scaleX, top * scaleY,
          (right - left) * scaleX, (bottom - top) * scaleY);
      } else if (result.scanCodeRect !== undefined) {
        finding.region = new SensitiveRegion(result.scanCodeRect.left * scaleX, result.scanCodeRect.top * scaleY,
          (result.scanCodeRect.right - result.scanCodeRect.left) * scaleX,
          (result.scanCodeRect.bottom - result.scanCodeRect.top) * scaleY);
      }
      findings.push(finding);
    }
    return findings;
  }
}
