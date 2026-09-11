/**
 * Permission-free MovingPhoto container analysis.
 *
 * API 24 `MediaAssetManager.requestMovingPhoto` and `MovingPhoto.requestContent`
 * both declare `@permission ohos.permission.READ_IMAGEVIDEO`. SafeShare does not
 * request that restricted permission, so Media Library export is not a viable
 * path for picker/share URIs. Huawei/Google motion photos that arrive as a
 * single authorized file are a JPEG/HEIF cover with an ISO-BMFF video appended
 * after the still-image end marker. This module only inspects those bytes.
 */
export class MovingPhotoLayout {
  isComposite: boolean = false;
  imageEnd: number = 0;
  videoStart: number = 0;
  videoLength: number = 0;
  reason: string = '';
}

export class MovingPhotoContainer {
  static readonly MOTION_XMP_MARKERS: string[] = [
    'GCamera:MicroVideo',
    'GCamera:MotionPhoto',
    'HwMotionPhoto:MotionPhoto',
    'HwMotionPhoto:Version',
    'Camera:MotionPhoto',
    'MotionPhotoPresentationTimestampUs'
  ];

  static inspect(bytes: Uint8Array): MovingPhotoLayout {
    const layout: MovingPhotoLayout = new MovingPhotoLayout();
    if (bytes.length < 32) {
      layout.reason = 'too-small';
      return layout;
    }
    const jpegEnd: number = MovingPhotoContainer.jpegStillEnd(bytes);
    if (jpegEnd <= 0) {
      layout.reason = 'not-jpeg-still';
      return layout;
    }
    const videoStart: number = MovingPhotoContainer.videoStartAfterJpeg(bytes, jpegEnd);
    if (videoStart <= jpegEnd || videoStart >= bytes.length) {
      // A motion UTD can still be a still-only share payload. Keep the
      // classifier honest: no trailing ISO-BMFF means no video component.
      layout.reason = MovingPhotoContainer.hasMotionXmp(bytes) ? 'xmp-without-video' : 'still-only';
      layout.imageEnd = jpegEnd;
      return layout;
    }
    if (!MovingPhotoContainer.isIsoBmffAt(bytes, videoStart)) {
      layout.reason = 'trailing-not-isobmff';
      layout.imageEnd = jpegEnd;
      return layout;
    }
    layout.isComposite = true;
    layout.imageEnd = jpegEnd;
    layout.videoStart = videoStart;
    layout.videoLength = bytes.length - videoStart;
    layout.reason = 'jpeg+isobmff';
    return layout;
  }

  static looksLikeMovingPhoto(bytes: Uint8Array): boolean {
    const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(bytes);
    return layout.isComposite || MovingPhotoContainer.hasMotionXmp(bytes);
  }

  static split(bytes: Uint8Array): MovingPhotoLayout {
    const layout: MovingPhotoLayout = MovingPhotoContainer.inspect(bytes);
    if (!layout.isComposite) {
      throw new Error('MOVING_PHOTO_COMPOSITE_NOT_FOUND');
    }
    return layout;
  }

  static imageSlice(bytes: Uint8Array, layout: MovingPhotoLayout): Uint8Array {
    return bytes.slice(0, layout.imageEnd);
  }

  static videoSlice(bytes: Uint8Array, layout: MovingPhotoLayout): Uint8Array {
    return bytes.slice(layout.videoStart, layout.videoStart + layout.videoLength);
  }

  /**
   * Rebuilds a single shareable motion-photo file: still cover (with
   * association XMP) + ISO-BMFF video appended after JPEG EOI. Share Kit
   * and Gallery identify MovingPhoto from this composite, not from
   * loadMovingPhoto's ephemeral object URI.
   */
  static compose(coverBytes: Uint8Array, videoBytes: Uint8Array): Uint8Array {
    if (coverBytes.length < 4 || coverBytes[0] !== 0xFF || coverBytes[1] !== 0xD8) {
      throw new Error('MOVING_PHOTO_COVER_NOT_JPEG');
    }
    if (!MovingPhotoContainer.isIsoBmffAt(videoBytes, 0)) {
      throw new Error('MOVING_PHOTO_VIDEO_NOT_ISOBMFF');
    }
    const coverEnd: number = MovingPhotoContainer.jpegStillEnd(coverBytes);
    if (coverEnd <= 0) throw new Error('MOVING_PHOTO_COVER_TRUNCATED');
    const cover: Uint8Array = coverBytes.length === coverEnd ?
      coverBytes : coverBytes.slice(0, coverEnd);
    const marked: Uint8Array = MovingPhotoContainer.ensureMotionXmp(cover, videoBytes.length);
    const output: Uint8Array = new Uint8Array(marked.length + videoBytes.length);
    output.set(marked, 0);
    output.set(videoBytes, marked.length);
    return output;
  }

