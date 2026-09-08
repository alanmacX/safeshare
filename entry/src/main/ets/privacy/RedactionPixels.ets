/**
 * Single source of truth for redaction pixel effects. Both the sanitizer
 * (final output) and the on-screen preview run these exact routines so the
 * preview is pixel-identical to the delivered copy. Pure Uint8Array math:
 * safe to run inside a taskpool worker off the main thread.
 */
import { FindingCategory } from '../models/PrivacyModels';

export class RedactionPixels {
  static paddingFor(category: FindingCategory, regionWidth: number, regionHeight: number): number {
    const ratio: number = category === FindingCategory.QR ? 0.18 :
      (category === FindingCategory.FACE ? 0.12 : 0.08);
    return Math.max(8, Math.round(Math.max(regionWidth, regionHeight) * ratio));
  }

  static applySolidCover(pixels: Uint8Array, stride: number, left: number, top: number,
    right: number, bottom: number): void {
    for (let y: number = top; y < bottom; y++) {
      for (let x: number = left; x < right; x++) {
        const offset: number = y * stride + x * 4;
        pixels[offset] = 0;
        pixels[offset + 1] = 0;
        pixels[offset + 2] = 0;
        pixels[offset + 3] = 255;
      }
    }
  }

  static applyPixelate(pixels: Uint8Array, stride: number, left: number, top: number,
    right: number, bottom: number): void {
    const blockSize: number = Math.max(12, Math.min(40,
      Math.floor(Math.max(right - left, bottom - top) / 12)));
    for (let blockTop: number = top; blockTop < bottom; blockTop += blockSize) {
      for (let blockLeft: number = left; blockLeft < right; blockLeft += blockSize) {
        const blockRight: number = Math.min(right, blockLeft + blockSize);
        const blockBottom: number = Math.min(bottom, blockTop + blockSize);
        let red: number = 0;
        let green: number = 0;
        let blue: number = 0;
        let samples: number = 0;
        for (let y: number = blockTop; y < blockBottom; y++) {
          for (let x: number = blockLeft; x < blockRight; x++) {
            const offset: number = y * stride + x * 4;
            red += pixels[offset];
            green += pixels[offset + 1];
            blue += pixels[offset + 2];
            samples++;
          }
        }
        const color: number[] = samples > 0 ?
          [Math.floor(red / samples), Math.floor(green / samples), Math.floor(blue / samples)] :
          [32, 32, 32];
        for (let y: number = blockTop; y < blockBottom; y++) {
          for (let x: number = blockLeft; x < blockRight; x++) {
            const offset: number = y * stride + x * 4;
            pixels[offset] = color[0];
            pixels[offset + 1] = color[1];
            pixels[offset + 2] = color[2];
            pixels[offset + 3] = 255;
          }
        }
      }
    }
  }

  static applyBlur(pixels: Uint8Array, stride: number, left: number, top: number,
    right: number, bottom: number): void {
    const regionWidth: number = right - left;
    const regionHeight: number = bottom - top;
    const radius: number = Math.max(10, Math.min(48, Math.floor(Math.max(regionWidth, regionHeight) / 10)));
    const passes: number = radius > 24 ? 3 : 2;
    for (let pass: number = 0; pass < passes; pass++) {
      const snapshot: Uint8Array = new Uint8Array(regionWidth * regionHeight * 4);
      for (let y: number = top; y < bottom; y++) {
        for (let x: number = left; x < right; x++) {
          const sourceOffset: number = y * stride + x * 4;
          const snapshotOffset: number = ((y - top) * regionWidth + x - left) * 4;
          snapshot[snapshotOffset] = pixels[sourceOffset];
          snapshot[snapshotOffset + 1] = pixels[sourceOffset + 1];
          snapshot[snapshotOffset + 2] = pixels[sourceOffset + 2];
          snapshot[snapshotOffset + 3] = 255;
        }
      }
      for (let y: number = top; y < bottom; y++) {
        for (let x: number = left; x < right; x++) {
          let red: number = 0;
          let green: number = 0;
          let blue: number = 0;
          let samples: number = 0;
          for (let sampleY: number = -radius; sampleY <= radius; sampleY += radius) {
            for (let sampleX: number = -radius; sampleX <= radius; sampleX += radius) {
              const localX: number = Math.max(0, Math.min(regionWidth - 1, x - left + sampleX));
              const localY: number = Math.max(0, Math.min(regionHeight - 1, y - top + sampleY));
              const offset: number = (localY * regionWidth + localX) * 4;
              red += snapshot[offset];
              green += snapshot[offset + 1];
              blue += snapshot[offset + 2];
              samples++;
            }
          }
          const offset: number = y * stride + x * 4;
          pixels[offset] = Math.floor(red / samples);
          pixels[offset + 1] = Math.floor(green / samples);
          pixels[offset + 2] = Math.floor(blue / samples);
          pixels[offset + 3] = 255;
        }
      }
    }
  }
}

