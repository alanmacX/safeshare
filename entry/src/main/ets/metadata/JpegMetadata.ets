export class JpegMetadataSummary {
  commentCount: number = 0;
  iptcCount: number = 0;
  privateXmpCount: number = 0;
  exifCount: number = 0;
}

/**
 * Rewrites only JPEG metadata segments before SOS. Entropy-coded image data,
 * ICC/MPF/JUMBF blocks and HDR gain-map XMP properties remain byte-identical.
 */
export class JpegMetadata {
  private static readonly PRIVATE_XMP_KEYS: string[] = [
    'exif:GPSLatitude', 'exif:GPSLongitude', 'exif:GPSAltitude', 'exif:GPSDateStamp',
    'exif:DateTimeOriginal', 'exif:DateTimeDigitized', 'tiff:DateTime', 'photoshop:DateCreated',
    'tiff:Make', 'tiff:Model', 'aux:SerialNumber', 'aux:LensSerialNumber', 'aux:OwnerName',
    'xmp:CreatorTool', 'xmp:MetadataDate', 'xmp:ModifyDate', 'xmp:CreateDate',
    'dc:creator', 'dc:rights', 'dc:description', 'dc:title', 'photoshop:City',
    'photoshop:State', 'photoshop:Country', 'Iptc4xmpCore:Location', 'Iptc4xmpCore:CreatorContactInfo'
  ];

  static isJpeg(bytes: Uint8Array): boolean {
    return bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF;
  }

  static inspect(bytes: Uint8Array): JpegMetadataSummary {
    const summary: JpegMetadataSummary = new JpegMetadataSummary();
    JpegMetadata.rewrite(bytes, summary, false);
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    const summary: JpegMetadataSummary = new JpegMetadataSummary();
    const output: Uint8Array = JpegMetadata.rewrite(bytes, summary, true);
    const verified: JpegMetadataSummary = JpegMetadata.inspect(output);
    if (verified.commentCount !== 0 || verified.iptcCount !== 0 || verified.privateXmpCount !== 0 ||
      verified.exifCount !== 0) {
      throw new Error('JPEG container metadata remained after rewriting.');
    }
    return output;
  }

  /** Bytes that an EXIF-only API is never allowed to change. */
  static protectedMediaBytes(bytes: Uint8Array): Uint8Array {
    if (!JpegMetadata.isJpeg(bytes)) throw new Error('Invalid JPEG signature.');
    const parts: Uint8Array[] = [bytes.subarray(0, 2)];
    let length: number = 2;
    let cursor: number = 2;
    while (cursor < bytes.length) {
      const start: number = cursor;
      if (bytes[cursor++] !== 0xFF) throw new Error('Invalid JPEG marker stream.');
      while (cursor < bytes.length && bytes[cursor] === 0xFF) cursor++;
      if (cursor >= bytes.length) throw new Error('Truncated JPEG marker.');
      const marker: number = bytes[cursor++];
      if (marker === 0xDA) {
        const tail: Uint8Array = bytes.subarray(start);
        parts.push(tail); length += tail.length;
        return JpegMetadata.join(parts, length);
      }
      if (marker === 0xD9 || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        const standalone: Uint8Array = bytes.subarray(start, cursor);
        parts.push(standalone); length += standalone.length;
        if (marker === 0xD9) return JpegMetadata.join(parts, length);
        continue;
      }
      if (cursor + 2 > bytes.length) throw new Error('Truncated JPEG segment.');
      const segmentLength: number = JpegMetadata.uint16Be(bytes, cursor);
      const end: number = cursor + segmentLength;
      if (segmentLength < 2 || end > bytes.length) throw new Error('Invalid JPEG segment length.');
      const payloadStart: number = cursor + 2;
      const exif: boolean = marker === 0xE1 && JpegMetadata.startsWithAscii(bytes, payloadStart, 'Exif\u0000\u0000');
      const mutableMetadata: boolean = marker === 0xE0 || marker === 0xFE || marker === 0xED || exif;
      if (!mutableMetadata) {
        const part: Uint8Array = bytes.subarray(start, end);
        parts.push(part); length += part.length;
      }
      cursor = end;
    }
    throw new Error('JPEG end marker is missing.');
  }

