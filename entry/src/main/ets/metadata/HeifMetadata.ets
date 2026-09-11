export class HeifMetadataSummary {
  exifItemCount: number = 0;
  xmpItemCount: number = 0;
  scrubbedBytes: number = 0;
}

/**
 * HEIF/HEIC container metadata scrubber.
 *
 * Huawei Gallery stills are typically HEIF. Privacy data lives in HEIF items
 * (`item_type` Exif or mime/XMP), not in a JPEG APP1 segment. This walks
 * meta/iinf/iloc and zeros those item payloads in place so the primary image
 * items (hvc1/grid/iovl) are untouched.
 */
export class HeifMetadata {
  static isHeif(bytes: Uint8Array): boolean {
    if (bytes.length < 12) return false;
    if (String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]) !== 'ftyp') return false;
    const brand: string = String.fromCharCode(bytes[8], bytes[9], bytes[10], bytes[11]).toLowerCase();
    return ['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'].indexOf(brand) >= 0;
  }

  static inspect(bytes: Uint8Array): HeifMetadataSummary {
    const summary: HeifMetadataSummary = new HeifMetadataSummary();
    HeifMetadata.walk(bytes, summary, false);
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    if (!HeifMetadata.isHeif(bytes)) throw new Error('Invalid HEIF signature.');
    const output: Uint8Array = new Uint8Array(bytes);
    HeifMetadata.walk(output, new HeifMetadataSummary(), true);
    if (HeifMetadata.nonEmptyItemCount(output) > 0) {
      throw new Error('HEIF metadata remained after scrubbing.');
    }
    return output;
  }

  private static nonEmptyItemCount(bytes: Uint8Array): number {
    let count: number = 0;
    const targets: HeifItemRange[] = HeifMetadata.locateItems(bytes);
    for (let index: number = 0; index < targets.length; index++) {
      const range: HeifItemRange = targets[index];
      if (range.length <= 0) continue;
      for (let cursor: number = range.offset; cursor < range.offset + range.length && cursor < bytes.length; cursor++) {
        if (bytes[cursor] !== 0) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  private static walk(bytes: Uint8Array, summary: HeifMetadataSummary, sanitize: boolean): HeifMetadataSummary {
    const targets: HeifItemRange[] = HeifMetadata.locateItems(bytes);
    for (let index: number = 0; index < targets.length; index++) {
      const range: HeifItemRange = targets[index];
      if (range.kind === 'exif') summary.exifItemCount++;
      if (range.kind === 'xmp') summary.xmpItemCount++;
      if (!sanitize || range.length <= 0) continue;
      const end: number = Math.min(range.offset + range.length, bytes.length);
      for (let cursor: number = Math.max(0, range.offset); cursor < end; cursor++) {
        if (bytes[cursor] !== 0) {
          bytes[cursor] = 0;
          summary.scrubbedBytes++;
        }
      }
    }
    return summary;
  }

  private static locateItems(bytes: Uint8Array): HeifItemRange[] {
    const ranges: HeifItemRange[] = [];
    const items: Map<number, string> = HeifMetadata.readItemTypes(bytes);
    if (items.size === 0) return ranges;
    const extents: Map<number, HeifItemRange> = HeifMetadata.readIloc(bytes, items);
    items.forEach((kind: string, id: number) => {
      const found: HeifItemRange | undefined = extents.get(id);
      if (found !== undefined) ranges.push(found);
    });
    return ranges;
  }

  private static readItemTypes(bytes: Uint8Array): Map<number, string> {
    const result: Map<number, string> = new Map();
    const meta: BoxRef | undefined = HeifMetadata.findTopLevelMeta(bytes);
    if (meta === undefined) return result;
    const inner: BoxRef | undefined = HeifMetadata.findNested(bytes, meta, 'iinf');
    if (inner === undefined) return result;
    let cursor: number = inner.start + inner.headerSize;
    const end: number = inner.start + inner.size;
    if (cursor + 4 > end) return result;
    const version: number = bytes[cursor];
    let count: number = 0;
    if (version === 0) {
      count = HeifMetadata.uint16(bytes, cursor + 4);
      cursor += 6;
    } else {
      count = HeifMetadata.uint32(bytes, cursor + 4);
      cursor += 8;
    }
    for (let index: number = 0; index < count && cursor + 8 <= end; index++) {
      const box: BoxRef | undefined = HeifMetadata.boxAt(bytes, cursor, end);
      if (box === undefined) break;
      if (HeifMetadata.fourCc(bytes, box.start + 4) === 'infe') {
        const payload: number = box.start + box.headerSize;
        const infeVersion: number = bytes[payload];
        let idOffset: number = payload + 4;
        let idValue: number = 0;
        if (infeVersion === 2) {
          idValue = HeifMetadata.uint32(bytes, idOffset);
          idOffset += 6;
        } else {
          idValue = HeifMetadata.uint16(bytes, idOffset);
          idOffset += 4;
        }
        if (idOffset + 4 <= end) {
          const type: string = HeifMetadata.fourCc(bytes, idOffset);
          if (type === 'Exif' || type === 'mime') {
            result.set(idValue, type === 'Exif' ? 'exif' : 'xmp');
          }
        }
      }
      cursor += box.size;
    }
    return result;
  }

  private static readIloc(bytes: Uint8Array, items: Map<number, string>): Map<number, HeifItemRange> {
    const result: Map<number, HeifItemRange> = new Map();
    const meta: BoxRef | undefined = HeifMetadata.findTopLevelMeta(bytes);
    if (meta === undefined) return result;
    const iloc: BoxRef | undefined = HeifMetadata.findNested(bytes, meta, 'iloc');
    if (iloc === undefined) return result;
    let cursor: number = iloc.start + iloc.headerSize;
    if (cursor + 6 > iloc.start + iloc.size) return result;
    const version: number = bytes[cursor];
    const offsetSize: number = (bytes[cursor + 4] >> 4) & 0x0F;
    const lengthSize: number = bytes[cursor + 4] & 0x0F;
    const baseOffsetSize: number = (bytes[cursor + 5] >> 4) & 0x0F;
    let index: number = cursor + 6;
    if (version === 1 || version === 2) index += 2;
    if (version < 2) {
      const itemCount: number = HeifMetadata.uint16(bytes, index);
      index += 2;
      for (let item: number = 0; item < itemCount && index + 2 <= iloc.start + iloc.size; item++) {
        const id: number = version < 2 ? HeifMetadata.uint16(bytes, index) : HeifMetadata.uint32(bytes, index);
        index += version < 2 ? 2 : 4;
        if (version === 1 || version === 2) index += 2;
        const baseOffset: number = HeifMetadata.readSized(bytes, index, baseOffsetSize);
        index += baseOffsetSize;
        const extentCount: number = HeifMetadata.uint16(bytes, index);
        index += 2;
        for (let extent: number = 0; extent < extentCount; extent++) {
          if (version === 1 || version === 2) index += 4;
          const extentOffset: number = HeifMetadata.readSized(bytes, index, offsetSize);
          index += offsetSize;
          const extentLength: number = HeifMetadata.readSized(bytes, index, lengthSize);
          index += lengthSize;
          if (items.has(id) && extentLength > 0) {
            result.set(id, {
              id: id,
              kind: items.get(id) ?? '',
              offset: baseOffset + extentOffset,
              length: extentLength
            });
          }
        }
      }
    }
    return result;
  }

  private static metaChildStart(bytes: Uint8Array, meta: BoxRef): number {
    // FullBox meta inserts version/flags after the box header.
    return meta.start + meta.headerSize + 4;
  }

  private static findTopLevelMeta(bytes: Uint8Array): BoxRef | undefined {
    let cursor: number = 0;
    const end: number = bytes.length;
    while (cursor + 8 <= end) {
      const box: BoxRef | undefined = HeifMetadata.boxAt(bytes, cursor, end);
      if (box === undefined) return undefined;
      if (HeifMetadata.fourCc(bytes, box.start + 4) === 'meta') return box;
      cursor += box.size;
    }
    return undefined;
  }

  private static findNested(bytes: Uint8Array, parent: BoxRef, type: string): BoxRef | undefined {
    // Only search direct children of meta-like containers.
    let cursor: number = parent.start + parent.headerSize;
    if (HeifMetadata.fourCc(bytes, parent.start + 4) === 'meta') cursor += 4;
    const end: number = parent.start + parent.size;
    while (cursor + 8 <= end) {
      const box: BoxRef | undefined = HeifMetadata.boxAt(bytes, cursor, end);
      if (box === undefined) return undefined;
      if (HeifMetadata.fourCc(bytes, box.start + 4) === type) return box;
      cursor += box.size;
    }
    return undefined;
  }

  private static boxAt(bytes: Uint8Array, cursor: number, end: number): BoxRef | undefined {
    if (cursor + 8 > end) return undefined;
    let size: number = HeifMetadata.uint32(bytes, cursor);
    let headerSize: number = 8;
    if (size === 1) {
      if (cursor + 16 > end) return undefined;
      size = HeifMetadata.uint32(bytes, cursor + 8) * 4294967296 + HeifMetadata.uint32(bytes, cursor + 12);
      headerSize = 16;
    } else if (size === 0) {
      size = end - cursor;
    }
    if (size < headerSize || cursor + size > end) return undefined;
    return { start: cursor, size: size, headerSize: headerSize };
  }

  private static readSized(bytes: Uint8Array, offset: number, size: number): number {
    if (size <= 0) return 0;
    if (size === 1) return bytes[offset];
    if (size === 2) return HeifMetadata.uint16(bytes, offset);
    if (size === 4) return HeifMetadata.uint32(bytes, offset);
    if (size === 8) {
      return HeifMetadata.uint32(bytes, offset) * 4294967296 + HeifMetadata.uint32(bytes, offset + 4);
    }
    return 0;
  }

  private static uint16(bytes: Uint8Array, offset: number): number {
    if (offset + 2 > bytes.length) return 0;
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  private static uint32(bytes: Uint8Array, offset: number): number {
    if (offset + 4 > bytes.length) return 0;
    return ((bytes[offset] << 24) >>> 0) + (bytes[offset + 1] << 16) +
      (bytes[offset + 2] << 8) + bytes[offset + 3];
  }

  private static fourCc(bytes: Uint8Array, offset: number): string {
    if (offset + 4 > bytes.length) return '';
    return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
  }
}

class BoxRef {
  start: number = 0;
  size: number = 0;
  headerSize: number = 8;
}

class HeifItemRange {
  id: number = 0;
  kind: string = '';
  offset: number = 0;
  length: number = 0;
}
