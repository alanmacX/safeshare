export class TiffMetadataSummary {
  privacyTagCount: number = 0;
  gpsDirectoryCount: number = 0;
  xmpIptcCount: number = 0;
}

/** Classic TIFF/DNG IFD privacy-tag scrubber; image strips/tiles are untouched. */
export class TiffMetadata {
  private static readonly PRIVACY_TAGS: number[] = [
    0x010E, 0x010F, 0x0110, 0x0131, 0x0132, 0x013B, 0x8298,
    0x9003, 0x9004, 0x9286, 0xA430, 0xA431, 0xA433, 0xA434, 0xA435
  ];
  private static readonly XMP_IPTC_TAGS: number[] = [0x02BC, 0x83BB, 0x8649];

  static isClassicTiff(bytes: Uint8Array): boolean {
    if (bytes.length < 8) return false;
    const little: boolean = bytes[0] === 0x49 && bytes[1] === 0x49;
    const big: boolean = bytes[0] === 0x4D && bytes[1] === 0x4D;
    if (!little && !big) return false;
    return TiffMetadata.u16(bytes, 2, little) === 42;
  }

  static isDng(bytes: Uint8Array): boolean {
    if (!TiffMetadata.isClassicTiff(bytes)) return false;
    const little: boolean = bytes[0] === 0x49;
    const offset: number = TiffMetadata.u32(bytes, 4, little);
    if (offset + 2 > bytes.length) return false;
    const count: number = TiffMetadata.u16(bytes, offset, little);
    if (count > 4096 || offset + 2 + count * 12 + 4 > bytes.length) return false;
    for (let index: number = 0; index < count; index++) {
      if (TiffMetadata.u16(bytes, offset + 2 + index * 12, little) === 0xC612) return true;
    }
    return false;
  }

  static inspect(bytes: Uint8Array): TiffMetadataSummary {
    const summary: TiffMetadataSummary = new TiffMetadataSummary();
    TiffMetadata.process(bytes, undefined, summary);
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    const output: Uint8Array = new Uint8Array(bytes);
    const summary: TiffMetadataSummary = new TiffMetadataSummary();
    TiffMetadata.process(bytes, output, summary);
    const verified: TiffMetadataSummary = TiffMetadata.inspect(output);
    if (verified.privacyTagCount !== 0 || verified.gpsDirectoryCount !== 0 || verified.xmpIptcCount !== 0) {
      throw new Error('TIFF/DNG metadata remained after rewriting.');
    }
    return output;
  }

  private static process(bytes: Uint8Array, output: Uint8Array | undefined,
    summary: TiffMetadataSummary): void {
    if (!TiffMetadata.isClassicTiff(bytes)) throw new Error('Unsupported TIFF/DNG container.');
    const little: boolean = bytes[0] === 0x49;
    const firstIfd: number = TiffMetadata.u32(bytes, 4, little);
    const visited: number[] = [];
    TiffMetadata.walkIfd(bytes, output, firstIfd, little, false, summary, visited, 0);
  }

  private static walkIfd(bytes: Uint8Array, output: Uint8Array | undefined, offset: number,
    little: boolean, gps: boolean, summary: TiffMetadataSummary, visited: number[], depth: number): void {
    if (offset === 0) return;
    if (depth > 16 || visited.indexOf(offset) >= 0 || offset + 2 > bytes.length) {
      throw new Error('Invalid TIFF IFD graph.');
    }
    visited.push(offset);
    const count: number = TiffMetadata.u16(bytes, offset, little);
    if (count > 4096 || offset + 2 + count * 12 + 4 > bytes.length) throw new Error('Invalid TIFF IFD size.');
    for (let index: number = 0; index < count; index++) {
      const entry: number = offset + 2 + index * 12;
      const tag: number = TiffMetadata.u16(bytes, entry, little);
      const type: number = TiffMetadata.u16(bytes, entry + 2, little);
      const itemCount: number = TiffMetadata.u32(bytes, entry + 4, little);
      const valueOffset: number = TiffMetadata.u32(bytes, entry + 8, little);
      if (tag === 0x8769) {
        TiffMetadata.walkIfd(bytes, output, valueOffset, little, false, summary, visited, depth + 1);
      } else if (tag === 0x8825) {
        summary.gpsDirectoryCount++;
        TiffMetadata.walkIfd(bytes, output, valueOffset, little, true, summary, visited, depth + 1);
        if (output !== undefined) TiffMetadata.eraseEntry(bytes, output, entry, type, itemCount, valueOffset);
      }
      const privacy: boolean = gps || TiffMetadata.PRIVACY_TAGS.indexOf(tag) >= 0;
      const xmpIptc: boolean = TiffMetadata.XMP_IPTC_TAGS.indexOf(tag) >= 0;
      if (privacy) summary.privacyTagCount++;
      if (xmpIptc) summary.xmpIptcCount++;
      if (output !== undefined && (privacy || xmpIptc)) {
        TiffMetadata.eraseEntry(bytes, output, entry, type, itemCount, valueOffset);
      }
    }
    if (!gps) {
      const next: number = TiffMetadata.u32(bytes, offset + 2 + count * 12, little);
      TiffMetadata.walkIfd(bytes, output, next, little, false, summary, visited, depth + 1);
    }
  }

  private static eraseEntry(source: Uint8Array, output: Uint8Array, entry: number,
    type: number, count: number, valueOffset: number): void {
    const typeSize: number = TiffMetadata.typeSize(type);
    const byteCount: number = typeSize > 0 && count <= Math.floor(0x7FFFFFFF / typeSize) ? typeSize * count : 0;
    if (byteCount > 4 && valueOffset + byteCount <= source.length) {
      for (let index: number = valueOffset; index < valueOffset + byteCount; index++) output[index] = 0;
    }
    for (let index: number = entry; index < entry + 12; index++) output[index] = 0;
  }

  private static typeSize(type: number): number {
    if (type === 1 || type === 2 || type === 6 || type === 7) return 1;
    if (type === 3 || type === 8) return 2;
    if (type === 4 || type === 9 || type === 11 || type === 13) return 4;
    if (type === 5 || type === 10 || type === 12) return 8;
    return 0;
  }

  private static u16(bytes: Uint8Array, offset: number, little: boolean): number {
    if (offset + 2 > bytes.length) throw new Error('Truncated TIFF value.');
    return little ? bytes[offset] | (bytes[offset + 1] << 8) : (bytes[offset] << 8) | bytes[offset + 1];
  }

  private static u32(bytes: Uint8Array, offset: number, little: boolean): number {
    if (offset + 4 > bytes.length) throw new Error('Truncated TIFF value.');
    if (little) return (bytes[offset] + (bytes[offset + 1] << 8) + (bytes[offset + 2] << 16) +
      bytes[offset + 3] * 0x1000000) >>> 0;
    return (bytes[offset] * 0x1000000 + (bytes[offset + 1] << 16) +
      (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
  }
}
