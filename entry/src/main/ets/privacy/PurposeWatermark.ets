import { drawing } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';

export class PurposeWatermark {
  static apply(pixelMap: image.PixelMap, text: string, opacity: number = 0.22,
    angle: number = -24, scale: number = 1, spacing: number = 1, color: string = '#FFFFFF'): void {
    const value: string = text.trim().slice(0, 40);
    if (value.length === 0) return;
    let info: image.ImageInfo;
    try {
      info = pixelMap.getImageInfoSync();
    } catch (_) {
      throw new Error('Unable to read image size for watermark.');
    }
    const width: number = info.size.width;
    const height: number = info.size.height;
    const fontSize: number = Math.max(20, Math.min(108,
      Math.round(Math.min(width, height) * 0.055 * Math.max(0.7, Math.min(1.6, scale)))));
    const font: drawing.Font = new drawing.Font();
    font.setSize(fontSize);
    font.enableEmbolden(true);
    const brush: drawing.Brush = new drawing.Brush();
    const channels: number[] = PurposeWatermark.parseColor(color);
    brush.setColor(Math.max(28, Math.min(180, Math.round(opacity * 255))),
      channels[0], channels[1], channels[2]);
    const canvas: drawing.Canvas = new drawing.Canvas(pixelMap);
    canvas.attachBrush(brush);
    const encoding: drawing.TextEncoding = drawing.TextEncoding.TEXT_ENCODING_UTF8;
    const blob: drawing.TextBlob = drawing.TextBlob.makeFromString(value, font, encoding);
    const textWidth: number = Math.max(fontSize * 4, font.measureText(value, encoding));
    const safeSpacing: number = Math.max(0.65, Math.min(1.8, spacing));
    const horizontalStep: number = Math.round((textWidth + fontSize * 2.5) * safeSpacing);
    const verticalStep: number = Math.round(fontSize * 3.4 * safeSpacing);
    canvas.save();
    canvas.rotate(Math.max(-60, Math.min(60, angle)), width / 2, height / 2);
    for (let y: number = -height; y < height * 2; y += verticalStep) {
      const rowOffset: number = Math.floor(y / verticalStep) % 2 === 0 ? 0 : -horizontalStep / 2;
      for (let x: number = -width + rowOffset; x < width * 2; x += horizontalStep) {
        canvas.drawTextBlob(blob, x, y);
      }
    }
    canvas.restore();
    canvas.detachBrush();
  }

  private static parseColor(value: string): number[] {
    const normalized: string = /^#[0-9A-Fa-f]{6}$/.test(value) ? value.substring(1) : 'FFFFFF';
    return [
      Number.parseInt(normalized.substring(0, 2), 16),
      Number.parseInt(normalized.substring(2, 4), 16),
      Number.parseInt(normalized.substring(4, 6), 16)
    ];
  }
}
