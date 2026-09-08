import { describe, expect, it } from '@ohos/hypium';
import { GifMetadata, GifMetadataSummary } from '../main/ets/metadata/GifMetadata';
import { ContainerMetadata, ContainerMetadataSummary } from '../main/ets/metadata/ContainerMetadata';
import { MediaCapabilityRegistry, SupportGrade } from '../main/ets/metadata/MediaCapabilityRegistry';
import { FileKind } from '../main/ets/processors/FileTypeRouter';

function bytes(values: number[]): Uint8Array {
  return new Uint8Array(values);
}

export default function testsuite(): void {
  describe('GifMetadata', (): void => {
    it('removes metadata without changing animation blocks', 0, (): void => {
      const headerAndPalette: number[] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF
      ];
      const loop: number[] = [0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45,
        0x32, 0x2E, 0x30, 0x03, 0x01, 0x00, 0x00, 0x00];
      const comment: number[] = [0x21, 0xFE, 0x03, 0x70, 0x69, 0x69, 0x00];
      const xmp: number[] = [0x21, 0xFF, 0x0B, 0x58, 0x4D, 0x50, 0x20, 0x44, 0x61, 0x74, 0x61,
        0x58, 0x4D, 0x50, 0x01, 0x78, 0x00];
      const frame: number[] = [0x21, 0xF9, 0x04, 0x00, 0x05, 0x00, 0x00, 0x00,
        0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x02, 0x02, 0x44, 0x01, 0x00, 0x3B];
      const input: Uint8Array = bytes(headerAndPalette.concat(loop, comment, xmp, frame));
      const output: Uint8Array = GifMetadata.sanitize(input);
      const expected: Uint8Array = bytes(headerAndPalette.concat(loop, frame));
      expect(output.length).assertEqual(expected.length);
      for (let index: number = 0; index < expected.length; index++) {
        expect(output[index]).assertEqual(expected[index]);
      }
      const result: GifMetadataSummary = GifMetadata.inspect(output);
      expect(result.commentCount).assertEqual(0);
      expect(result.applicationMetadataCount).assertEqual(0);
    });

    it('rejects a truncated container', 0, (): void => {
      let rejected: boolean = false;
      try {
        GifMetadata.inspect(bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]));
      } catch (_) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });

  describe('ContainerMetadata', (): void => {
    it('removes WebP EXIF and XMP while retaining animation chunks', 0, (): void => {
      const body: number[] = [
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x58, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00,
        0x45, 0x58, 0x49, 0x46, 0x02, 0x00, 0x00, 0x00, 0x01, 0x02,
        0x58, 0x4D, 0x50, 0x20, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00,
        0x41, 0x4E, 0x49, 0x4D, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00
      ];
      const input: Uint8Array = new Uint8Array(body.length + 8);
      input.set(bytes([0x52, 0x49, 0x46, 0x46, body.length, 0, 0, 0]), 0);
      input.set(bytes(body), 8);
      const output: Uint8Array = ContainerMetadata.sanitizeWebp(input);
      const result: ContainerMetadataSummary = ContainerMetadata.inspectWebp(output);
      expect(result.exifCount).assertEqual(0);
      expect(result.xmpCount).assertEqual(0);
      let hasAnimation: boolean = false;
      for (let index: number = 0; index + 3 < output.length; index++) {
        if (output[index] === 0x41 && output[index + 1] === 0x4E &&
          output[index + 2] === 0x49 && output[index + 3] === 0x4D) hasAnimation = true;
      }
      expect(hasAnimation).assertTrue();
    });
  });

  describe('MediaCapabilityRegistry', (): void => {
    it('keeps animated and HDR-safe formats metadata-only', 0, (): void => {
      const gif = MediaCapabilityRegistry.image('image/gif', true);
      const heif = MediaCapabilityRegistry.image('image/heif', false);
      expect(gif.metadataClean).assertTrue();
      expect(gif.face).assertFalse();
      expect(gif.textWatermark).assertFalse();
      expect(heif.losslessMetadata).assertTrue();
      expect(heif.imageWatermark).assertFalse();
    });

    it('opens visual tools only for eligible still images', 0, (): void => {
      const jpeg = MediaCapabilityRegistry.image('image/jpeg', false);
      const tiff = MediaCapabilityRegistry.image('image/tiff', false);
      expect(jpeg.face).assertTrue();
      expect(jpeg.qr).assertTrue();
      expect(tiff.face).assertFalse();
      expect(tiff.metadataClean).assertTrue();
    });

    it('marks unsupported audio cleanup before processing', 0, (): void => {
      const audio = MediaCapabilityRegistry.forResult(FileKind.AUDIO_VIDEO,
        'audio/mpeg', false, false, true);
      expect(audio.grade).assertEqual(SupportGrade.READ_ONLY);
      expect(audio.metadataScan).assertTrue();
      expect(audio.metadataClean).assertFalse();
    });
  });
}
