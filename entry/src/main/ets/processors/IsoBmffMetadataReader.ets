import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

class IsoBox {
  type: string = '';
  start: number = 0;
  size: number = 0;
  headerSize: number = 8;

  constructor(type: string, start: number, size: number, headerSize: number) {
    this.type = type;
    this.start = start;
    this.size = size;
    this.headerSize = headerSize;
  }
}

export class IsoMetadataItem {
  key: string = '';
  value: string = '';

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/**
 * Small, bounded ISO-BMFF reader used only as a fallback when the platform
 * extractor does not expose metadata stored in MP4/MOV moov boxes. It never
 * writes to the source and never reads mdat payloads.
 */
export class IsoBmffMetadataReader {
  private static readonly MAX_MOOV_BYTES: number = 32 * 1024 * 1024;
  private static readonly MAC_EPOCH_OFFSET_SECONDS: number = 2082844800;

  static read(fd: number, fileSize: number): IsoMetadataItem[] {
    const items: IsoMetadataItem[] = [];
    const moov: IsoBox | undefined = IsoBmffMetadataReader.findTopLevelMoov(fd, fileSize);
    if (moov === undefined || moov.size <= moov.headerSize ||
      moov.size > IsoBmffMetadataReader.MAX_MOOV_BYTES) {
      return items;
    }
    const payloadSize: number = moov.size - moov.headerSize;
    const bytes: Uint8Array = IsoBmffMetadataReader.readAt(fd, moov.start + moov.headerSize, payloadSize);
    if (bytes.length !== payloadSize) return items;
    IsoBmffMetadataReader.parseChildren(bytes, 0, bytes.length, items, []);
    return items;
  }

  /**
   * Clears privacy-bearing values inside moov without changing a box size,
   * track, sample, codec payload or MovingPhoto anchor. The caller must pass
   * a sandbox copy opened read/write; the selected source is never modified.
   */
  static sanitizePrivacyMetadata(fd: number, fileSize: number): boolean {
    const moov: IsoBox | undefined = IsoBmffMetadataReader.findTopLevelMoov(fd, fileSize);
    if (moov === undefined || moov.size <= moov.headerSize ||
      moov.size > IsoBmffMetadataReader.MAX_MOOV_BYTES) return false;
    const payloadSize: number = moov.size - moov.headerSize;
    const bytes: Uint8Array = IsoBmffMetadataReader.readAt(fd, moov.start + moov.headerSize, payloadSize);
    if (bytes.length !== payloadSize) return false;
    IsoBmffMetadataReader.scrubChildren(bytes, 0, bytes.length);
    try {
      fileIo.lseek(fd, moov.start + moov.headerSize, fileIo.WhenceType.SEEK_SET);
      return fileIo.writeSync(fd, bytes.buffer, { length: bytes.byteLength }) === bytes.byteLength;
    } catch (_) {
      return false;
    }
  }

  /** True when the ISO-BMFF top-level structure contains a bounded moov. */
  static isReadableContainer(fd: number, fileSize: number): boolean {
    const moov: IsoBox | undefined = IsoBmffMetadataReader.findTopLevelMoov(fd, fileSize);
    return moov !== undefined && moov.size > moov.headerSize &&
      moov.size <= IsoBmffMetadataReader.MAX_MOOV_BYTES;
  }

  /** Resolves the actual container MIME from ftyp, independent of filename. */
  static containerMimeType(fd: number, fileSize: number): string {
    if (fileSize < 12) return '';
    const header: Uint8Array = IsoBmffMetadataReader.readAt(fd, 0, 12);
    if (header.length < 12 || IsoBmffMetadataReader.fourCc(header, 4) !== 'ftyp') return '';
    const brand: string = IsoBmffMetadataReader.fourCc(header, 8).toLowerCase();
    if (brand === 'qt  ') return 'video/quicktime';
    if (brand === 'm4a ' || brand === 'm4b ' || brand === 'm4p ') return 'audio/mp4';
    if (['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1', 'avif', 'avis']
      .indexOf(brand) >= 0) return 'image/heif';
    return 'video/mp4';
  }

  private static findTopLevelMoov(fd: number, fileSize: number): IsoBox | undefined {
    let cursor: number = 0;
    while (cursor + 8 <= fileSize) {
      const header: Uint8Array = IsoBmffMetadataReader.readAt(fd, cursor, 16);
      if (header.length < 8) return undefined;
      let size: number = IsoBmffMetadataReader.uint32(header, 0);
      let headerSize: number = 8;
      if (size === 1) {
        if (header.length < 16) return undefined;
        size = IsoBmffMetadataReader.uint32(header, 8) * 4294967296 +
          IsoBmffMetadataReader.uint32(header, 12);
        headerSize = 16;
      } else if (size === 0) {
        size = fileSize - cursor;
      }
      if (size < headerSize || cursor + size > fileSize) return undefined;
      const box: IsoBox = new IsoBox(IsoBmffMetadataReader.fourCc(header, 4), cursor, size, headerSize);
      if (box.type === 'moov') return box;
      cursor += box.size;
    }
    return undefined;
  }

