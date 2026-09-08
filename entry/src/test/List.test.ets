import { describe, expect, it } from '@ohos/hypium';
import { GifMetadata, GifMetadataSummary } from '../main/ets/metadata/GifMetadata';
import { ContainerMetadata, ContainerMetadataSummary } from '../main/ets/metadata/ContainerMetadata';
import { JpegMetadata, JpegMetadataSummary } from '../main/ets/metadata/JpegMetadata';
import { MediaCapabilityRegistry, SupportGrade } from '../main/ets/metadata/MediaCapabilityRegistry';
import { FileKind } from '../main/ets/processors/FileTypeRouter';
import { IsoBmffMetadataReader } from '../main/ets/processors/IsoBmffMetadataReader';

function bytes(values: number[]): Uint8Array {
  return new Uint8Array(values);
}

function uint32(value: number): number[] {
  return [(value >>> 24) & 0xFF, (value >>> 16) & 0xFF, (value >>> 8) & 0xFF, value & 0xFF];
}

function ascii(value: string): number[] {
  const output: number[] = [];
  for (let index: number = 0; index < value.length; index++) output.push(value.charCodeAt(index));
  return output;
}

function box(type: number[], payload: number[]): number[] {
  return uint32(payload.length + 8).concat(type, payload);
}

function textBox(type: string, payload: number[]): number[] {
  return box(ascii(type), payload);
}

function containsAscii(value: Uint8Array, needle: string): boolean {
  const target: number[] = ascii(needle);
  for (let offset: number = 0; offset + target.length <= value.length; offset++) {
    let matches: boolean = true;
    for (let index: number = 0; index < target.length; index++) {
      if (value[offset + index] !== target[index]) { matches = false; break; }
    }
    if (matches) return true;
  }
  return false;
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

  describe('JpegMetadata', (): void => {
    it('removes EXIF while preserving encoded image bytes', 0, (): void => {
      const exif: number[] = [0xFF, 0xE1, 0x00, 0x0A, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x01, 0x02];
      const scan: number[] = [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        0x11, 0x22, 0x33, 0xFF, 0xD9];
      const input: Uint8Array = bytes([0xFF, 0xD8].concat(exif, scan));
      const protectedBefore: Uint8Array = JpegMetadata.protectedMediaBytes(input);
      const output: Uint8Array = JpegMetadata.sanitize(input);
      const protectedAfter: Uint8Array = JpegMetadata.protectedMediaBytes(output);
      const result: JpegMetadataSummary = JpegMetadata.inspect(output);
      expect(result.exifCount).assertEqual(0);
      expect(protectedAfter.length).assertEqual(protectedBefore.length);
      for (let index: number = 0; index < protectedBefore.length; index++) {
        expect(protectedAfter[index]).assertEqual(protectedBefore[index]);
      }
    });

    it('keeps MovingPhoto XMP association while clearing private XMP values', 0, (): void => {
      const xmp: string = 'http://ns.adobe.com/xap/1.0/\u0000' +
        '<x GCamera:MicroVideoPresentationTimestampUs="123456" ' +
        'exif:DateTimeOriginal="2026:09:09 00:00:00"/>';
      const payload: number[] = ascii(xmp);
      const app1: number[] = [0xFF, 0xE1].concat([(payload.length + 2) >>> 8, (payload.length + 2) & 0xFF], payload);
      const scan: number[] = [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        0x44, 0x55, 0xFF, 0xD9];
      const cleaned: Uint8Array = JpegMetadata.sanitize(bytes([0xFF, 0xD8].concat(app1, scan)));
      expect(containsAscii(cleaned, 'GCamera:MicroVideoPresentationTimestampUs="123456"')).assertTrue();
      expect(containsAscii(cleaned, 'exif:DateTimeOriginal="2026:09:09 00:00:00"')).assertFalse();
    });
  });

  describe('MovingPhotoMetadata', (): void => {
    it('never classifies motion association keys as privacy metadata', 0, (): void => {
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey(
        'com.apple.quicktime.still-image-time')).assertFalse();
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey(
        'com.huawei.motionphoto.timestamp')).assertFalse();
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey(
        'GCamera:MicroVideoPresentationTimestampUs')).assertFalse();
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey(
        'com.apple.quicktime.content.identifier')).assertFalse();
    });

    it('continues to classify user-revealing container keys', 0, (): void => {
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey('com.apple.quicktime.location.ISO6709')).assertTrue();
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey('container.creationTime')).assertTrue();
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey('manufacturer')).assertTrue();
      expect(IsoBmffMetadataReader.isPrivacyMetadataKey('author')).assertTrue();
    });

    it('scrubs privacy values but retains the timed-photo anchor byte-for-byte', 0, (): void => {
      const locationKey: string = 'com.apple.quicktime.location.ISO6709';
      const anchorKey: string = 'com.apple.quicktime.still-image-time';
      const keyOne: number[] = uint32(locationKey.length + 8).concat(ascii('mdta'), ascii(locationKey));
      const keyTwo: number[] = uint32(anchorKey.length + 8).concat(ascii('mdta'), ascii(anchorKey));
      const keys: number[] = textBox('keys', [0, 0, 0, 0].concat(uint32(2), keyOne, keyTwo));
      const dataPrefix: number[] = [0, 0, 0, 1, 0, 0, 0, 0];
      const privateData: number[] = textBox('data', dataPrefix.concat(ascii('+31.2+121.5/')));
      const anchorValue: number[] = [0xFF];
      const anchorData: number[] = textBox('data', dataPrefix.concat(anchorValue));
      const privateItem: number[] = box([0, 0, 0, 1], privateData);
      const anchorItem: number[] = box([0, 0, 0, 2], anchorData);
      const ilst: number[] = textBox('ilst', privateItem.concat(anchorItem));
      const payload: Uint8Array = bytes(textBox('meta', [0, 0, 0, 0].concat(keys, ilst)));
      const cleaned: Uint8Array = IsoBmffMetadataReader.sanitizeMoovPayload(payload);
      expect(cleaned.length).assertEqual(payload.length);
      // The final byte is the functional still-image-time value.
      expect(cleaned[cleaned.length - 1]).assertEqual(0xFF);
      const items = IsoBmffMetadataReader.inspectMoovPayload(cleaned);
      // Binary association values are deliberately not surfaced as text;
      // the privacy entry must be gone while the byte assertion above proves
      // that the functional anchor survived.
      expect(items.length).assertEqual(0);
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