  private static rewrite(bytes: Uint8Array, summary: JpegMetadataSummary, sanitize: boolean): Uint8Array {
    if (!JpegMetadata.isJpeg(bytes)) throw new Error('Invalid JPEG signature.');
    const parts: Uint8Array[] = [bytes.subarray(0, 2)];
    let outputLength: number = 2;
    let cursor: number = 2;
    while (cursor < bytes.length) {
      if (bytes[cursor] !== 0xFF) throw new Error('Invalid JPEG marker stream.');
      const start: number = cursor;
      while (cursor < bytes.length && bytes[cursor] === 0xFF) cursor++;
      if (cursor >= bytes.length) throw new Error('Truncated JPEG marker.');
      const marker: number = bytes[cursor++];
      if (marker === 0xDA) {
        if (cursor + 2 > bytes.length) throw new Error('Truncated JPEG scan header.');
        const length: number = JpegMetadata.uint16Be(bytes, cursor);
        if (length < 2 || cursor + length > bytes.length) throw new Error('Invalid JPEG scan header.');
        const tail: Uint8Array = bytes.subarray(start);
        parts.push(tail);
        outputLength += tail.length;
        return JpegMetadata.join(parts, outputLength);
      }
      if (marker === 0xD9) {
        const endPart: Uint8Array = bytes.subarray(start, cursor);
        parts.push(endPart);
        outputLength += endPart.length;
        if (cursor !== bytes.length) throw new Error('Unexpected data after JPEG EOI.');
        return JpegMetadata.join(parts, outputLength);
      }
      if (marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        const standalone: Uint8Array = bytes.subarray(start, cursor);
        parts.push(standalone);
        outputLength += standalone.length;
        continue;
      }
      if (cursor + 2 > bytes.length) throw new Error('Truncated JPEG segment length.');
      const segmentLength: number = JpegMetadata.uint16Be(bytes, cursor);
      const end: number = cursor + segmentLength;
      if (segmentLength < 2 || end > bytes.length) throw new Error('Invalid JPEG segment length.');
      const payloadStart: number = cursor + 2;
      const comment: boolean = marker === 0xFE;
      const iptc: boolean = marker === 0xED;
      const xmp: boolean = marker === 0xE1 &&
        JpegMetadata.startsWithAscii(bytes, payloadStart, 'http://ns.adobe.com/xap/1.0/\u0000');
      const exif: boolean = marker === 0xE1 && JpegMetadata.startsWithAscii(bytes, payloadStart, 'Exif\u0000\u0000');
      if (comment) summary.commentCount++;
      if (iptc) summary.iptcCount++;
      if (exif) summary.exifCount++;
      let part: Uint8Array = bytes.subarray(start, end);
      if (xmp) {
        const copy: Uint8Array = new Uint8Array(part);
        summary.privateXmpCount += JpegMetadata.scrubPrivateXmp(copy);
        if (sanitize) part = copy;
      }
      if (!sanitize || (!comment && !iptc && !exif)) {
        parts.push(part);
        outputLength += part.length;
      }
      cursor = end;
    }
    throw new Error('JPEG end marker is missing.');
  }

  /** Replaces only values, never namespaces or HDR/gain-map properties. */
  private static scrubPrivateXmp(segment: Uint8Array): number {
    let count: number = 0;
    for (let keyIndex: number = 0; keyIndex < JpegMetadata.PRIVATE_XMP_KEYS.length; keyIndex++) {
      const key: string = JpegMetadata.PRIVATE_XMP_KEYS[keyIndex];
      let cursor: number = 0;
      while (cursor < segment.length) {
        const keyStart: number = JpegMetadata.indexOfAscii(segment, key, cursor);
        if (keyStart < 0) break;
        const afterKey: number = keyStart + key.length;
        let valueStart: number = afterKey;
        while (valueStart < segment.length && (segment[valueStart] === 0x20 || segment[valueStart] === 0x09)) {
          valueStart++;
        }
        if (valueStart < segment.length && segment[valueStart] === 0x3D) {
          valueStart++;
          while (valueStart < segment.length && (segment[valueStart] === 0x20 || segment[valueStart] === 0x09)) {
            valueStart++;
          }
          if (valueStart < segment.length && (segment[valueStart] === 0x22 || segment[valueStart] === 0x27)) {
            const quote: number = segment[valueStart++];
            const valueEnd: number = JpegMetadata.indexOfByte(segment, quote, valueStart);
            if (valueEnd >= 0) {
              const containedValue: boolean = JpegMetadata.hasNonBlank(segment, valueStart, valueEnd);
              JpegMetadata.blank(segment, valueStart, valueEnd);
              if (containedValue) count++;
              cursor = valueEnd + 1;
              continue;
            }
          }
        }
        const openEnd: number = JpegMetadata.indexOfByte(segment, 0x3E, afterKey);
        if (openEnd >= 0) {
          const close: string = `</${key}>`;
          const closeStart: number = JpegMetadata.indexOfAscii(segment, close, openEnd + 1);
          if (closeStart >= 0) {
            const containedValue: boolean = JpegMetadata.hasNonBlank(segment, openEnd + 1, closeStart);
            JpegMetadata.blank(segment, openEnd + 1, closeStart);
            if (containedValue) count++;
            cursor = closeStart + close.length;
            continue;
          }
        }
        cursor = afterKey;
      }
    }
    return count;
  }

  private static blank(bytes: Uint8Array, start: number, end: number): void {
    for (let index: number = start; index < end; index++) bytes[index] = 0x20;
  }

  private static hasNonBlank(bytes: Uint8Array, start: number, end: number): boolean {
    for (let index: number = start; index < end; index++) {
      if (bytes[index] !== 0x00 && bytes[index] !== 0x09 && bytes[index] !== 0x0A &&
        bytes[index] !== 0x0D && bytes[index] !== 0x20) return true;
    }
    return false;
  }

  private static indexOfAscii(bytes: Uint8Array, value: string, start: number): number {
    for (let offset: number = start; offset + value.length <= bytes.length; offset++) {
      if (JpegMetadata.startsWithAscii(bytes, offset, value)) return offset;
    }
    return -1;
  }

  private static indexOfByte(bytes: Uint8Array, value: number, start: number): number {
    for (let offset: number = start; offset < bytes.length; offset++) if (bytes[offset] === value) return offset;
    return -1;
  }

  private static startsWithAscii(bytes: Uint8Array, start: number, value: string): boolean {
    if (start + value.length > bytes.length) return false;
    for (let index: number = 0; index < value.length; index++) {
      if (bytes[start + index] !== value.charCodeAt(index)) return false;
    }
    return true;
  }

  private static uint16Be(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  private static join(parts: Uint8Array[], length: number): Uint8Array {
    const output: Uint8Array = new Uint8Array(length);
    let cursor: number = 0;
    for (let index: number = 0; index < parts.length; index++) {
      output.set(parts[index], cursor);
      cursor += parts[index].length;
    }
    return output;
  }
}