  /**
   * Refreshes GCamera/HwMotionPhoto association XMP so MicroVideoOffset
   * matches the appended video length. Existing motion keys are preserved;
   * only the offset value is rewritten. If the cleaned cover lost all motion
   * XMP, inject the minimal Google/Huawei keys used by system Gallery.
   */
  static ensureMotionXmp(jpeg: Uint8Array, videoLength: number): Uint8Array {
    if (videoLength <= 0) throw new Error('MOVING_PHOTO_VIDEO_EMPTY');
    const offsetText: string = `${videoLength}`;
    const updated: Uint8Array | undefined =
      MovingPhotoContainer.rewriteMotionXmpOffset(jpeg, offsetText);
    if (updated !== undefined) return updated;
    return MovingPhotoContainer.injectMotionXmp(jpeg, offsetText);
  }

  private static rewriteMotionXmpOffset(jpeg: Uint8Array, offsetText: string): Uint8Array | undefined {
    let cursor: number = 2;
    while (cursor + 4 < jpeg.length) {
      if (jpeg[cursor] !== 0xFF) return undefined;
      while (cursor < jpeg.length && jpeg[cursor] === 0xFF) cursor++;
      if (cursor >= jpeg.length) return undefined;
      const marker: number = jpeg[cursor++];
      if (marker === 0xDA || marker === 0xD9) return undefined;
      if (marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
      if (cursor + 2 > jpeg.length) return undefined;
      const segmentLength: number = (jpeg[cursor] << 8) | jpeg[cursor + 1];
      const end: number = cursor + segmentLength;
      if (segmentLength < 2 || end > jpeg.length) return undefined;
      const payloadStart: number = cursor + 2;
      const isXmp: boolean = marker === 0xE1 &&
        MovingPhotoContainer.startsWithAscii(jpeg, payloadStart, 'http://ns.adobe.com/xap/1.0/\u0000');
      if (isXmp) {
        const payload: Uint8Array = jpeg.slice(payloadStart, end);
        const textStart: number = MovingPhotoContainer.indexOfAscii(payload, 'MicroVideoOffset', 0);
        if (textStart < 0) return undefined;
        const quote: number = MovingPhotoContainer.indexOfByte(payload, 0x22, textStart);
        if (quote < 0) return undefined;
        const valueStart: number = quote + 1;
        const valueEnd: number = MovingPhotoContainer.indexOfByte(payload, 0x22, valueStart);
        if (valueEnd < 0) return undefined;
        const head: Uint8Array = payload.slice(0, valueStart);
        const tail: Uint8Array = payload.slice(valueEnd);
        const valueBytes: Uint8Array = new Uint8Array(offsetText.length);
        for (let index: number = 0; index < offsetText.length; index++) {
          valueBytes[index] = offsetText.charCodeAt(index);
        }
        const nextPayload: Uint8Array = new Uint8Array(head.length + valueBytes.length + tail.length);
        nextPayload.set(head, 0);
        nextPayload.set(valueBytes, head.length);
        nextPayload.set(tail, head.length + valueBytes.length);
        const nextLength: number = nextPayload.length + 2;
        if (nextLength > 0xFFFF) return undefined;
        const app1: Uint8Array = new Uint8Array(4 + nextPayload.length);
        app1[0] = 0xFF;
        app1[1] = 0xE1;
        app1[2] = (nextLength >> 8) & 0xFF;
        app1[3] = nextLength & 0xFF;
        app1.set(nextPayload, 4);
        const segmentStart: number = cursor - 2;
        const before: Uint8Array = jpeg.slice(0, segmentStart);
        const after: Uint8Array = jpeg.slice(end);
        const output: Uint8Array = new Uint8Array(before.length + app1.length + after.length);
        output.set(before, 0);
        output.set(app1, before.length);
        output.set(after, before.length + app1.length);
        return output;
      }
      cursor = end;
    }
    return undefined;
  }

  private static injectMotionXmp(jpeg: Uint8Array, offsetText: string): Uint8Array {
    const xmpBody: string =
      'http://ns.adobe.com/xap/1.0/\u0000' +
      '<x:xmpmeta xmlns:x="adobe:ns:meta/">' +
      '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
      '<rdf:Description rdf:about="" ' +
      'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" ' +
      'xmlns:HwMotionPhoto="http://www.huawei.com/photos/1.0/motionphoto/" ' +
      `GCamera:MicroVideo="1" GCamera:MicroVideoOffset="${offsetText}" ` +
      'HwMotionPhoto:MotionPhoto="1" HwMotionPhoto:Version="1"/>' +
      '</rdf:RDF></x:xmpmeta>';
    const payload: Uint8Array = new Uint8Array(xmpBody.length);
    for (let index: number = 0; index < xmpBody.length; index++) {
      payload[index] = xmpBody.charCodeAt(index) & 0xFF;
    }
    const segmentLength: number = payload.length + 2;
    if (segmentLength > 0xFFFF) throw new Error('MOVING_PHOTO_XMP_TOO_LARGE');
    const app1: Uint8Array = new Uint8Array(4 + payload.length);
    app1[0] = 0xFF;
    app1[1] = 0xE1;
    app1[2] = (segmentLength >> 8) & 0xFF;
    app1[3] = segmentLength & 0xFF;
    app1.set(payload, 4);
    const output: Uint8Array = new Uint8Array(jpeg.length + app1.length);
    output.set(jpeg.subarray(0, 2), 0);
    output.set(app1, 2);
    output.set(jpeg.subarray(2), 2 + app1.length);
    return output;
  }

  private static startsWithAscii(bytes: Uint8Array, start: number, value: string): boolean {
    if (start + value.length > bytes.length) return false;
    for (let index: number = 0; index < value.length; index++) {
      if (bytes[start + index] !== value.charCodeAt(index)) return false;
    }
    return true;
  }

  private static indexOfAscii(bytes: Uint8Array, value: string, start: number): number {
    for (let offset: number = start; offset + value.length <= bytes.length; offset++) {
      if (MovingPhotoContainer.startsWithAscii(bytes, offset, value)) return offset;
    }
    return -1;
  }

  private static indexOfByte(bytes: Uint8Array, value: number, start: number): number {
    for (let offset: number = start; offset < bytes.length; offset++) {
      if (bytes[offset] === value) return offset;
    }
    return -1;
  }

  /**
   * Walk JPEG markers and return the exclusive end of the still image
   * (index just after FFD9). Trailing motion-photo video is never included.
   */
  static jpegStillEnd(bytes: Uint8Array): number {
    if (bytes.length < 4 || bytes[0] !== 0xFF || bytes[1] !== 0xD8) return 0;
    let cursor: number = 2;
    while (cursor + 1 < bytes.length) {
      if (bytes[cursor] !== 0xFF) {
        // Entropy-coded scan payload. Find the next marker start.
        const next: number = MovingPhotoContainer.indexOfMarker(bytes, cursor);
        if (next < 0) return 0;
        cursor = next;
        continue;
      }
      while (cursor < bytes.length && bytes[cursor] === 0xFF) cursor++;
      if (cursor >= bytes.length) return 0;
      const marker: number = bytes[cursor++];
      if (marker === 0xD9) return cursor;
      if (marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
      if (marker === 0xDA) {
        // Start of scan: consume entropy until EOI.
        const eoi: number = MovingPhotoContainer.indexOfEoi(bytes, cursor);
        return eoi > 0 ? eoi : 0;
      }
      if (cursor + 2 > bytes.length) return 0;
      const segmentLength: number = (bytes[cursor] << 8) | bytes[cursor + 1];
      if (segmentLength < 2 || cursor + segmentLength > bytes.length) return 0;
      cursor += segmentLength;
    }
    return 0;
  }

  static hasMotionXmp(bytes: Uint8Array): boolean {
    const text: string = MovingPhotoContainer.asciiWindow(bytes, 0, Math.min(bytes.length, 512 * 1024));
    for (let index: number = 0; index < MovingPhotoContainer.MOTION_XMP_MARKERS.length; index++) {
      if (text.indexOf(MovingPhotoContainer.MOTION_XMP_MARKERS[index]) >= 0) return true;
    }
    // Google MicroVideoOffset without the boolean still marks a motion payload.
    return text.indexOf('MicroVideoOffset') >= 0;
  }

  private static videoStartAfterJpeg(bytes: Uint8Array, jpegEnd: number): number {
    // ISO-BMFF box sizes are big-endian and commonly start with 0x00 bytes.
    // Never skip leading zeros here — that walks into the middle of ftyp.
    // A valid motion photo places the video immediately after still-image EOI.
    if (MovingPhotoContainer.isIsoBmffAt(bytes, jpegEnd)) return jpegEnd;
    // MicroVideoOffset is documented as the byte count from EOF to the video
    // start (equivalently the video length). Accept it only when it lands on
    // an ISO-BMFF header so a stale XMP value cannot invent a fake video.
    const offset: number = MovingPhotoContainer.microVideoOffset(bytes);
    if (offset > 0 && offset < bytes.length) {
      const fromEnd: number = bytes.length - offset;
      if (fromEnd >= jpegEnd && MovingPhotoContainer.isIsoBmffAt(bytes, fromEnd)) return fromEnd;
    }
    return -1;
  }

  private static microVideoOffset(bytes: Uint8Array): number {
    const window: string = MovingPhotoContainer.asciiWindow(bytes, 0, Math.min(bytes.length, 512 * 1024));
    const key: string = 'MicroVideoOffset';
    const index: number = window.indexOf(key);
    if (index < 0) return 0;
    let cursor: number = index + key.length;
    while (cursor < window.length && (window.charAt(cursor) === ' ' || window.charAt(cursor) === '"' ||
      window.charAt(cursor) === '=' || window.charAt(cursor) === '\'')) {
      cursor++;
    }
    let value: string = '';
    while (cursor < window.length && window.charAt(cursor) >= '0' && window.charAt(cursor) <= '9') {
      value += window.charAt(cursor);
      cursor++;
      if (value.length > 16) break;
    }
    if (value.length === 0) return 0;
    const parsed: number = Number.parseInt(value, 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  }

  static isIsoBmffAt(bytes: Uint8Array, start: number): boolean {
    if (start < 0 || start + 12 > bytes.length) return false;
    const type: string = String.fromCharCode(bytes[start + 4], bytes[start + 5],
      bytes[start + 6], bytes[start + 7]);
    return type === 'ftyp';
  }

  private static indexOfMarker(bytes: Uint8Array, start: number): number {
    for (let index: number = start; index + 1 < bytes.length; index++) {
      if (bytes[index] === 0xFF && bytes[index + 1] !== 0x00 && bytes[index + 1] !== 0xFF) {
        return index;
      }
    }
    return -1;
  }

  private static indexOfEoi(bytes: Uint8Array, start: number): number {
    for (let index: number = start; index + 1 < bytes.length; index++) {
      if (bytes[index] === 0xFF && bytes[index + 1] === 0xD9) return index + 2;
    }
    return -1;
  }

  private static asciiWindow(bytes: Uint8Array, start: number, end: number): string {
    const limit: number = Math.min(end, bytes.length);
    let value: string = '';
    // XMP is ASCII; scanning only the head keeps large HDR payloads cheap.
    for (let index: number = start; index < limit; index++) {
      const byte: number = bytes[index];
      if (byte === 0) continue;
      value += byte >= 0x20 && byte < 0x7F ? String.fromCharCode(byte) : ' ';
    }
    return value;
  }
}
