import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { MovingPhotoContainer } from './MovingPhotoContainer';

/**
 * MovingPhoto gate. Detection only — SafeShare refuses motion photos.
 *
 * Probe must stay cheap: a 50-photo batch previously opened each file and
 * read it end-to-end. We only sniff a small head for motion XMP / JPEG SOI
 * and skip the rest unless that sniff already says “motion”.
 */
export class MovingPhotoPrivacyTool {
  private static readonly SNIFF_BYTES: number = 64 * 1024;
  private cache: Map<string, boolean> = new Map();

  constructor(context: common.UIAbilityContext) {
  }

  async isMovingPhoto(uri: string): Promise<boolean> {
    const cached: boolean | undefined = this.cache.get(uri);
    if (cached !== undefined) return cached;
    const result: boolean = await this.detect(uri);
    this.cache.set(uri, result);
    return result;
  }

  assertSupported(): void {
    throw new Error('MOVING_PHOTO_UNSUPPORTED');
  }

  private async detect(uri: string): Promise<boolean> {
    const head: Uint8Array | undefined = await this.readRange(uri, 0,
      MovingPhotoPrivacyTool.SNIFF_BYTES);
    if (head === undefined) return false;
    // Still JPEG/PNG/HEIF without motion XMP → not a motion photo. No tail read.
    if (MovingPhotoContainer.hasMotionXmp(head)) return true;
    if (MovingPhotoContainer.looksLikeMovingPhoto(head)) return true;
    // Composite whose XMP sits past the sniff window is rare; only then
    // inspect a short tail for EOI+ftyp.
    if (MovingPhotoContainer.jpegStillEnd(head) === 0) {
      const size: number = await this.fileSize(uri);
      if (size > MovingPhotoPrivacyTool.SNIFF_BYTES) {
        const tail: Uint8Array | undefined = await this.readRange(uri,
          Math.max(0, size - 32 * 1024), 32 * 1024);
        if (tail !== undefined && MovingPhotoContainer.looksLikeMovingPhoto(tail)) {
          return true;
        }
      }
    }
    return false;
  }

  private async fileSize(uri: string): Promise<number> {
    let source: fileIo.File | undefined = undefined;
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      return fileIo.statSync(source.fd).size;
    } catch (_) {
      return 0;
    } finally {
      try {
        if (source !== undefined) fileIo.closeSync(source);
      } catch (_) {}
    }
  }

  private async readRange(uri: string, offset: number, length: number): Promise<Uint8Array | undefined> {
    let source: fileIo.File | undefined = undefined;
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(source.fd).size;
      if (size <= 0) return undefined;
      const want: number = Math.min(length, Math.max(0, size - offset));
      if (want <= 0) return undefined;
      const buffer: ArrayBuffer = new ArrayBuffer(want);
      fileIo.lseek(source.fd, offset, fileIo.WhenceType.SEEK_SET);
      let readTotal: number = 0;
      while (readTotal < want) {
        const read: number = await fileIo.read(source.fd, buffer, {
          offset: readTotal, length: want - readTotal
        });
        if (read <= 0) break;
        readTotal += read;
      }
      if (readTotal <= 0) return undefined;
      return new Uint8Array(buffer, 0, readTotal);
    } catch (_) {
      return undefined;
    } finally {
      try {
        if (source !== undefined) fileIo.closeSync(source);
      } catch (_) {}
    }
  }
}