  private static readAt(fd: number, position: number, length: number): Uint8Array {
    if (length <= 0) return new Uint8Array(0);
    try {
      fileIo.lseek(fd, position, fileIo.WhenceType.SEEK_SET);
      const buffer: ArrayBuffer = new ArrayBuffer(length);
      const readLength: number = fileIo.readSync(fd, buffer, { length: length });
      return new Uint8Array(buffer, 0, Math.max(0, readLength));
    } catch (_) {
      return new Uint8Array(0);
    }
  }

  private static parseChildren(bytes: Uint8Array, start: number, end: number,
    items: IsoMetadataItem[], keys: string[]): void {
    let cursor: number = start;
    while (cursor + 8 <= end) {
      const box: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, cursor, end, 0, end);
      if (box === undefined) return;
      const payloadStart: number = cursor + box.headerSize;
      const payloadEnd: number = cursor + box.size;
      if (box.type === 'mvhd') {
        IsoBmffMetadataReader.readCreationTime(bytes, payloadStart, payloadEnd, items);
      } else if (box.type === 'meta') {
        IsoBmffMetadataReader.parseMeta(bytes, payloadStart, payloadEnd, items);
      } else if (box.type === 'udta' || box.type === 'moov' || box.type === 'trak') {
        IsoBmffMetadataReader.parseChildren(bytes, payloadStart, payloadEnd, items, keys);
      } else if (box.type === '\u00a9xyz' || box.type === '\u00a9day' || box.type === '\u00a9mak' ||
        box.type === '\u00a9mod' || box.type === '\u00a9swr' || box.type === '\u00a9ART' ||
        box.type === '\u00a9nam' || box.type === '\u00a9cmt') {
        const value: string = IsoBmffMetadataReader.cleanText(bytes, payloadStart, payloadEnd);
        IsoBmffMetadataReader.addUnique(items, box.type, value);
      }
      cursor += box.size;
    }
  }

