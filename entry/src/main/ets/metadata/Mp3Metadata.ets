export class Mp3MetadataSummary {
  id3v2Count: number = 0;
  id3v1Count: number = 0;
  apeCount: number = 0;
}

/**
 * Lossless MP3 tag stripper.
 *
 * HarmonyOS has no public write-back API for MP3 tags. Privacy data is in
 * ID3v2 (start), ID3v1 (last 128 bytes) and optional APEv2 (before ID3v1).
 * This copies only the MPEG audio frame payload.
 */
export class Mp3Metadata {
  static isMp3(bytes: Uint8Array): boolean {
    if (bytes.length < 4) return false;
    if (bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) return true;
    return Mp3Metadata.findFrameSync(bytes, 0, Math.min(bytes.length, 8192)) >= 0;
  }

  static inspect(bytes: Uint8Array): Mp3MetadataSummary {
    const summary: Mp3MetadataSummary = new Mp3MetadataSummary();
    const head: number = Mp3Metadata.id3v2Size(bytes);
    if (head > 0) summary.id3v2Count = 1;
    const tail: TailTags = Mp3Metadata.tailTagSize(bytes);
    if (tail.id3v1) summary.id3v1Count = 1;
    if (tail.ape) summary.apeCount = 1;
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    const head: number = Mp3Metadata.id3v2Size(bytes);
    const tail: TailTags = Mp3Metadata.tailTagSize(bytes);
    let start: number = head;
    let end: number = bytes.length - tail.total;
    if (end < start) {
      start = 0;
      end = bytes.length;
    }
    // Keep only bytes that look like MPEG audio; if the first frame sync is
    // late (padding junk), still emit the interior slice — never the tags.
    const output: Uint8Array = bytes.slice(start, end);
    if (output.length < 4) throw new Error('MP3_AUDIO_PAYLOAD_EMPTY');
    const verified: Mp3MetadataSummary = Mp3Metadata.inspect(output);
    if (verified.id3v2Count !== 0 || verified.id3v1Count !== 0 || verified.apeCount !== 0) {
      throw new Error('MP3 metadata remained after stripping.');
    }
    return output;
  }

  /** Size of a leading ID3v2 tag including header; 0 when absent. */
  static id3v2Size(bytes: Uint8Array): number {
    if (bytes.length < 10) return 0;
    if (bytes[0] !== 0x49 || bytes[1] !== 0x44 || bytes[2] !== 0x33) return 0;
    const flags: number = bytes[5];
    let size: number = ((bytes[6] & 0x7F) << 21) | ((bytes[7] & 0x7F) << 14) |
      ((bytes[8] & 0x7F) << 7) | (bytes[9] & 0x7F);
    size += 10;
    if ((flags & 0x10) !== 0) size += 10; // footer
    return size <= bytes.length ? size : 0;
  }

  /** Combined trailing ID3v1 + APEv2 size. */
  static tailTagSize(bytes: Uint8Array): TailTags {
    const result: TailTags = new TailTags();
    if (bytes.length >= 128 &&
      bytes[bytes.length - 128] === 0x54 && bytes[bytes.length - 127] === 0x41 &&
      bytes[bytes.length - 126] === 0x47) {
      result.id3v1 = true;
      result.total += 128;
    }
    // APEv2 footer: 'APETAGEX' at (length - total - 32) roughly. Search a
    // small window before ID3v1 / EOF.
    const searchEnd: number = bytes.length - result.total;
    const window: number = Math.min(searchEnd, 8192);
    for (let index: number = searchEnd - 32; index >= searchEnd - window && index >= 0; index--) {
      if (bytes[index] === 0x41 && bytes[index + 1] === 0x50 && bytes[index + 2] === 0x45 &&
        bytes[index + 3] === 0x54 && bytes[index + 4] === 0x41 && bytes[index + 5] === 0x47 &&
        bytes[index + 6] === 0x45 && bytes[index + 7] === 0x58) {
        const size: number = Mp3Metadata.uint32Le(bytes, index + 12);
        // Footer size field is the tag body size; full tag includes header.
        const tagSize: number = size + 32;
        if (tagSize > 0 && index >= searchEnd - tagSize && tagSize <= searchEnd) {
          result.ape = true;
          result.total = tagSize + (result.id3v1 ? 128 : 0);
          return result;
        }
      }
    }
    return result;
  }

  private static findFrameSync(bytes: Uint8Array, start: number, end: number): number {
    for (let index: number = start; index + 1 < end; index++) {
      if (bytes[index] === 0xFF && (bytes[index + 1] & 0xE0) === 0xE0) return index;
    }
    return -1;
  }

  private static uint32Le(bytes: Uint8Array, offset: number): number {
    if (offset + 4 > bytes.length) return 0;
    return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
  }
}

class TailTags {
  id3v1: boolean = false;
  ape: boolean = false;
  total: number = 0;
}
