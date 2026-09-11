import { describe, expect, it } from '@ohos/hypium';
import { GifMetadata, GifMetadataSummary } from '../main/ets/metadata/GifMetadata';
import { ContainerMetadata, ContainerMetadataSummary } from '../main/ets/metadata/ContainerMetadata';
import { JpegMetadata, JpegMetadataSummary } from '../main/ets/metadata/JpegMetadata';
import { MediaCapabilityRegistry, SupportGrade } from '../main/ets/metadata/MediaCapabilityRegistry';
import { FileKind } from '../main/ets/processors/FileTypeRouter';
import { IsoBmffMetadataReader } from '../main/ets/processors/IsoBmffMetadataReader';
import { MovingPhotoContainer, MovingPhotoLayout } from '../main/ets/processors/MovingPhotoContainer';
import { HeifMetadata } from '../main/ets/metadata/HeifMetadata';
import { Mp3Metadata, Mp3MetadataSummary } from '../main/ets/metadata/Mp3Metadata';
import { FlacMetadata } from '../main/ets/metadata/FlacMetadata';
import { WavMetadata } from '../main/ets/metadata/WavMetadata';

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

  describe('MovingPhotoContainer', (): void => {
    function jpegWithXmp(xmp: string, scanPayload: number[]): number[] {
      const payload: number[] = ascii('http://ns.adobe.com/xap/1.0/\u0000' + xmp);
      const app1: number[] = [0xFF, 0xE1].concat(
        [((payload.length + 2) >>> 8) & 0xFF, (payload.length + 2) & 0xFF], payload);
      const scan: number[] = [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]
        .concat(scanPayload, [0xFF, 0xD9]);
      return [0xFF, 0xD8].concat(app1, scan);
    }

    function minimalMp4(extra: number[] = []): number[] {
      const ftyp: number[] = textBox('ftyp', ascii('isom').concat([0, 0, 0, 0], ascii('isom')));
      const free: number[] = textBox('free', extra.length > 0 ? extra : ascii('privacy'));
      return ftyp.concat(free);
    }

    it('splits a Huawei/Google style JPEG+MP4 composite', 0, (): void => {
      const xmp: string = 'GCamera:MicroVideo="1" GCamera:MicroVideoOffset="40" ' +
        'exif:DateTimeOriginal="2026:01:02 03:04:05"';
      const jpeg: number[] = jpegWithXmp(xmp, [0x11, 0x22, 0x33]);
      const video: number[] = minimalMp4();
      const composite: Uint8Array = bytes(jpeg.concat(video));
      const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(composite);
      expect(layout.isComposite).assertTrue();
      expect(layout.imageEnd).assertEqual(jpeg.length);
      expect(layout.videoStart).assertEqual(jpeg.length);
      expect(layout.videoLength).assertEqual(video.length);
      const imageSlice: Uint8Array = MovingPhotoContainer.imageSlice(composite, layout);
      const videoSlice: Uint8Array = MovingPhotoContainer.videoSlice(composite, layout);
      expect(imageSlice.length).assertEqual(jpeg.length);
      expect(videoSlice.length).assertEqual(video.length);
      expect(MovingPhotoContainer.isIsoBmffAt(videoSlice, 0)).assertTrue();
      // Cover still ends at FFD9; trailing video is never part of the JPEG.
      expect(imageSlice[imageSlice.length - 1]).assertEqual(0xD9);
      expect(imageSlice[imageSlice.length - 2]).assertEqual(0xFF);
    });

    it('keeps a still-only JPEG classified as non-composite', 0, (): void => {
      const jpeg: Uint8Array = bytes(jpegWithXmp('GCamera:MicroVideo="1"', [0x44]));
      const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(jpeg);
      expect(layout.isComposite).assertFalse();
      expect(MovingPhotoContainer.hasMotionXmp(jpeg)).assertTrue();
    });

    it('does not invent a video when trailing bytes are not ISO-BMFF', 0, (): void => {
      const jpeg: number[] = jpegWithXmp('GCamera:MicroVideo="1"', [0x55]);
      const garbage: Uint8Array = bytes(jpeg.concat([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]));
      const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(garbage);
      expect(layout.isComposite).assertFalse();
      expect(layout.reason).assertEqual('trailing-not-isobmff');
    });

    it('rebuilds a shareable composite with a refreshed MicroVideoOffset', 0, (): void => {
      const jpeg: number[] = jpegWithXmp('GCamera:MicroVideo="1" GCamera:MicroVideoOffset="0040"', [0x21]);
      const video: number[] = minimalMp4([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
      const composed: Uint8Array = MovingPhotoContainer.compose(bytes(jpeg), bytes(video));
      const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(composed);
      expect(layout.isComposite).assertTrue();
      expect(layout.videoLength).assertEqual(video.length);
      expect(containsAscii(composed, `GCamera:MicroVideoOffset="${video.length}"`)).assertTrue();
      expect(MovingPhotoContainer.looksLikeMovingPhoto(composed)).assertTrue();
    });

    it('injects motion XMP when the cleaned cover lost association keys', 0, (): void => {
      const plainJpeg: number[] = jpegWithXmp('tiff:Make="HUAWEI"', [0x31]);
      const video: number[] = minimalMp4([0x0A]);
      const composed: Uint8Array = MovingPhotoContainer.compose(bytes(plainJpeg), bytes(video));
      expect(containsAscii(composed, 'GCamera:MicroVideo="1"')).assertTrue();
      expect(containsAscii(composed, `GCamera:MicroVideoOffset="${video.length}"`)).assertTrue();
      const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(composed);
      expect(layout.isComposite).assertTrue();
      expect(layout.videoStart).assertEqual(MovingPhotoContainer.jpegStillEnd(composed));
    });
  });

  describe('HeifMetadata', (): void => {
    it('detects HEIF brands and rejects non-HEIF', 0, (): void => {
      const heif: Uint8Array = bytes([
        0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63,
        0, 0, 0, 0, 0x68, 0x65, 0x69, 0x63, 0, 0, 0, 0
      ]);
      expect(HeifMetadata.isHeif(heif)).assertTrue();
      expect(HeifMetadata.isHeif(bytes([0xFF, 0xD8, 0xFF]))).assertFalse();
    });
  });

  describe('Mp3Metadata', (): void => {
    it('strips ID3v2/ID3v1 and keeps audio frames', 0, (): void => {
      const id3v2: number[] = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      const frame: number[] = [0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22, 0x33, 0x44];
      const id3v1: number[] = [];
      id3v1.push(0x54, 0x41, 0x47);
      for (let i: number = 0; i < 125; i++) id3v1.push(0x20);
      const input: Uint8Array = bytes(id3v2.concat(frame, id3v1));
      const output: Uint8Array = Mp3Metadata.sanitize(input);
      expect(output.length).assertEqual(frame.length);
      expect(output[0]).assertEqual(0xFF);
      const summary: Mp3MetadataSummary = Mp3Metadata.inspect(output);
      expect(summary.id3v2Count).assertEqual(0);
      expect(summary.id3v1Count).assertEqual(0);
    });
  });

  describe('FlacMetadata', (): void => {
    it('keeps STREAMINFO and drops Vorbis Comment', 0, (): void => {
      // fLaC + STREAMINFO (type 0, len 4) + VORBIS_COMMENT (type 4, len 4) + last flag
      const streamInfo: number[] = [0x00, 0x00, 0x00, 0x04, 1, 2, 3, 4];
      const comment: number[] = [0x84, 0x00, 0x00, 0x04, 0x76, 0x6F, 0x72, 0x62];
      const frames: number[] = [0xFF, 0xF8, 0x01, 0x02, 0x03];
      const input: Uint8Array = bytes([0x66, 0x4C, 0x61, 0x43].concat(streamInfo, comment, frames));
      const output: Uint8Array = FlacMetadata.sanitize(input);
      expect(output.length).assertEqual(4 + streamInfo.length + frames.length);
      expect(FlacMetadata.inspect(output).vorbisCommentCount).assertEqual(0);
      expect(output[output.length - 1]).assertEqual(0x03);
    });
  });

  describe('WavMetadata', (): void => {
    it('keeps fmt/data and drops LIST INFO', 0, (): void => {
      const header: number[] = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45];
      const fmt: number[] = [0x66, 0x6D, 0x74, 0x20, 2, 0, 0, 0, 0x01, 0x00];
      const data: number[] = [0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0x11, 0x22];
      const list: number[] = [0x4C, 0x49, 0x53, 0x54, 4, 0, 0, 0, 0x49, 0x4E, 0x46, 0x4F];
      const input: Uint8Array = bytes(header.concat(fmt, data, list));
      // Patch RIFF size
      const total: number = input.length;
      input[4] = (total - 8) & 0xFF;
      input[5] = ((total - 8) >> 8) & 0xFF;
      const output: Uint8Array = WavMetadata.sanitize(input);
      expect(WavMetadata.inspect(output).listInfoCount).assertEqual(0);
      expect(WavMetadata.isWav(output)).assertTrue();
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

    it('marks moving photos unsupported', 0, (): void => {
      const moving = MediaCapabilityRegistry.movingPhoto();
      expect(moving.grade).assertEqual(SupportGrade.UNSUPPORTED);
      expect(moving.metadataClean).assertFalse();
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
