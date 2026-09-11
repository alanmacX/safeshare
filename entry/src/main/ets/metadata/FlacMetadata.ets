export class FlacMetadataSummary {
  vorbisCommentCount: number = 0;
  pictureCount: number = 0;
  applicationCount: number = 0;
}

/**
 * Lossless FLAC metadata-block stripper.
 * Keeps STREAMINFO (required). Drops VORBIS_COMMENT, PICTURE and APPLICATION.
 * Audio frames after the last metadata block are copied byte-for-byte.
 */
export class FlacMetadata {
  static isFlac(bytes: Uint8Array): boolean {
    return bytes.length >= 4 &&
      bytes[0] === 0x66 && bytes[1] === 0x4C && bytes[2] === 0x61 && bytes[3] === 0x43;
  }

  static inspect(bytes: Uint8Array): FlacMetadataSummary {
    const summary: FlacMetadataSummary = new FlacMetadataSummary();
    FlacMetadata.walk(bytes, summary, false);
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    if (!FlacMetadata.isFlac(bytes)) throw new Error('Invalid FLAC signature.');
    const parts: Uint8Array[] = [bytes.subarray(0, 4)];
    let length: number = 4;
    let cursor: number = 4;
    let last: boolean = false;
    while (cursor + 4 <= bytes.length && !last) {
      const flags: number = bytes[cursor];
      last = (flags & 0x80) !== 0;
      const type: number = flags & 0x7F;
      const blockLength: number = (bytes[cursor + 1] << 16) | (bytes[cursor + 2] << 8) | bytes[cursor + 3];
      const end: number = cursor + 4 + blockLength;
      if (end > bytes.length) throw new Error('FLAC metadata block truncated.');
      // STREAMINFO (0) and PADDING (1) are kept; drop comment/picture/app.
      const drop: boolean = type === 4 || type === 6 || type === 2;
      if (!drop) {
        const part: Uint8Array = bytes.subarray(cursor, end);
        parts.push(part);
        length += part.length;
      }
      cursor = end;
    }
    if (cursor >= bytes.length) throw new Error('FLAC audio frames missing.');
    const frames: Uint8Array = bytes.subarray(cursor);
    parts.push(frames);
    length += frames.length;
    const output: Uint8Array = new Uint8Array(length);
    let offset: number = 0;
    for (let index: number = 0; index < parts.length; index++) {
      output.set(parts[index], offset);
      offset += parts[index].length;
    }
    const verified: FlacMetadataSummary = FlacMetadata.inspect(output);
    if (verified.vorbisCommentCount !== 0 || verified.pictureCount !== 0) {
      throw new Error('FLAC metadata remained after stripping.');
    }
    return output;
  }

  private static walk(bytes: Uint8Array, summary: FlacMetadataSummary, _sanitize: boolean): void {
    if (!FlacMetadata.isHeifLike(bytes)) return;
    let cursor: number = 4;
    let last: boolean = false;
    while (cursor + 4 <= bytes.length && !last) {
      const flags: number = bytes[cursor];
      last = (flags & 0x80) !== 0;
      const type: number = flags & 0x7F;
      const blockLength: number = (bytes[cursor + 1] << 16) | (bytes[cursor + 2] << 8) | bytes[cursor + 3];
      if (type === 4) summary.vorbisCommentCount++;
      if (type === 6) summary.pictureCount++;
      if (type === 2) summary.applicationCount++;
      cursor += 4 + blockLength;
    }
  }

  private static isHeifLike(bytes: Uint8Array): boolean {
    return FlacMetadata.isFlac(bytes);
  }
}
