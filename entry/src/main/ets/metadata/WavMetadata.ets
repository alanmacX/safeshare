export class WavMetadataSummary {
  listInfoCount: number = 0;
  bextCount: number = 0;
  ixmlCount: number = 0;
  otherMetaCount: number = 0;
}

/**
 * Lossless WAV RIFF chunk stripper.
 * Keeps RIFF/WAVE header, `fmt ` and `data`. Drops LIST/INFO, bext, iXML and
 * other non-audio metadata chunks. Sample data is copied byte-for-byte.
 */
export class WavMetadata {
  static isWav(bytes: Uint8Array): boolean {
    return bytes.length >= 12 &&
      String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) === 'RIFF' &&
      String.fromCharCode(bytes[8], bytes[9], bytes[10], bytes[11]) === 'WAVE';
  }

  static inspect(bytes: Uint8Array): WavMetadataSummary {
    const summary: WavMetadataSummary = new WavMetadataSummary();
    WavMetadata.walk(bytes, summary);
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    if (!WavMetadata.isWav(bytes)) throw new Error('Invalid WAV signature.');
    const parts: Uint8Array[] = [bytes.subarray(0, 12)];
    let length: number = 12;
    let cursor: number = 12;
    let sawFmt: boolean = false;
    let sawData: boolean = false;
    while (cursor + 8 <= bytes.length) {
      const id: string = String.fromCharCode(bytes[cursor], bytes[cursor + 1],
        bytes[cursor + 2], bytes[cursor + 3]);
      const size: number = WavMetadata.uint32Le(bytes, cursor + 4);
      let end: number = cursor + 8 + size;
      if (size % 2 === 1) end += 1; // word align
      if (end > bytes.length) {
        // Trailing partial chunk: stop rather than fail the whole copy.
        break;
      }
      const keep: boolean = id === 'fmt ' || id === 'data';
      if (id === 'fmt ') sawFmt = true;
      if (id === 'data') sawData = true;
      if (keep) {
        const part: Uint8Array = bytes.subarray(cursor, end);
        parts.push(part);
        length += part.length;
      }
      cursor = end;
    }
    if (!sawFmt || !sawData) throw new Error('WAV fmt/data missing.');
    const output: Uint8Array = new Uint8Array(length);
    // Patch RIFF size = total - 8
    output.set(bytes.subarray(0, 12), 0);
    const riffSize: number = length - 8;
    output[4] = riffSize & 0xFF;
    output[5] = (riffSize >> 8) & 0xFF;
    output[6] = (riffSize >> 16) & 0xFF;
    output[7] = (riffSize >> 24) & 0xFF;
    let offset: number = 12;
    for (let index: number = 1; index < parts.length; index++) {
      output.set(parts[index], offset);
      offset += parts[index].length;
    }
    const verified: WavMetadataSummary = WavMetadata.inspect(output);
    if (verified.listInfoCount !== 0 || verified.bextCount !== 0 || verified.ixmlCount !== 0) {
      throw new Error('WAV metadata remained after stripping.');
    }
    return output;
  }

  private static walk(bytes: Uint8Array, summary: WavMetadataSummary): void {
    let cursor: number = 12;
    while (cursor + 8 <= bytes.length) {
      const id: string = String.fromCharCode(bytes[cursor], bytes[cursor + 1],
        bytes[cursor + 2], bytes[cursor + 3]);
      const size: number = WavMetadata.uint32Le(bytes, cursor + 4);
      let end: number = cursor + 8 + size;
      if (size % 2 === 1) end += 1;
      if (end > bytes.length) break;
      if (id === 'LIST') summary.listInfoCount++;
      if (id === 'bext') summary.bextCount++;
      if (id === 'iXML' || id === 'axml') summary.ixmlCount++;
      if (id !== 'fmt ' && id !== 'data' && id !== 'LIST' && id !== 'bext' &&
        id !== 'iXML' && id !== 'axml' && id !== 'fact') {
        summary.otherMetaCount++;
      }
      cursor = end;
    }
  }

  private static uint32Le(bytes: Uint8Array, offset: number): number {
    if (offset + 4 > bytes.length) return 0;
    return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
  }
}