  private static parseMeta(bytes: Uint8Array, start: number, end: number,
    items: IsoMetadataItem[]): void {
    // Apple QuickTime writes `hdlr` immediately after the meta header, while
    // ISO/MP4 FullBox meta inserts four version/flag bytes first. Assuming the
    // latter unconditionally shifts every child by four bytes and makes all
    // iPhone/Huawei-compatible QuickTime keys invisible.
    const childStart: number = IsoBmffMetadataReader.hasValidBoxAt(bytes, start, end) ? start : start + 4;
    const keys: string[] = [];
    let cursor: number = childStart;
    while (cursor + 8 <= end) {
      const box: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, cursor, end, 0, end);
      if (box === undefined) return;
      const payloadStart: number = cursor + box.headerSize;
      const payloadEnd: number = cursor + box.size;
      if (box.type === 'keys') {
        IsoBmffMetadataReader.readKeys(bytes, payloadStart, payloadEnd, keys);
      } else if (box.type === 'ilst') {
        IsoBmffMetadataReader.readItemList(bytes, payloadStart, payloadEnd, keys, items);
      }
      cursor += box.size;
    }
  }

  private static scrubChildren(bytes: Uint8Array, start: number, end: number): void {
    let cursor: number = start;
    while (cursor + 8 <= end) {
      const box: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, cursor, end, 0, end);
      if (box === undefined) return;
      const payloadStart: number = cursor + box.headerSize;
      const payloadEnd: number = cursor + box.size;
      if (box.type === 'mvhd' || box.type === 'tkhd' || box.type === 'mdhd') {
        IsoBmffMetadataReader.zeroCreationAndModification(bytes, payloadStart, payloadEnd);
      } else if (box.type === 'meta') {
        IsoBmffMetadataReader.scrubMeta(bytes, payloadStart, payloadEnd);
      } else if (box.type === 'udta' || box.type === 'moov' || box.type === 'trak' ||
        box.type === 'mdia') {
        IsoBmffMetadataReader.scrubChildren(bytes, payloadStart, payloadEnd);
      } else if (IsoBmffMetadataReader.isPrivateDirectAtom(box.type)) {
        IsoBmffMetadataReader.zeroRange(bytes, payloadStart, payloadEnd);
      }
      cursor += box.size;
    }
  }

  private static scrubMeta(bytes: Uint8Array, start: number, end: number): void {
    const childStart: number = IsoBmffMetadataReader.hasValidBoxAt(bytes, start, end) ? start : start + 4;
    const keys: string[] = [];
    let ilstStart: number = -1;
    let ilstEnd: number = -1;
    let cursor: number = childStart;
    while (cursor + 8 <= end) {
      const box: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, cursor, end, 0, end);
      if (box === undefined) return;
      const payloadStart: number = cursor + box.headerSize;
      const payloadEnd: number = cursor + box.size;
      if (box.type === 'keys') IsoBmffMetadataReader.readKeys(bytes, payloadStart, payloadEnd, keys);
      if (box.type === 'ilst') {
        ilstStart = payloadStart;
        ilstEnd = payloadEnd;
      }
      cursor += box.size;
    }
    if (ilstStart >= 0) IsoBmffMetadataReader.scrubItemList(bytes, ilstStart, ilstEnd, keys);
  }

  private static scrubItemList(bytes: Uint8Array, start: number, end: number, keys: string[]): void {
    let cursor: number = start;
    while (cursor + 8 <= end) {
      const item: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, cursor, end, 0, end);
      if (item === undefined) return;
      const keyIndex: number = IsoBmffMetadataReader.uint32(bytes, cursor + 4);
      let key: string = keyIndex > 0 && keyIndex <= keys.length ? keys[keyIndex - 1] : item.type;
      let childCursor: number = cursor + item.headerSize;
      const itemEnd: number = cursor + item.size;
      while (childCursor + 8 <= itemEnd) {
        const child: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, childCursor, itemEnd, 0, itemEnd);
        if (child === undefined) break;
        const childStart: number = childCursor + child.headerSize;
        const childEnd: number = childCursor + child.size;
        if (child.type === 'name') {
          key = IsoBmffMetadataReader.cleanText(bytes, Math.min(childStart + 4, childEnd), childEnd);
        } else if (child.type === 'data' && IsoBmffMetadataReader.isPrivacyKey(key)) {
          // Keep the data type/locale prefix and box geometry intact.
          IsoBmffMetadataReader.zeroRange(bytes, Math.min(childStart + 8, childEnd), childEnd);
        }
        childCursor += child.size;
      }
      cursor += item.size;
    }
  }

  private static zeroCreationAndModification(bytes: Uint8Array, start: number, end: number): void {
    if (start + 12 > end) return;
    const fieldBytes: number = bytes[start] === 1 ? 8 : 4;
    IsoBmffMetadataReader.zeroRange(bytes, start + 4, Math.min(start + 4 + fieldBytes * 2, end));
  }

  private static isPrivateDirectAtom(type: string): boolean {
    return ['\u00a9xyz', '\u00a9day', '\u00a9mak', '\u00a9mod', '\u00a9swr', '\u00a9ART',
      '\u00a9nam', '\u00a9cmt'].indexOf(type) >= 0;
  }

  private static isPrivacyKey(key: string): boolean {
    const normalized: string = key.toLowerCase();
    const needles: string[] = ['location', 'latitude', 'longitude', 'gps', 'iso6709', 'creation',
      'created', 'datetime', 'date', 'author', 'artist', 'owner', 'copyright', 'manufacturer',
      'make', 'model', 'device', 'vendor', 'comment', 'description', 'title', 'software',
      'encoder', 'encoding_tool', '\u00a9xyz', '\u00a9day', '\u00a9mak', '\u00a9mod', '\u00a9swr',
      '\u00a9art', '\u00a9nam', '\u00a9cmt'];
    for (let index: number = 0; index < needles.length; index++) {
      if (normalized.indexOf(needles[index]) >= 0) return true;
    }
    return false;
  }

  private static zeroRange(bytes: Uint8Array, start: number, end: number): void {
    for (let index: number = Math.max(0, start); index < Math.min(end, bytes.length); index++) bytes[index] = 0;
  }

  private static hasValidBoxAt(bytes: Uint8Array, start: number, end: number): boolean {
    // FullBox version/flags commonly begin with 0. boxAt() deliberately treats
    // a zero box size as "extends to end", so using it alone would mistake
    // those flags for a valid child box. Require an actual child size here.
    if (start + 8 > end) return false;
    const declaredSize: number = IsoBmffMetadataReader.uint32(bytes, start);
    if (declaredSize === 1) {
      if (start + 16 > end) return false;
      const extendedSize: number = IsoBmffMetadataReader.uint32(bytes, start + 8) * 4294967296 +
        IsoBmffMetadataReader.uint32(bytes, start + 12);
      return extendedSize >= 16 && start + extendedSize <= end;
    }
    return declaredSize >= 8 && start + declaredSize <= end;
  }

  private static readKeys(bytes: Uint8Array, start: number, end: number, keys: string[]): void {
    if (start + 8 > end) return;
    const view: DataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const count: number = view.getUint32(start + 4, false);
    let cursor: number = start + 8;
    for (let index: number = 0; index < count && cursor + 8 <= end; index++) {
      const size: number = view.getUint32(cursor, false);
      if (size < 8 || cursor + size > end) return;
      keys.push(IsoBmffMetadataReader.cleanText(bytes, cursor + 8, cursor + size));
      cursor += size;
    }
  }

  private static readItemList(bytes: Uint8Array, start: number, end: number,
    keys: string[], items: IsoMetadataItem[]): void {
    let cursor: number = start;
    while (cursor + 8 <= end) {
      const item: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, cursor, end, 0, end);
      if (item === undefined) return;
      const keyIndex: number = IsoBmffMetadataReader.uint32(bytes, cursor + 4);
      let key: string = keyIndex > 0 && keyIndex <= keys.length ? keys[keyIndex - 1] : item.type;
      let value: string = '';
      let childCursor: number = cursor + item.headerSize;
      const itemEnd: number = cursor + item.size;
      while (childCursor + 8 <= itemEnd) {
        const child: IsoBox | undefined = IsoBmffMetadataReader.boxAt(bytes, childCursor, itemEnd, 0, itemEnd);
        if (child === undefined) break;
        const childStart: number = childCursor + child.headerSize;
        const childEnd: number = childCursor + child.size;
        if (child.type === 'data') {
          value = IsoBmffMetadataReader.cleanText(bytes, Math.min(childStart + 8, childEnd), childEnd);
        } else if (child.type === 'name') {
          key = IsoBmffMetadataReader.cleanText(bytes, Math.min(childStart + 4, childEnd), childEnd);
        }
        childCursor += child.size;
      }
      IsoBmffMetadataReader.addUnique(items, key, value);
      cursor += item.size;
    }
  }

  private static readCreationTime(bytes: Uint8Array, start: number, end: number,
    items: IsoMetadataItem[]): void {
    if (start + 8 > end) return;
    const version: number = bytes[start];
    let seconds: number = 0;
    if (version === 1 && start + 12 <= end) {
      const high: number = IsoBmffMetadataReader.uint32(bytes, start + 4);
      const low: number = IsoBmffMetadataReader.uint32(bytes, start + 8);
      seconds = high * 4294967296 + low;
    } else {
      seconds = IsoBmffMetadataReader.uint32(bytes, start + 4);
    }
    const unixSeconds: number = seconds - IsoBmffMetadataReader.MAC_EPOCH_OFFSET_SECONDS;
    if (unixSeconds <= 0 || unixSeconds > 4102444800) return;
    const value: string = new Date(unixSeconds * 1000).toISOString();
    IsoBmffMetadataReader.addUnique(items, 'container.creationTime', value);
  }

  private static boxAt(bytes: Uint8Array, cursor: number, end: number,
    absoluteBase: number, absoluteEnd: number): IsoBox | undefined {
    if (cursor + 8 > end) return undefined;
    let size: number = IsoBmffMetadataReader.uint32(bytes, cursor);
    const type: string = IsoBmffMetadataReader.fourCc(bytes, cursor + 4);
    let headerSize: number = 8;
    if (size === 1) {
      if (cursor + 16 > end) return undefined;
      size = IsoBmffMetadataReader.uint32(bytes, cursor + 8) * 4294967296 +
        IsoBmffMetadataReader.uint32(bytes, cursor + 12);
      headerSize = 16;
    } else if (size === 0) {
      size = absoluteEnd - (absoluteBase + cursor);
    }
    if (size < headerSize || absoluteBase + cursor + size > absoluteEnd || cursor + size > end) {
      return undefined;
    }
    return new IsoBox(type, absoluteBase + cursor, size, headerSize);
  }

  private static uint32(bytes: Uint8Array, offset: number): number {
    if (offset + 4 > bytes.length) return 0;
    return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(offset, false);
  }

  private static fourCc(bytes: Uint8Array, offset: number): string {
    if (offset + 4 > bytes.length) return '';
    return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
  }

  private static cleanText(bytes: Uint8Array, start: number, end: number): string {
    if (start >= end || start < 0 || end > bytes.length) return '';
    let value: string = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true })
      .decodeToString(bytes.subarray(start, end));
    value = value.replace(/\uFFFD/g, '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim();
    return value.length > 200 ? value.slice(0, 200) : value;
  }

  private static addUnique(items: IsoMetadataItem[], key: string, value: string): void {
    if (key.length === 0 || value.length === 0) return;
    for (let index: number = 0; index < items.length; index++) {
      if (items[index].key === key || items[index].value === value) return;
    }
    items.push(new IsoMetadataItem(key, value));
  }
}
