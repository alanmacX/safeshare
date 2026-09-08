export class ContainerMetadataSummary {
  textCount: number = 0;
  exifCount: number = 0;
  xmpCount: number = 0;
}

/** Lossless metadata stripping for PNG and WebP containers. */
export class ContainerMetadata {
  static isPng(bytes: Uint8Array): boolean {
    const signature: number[] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < signature.length) return false;
    for (let index: number = 0; index < signature.length; index++) {
      if (bytes[index] !== signature[index]) return false;
    }
    return true;
  }

  static isWebp(bytes: Uint8Array): boolean {
    return bytes.length >= 12 && ContainerMetadata.ascii(bytes, 0, 4) === 'RIFF' &&
      ContainerMetadata.ascii(bytes, 8, 4) === 'WEBP';
  }

  static inspectPng(bytes: Uint8Array): ContainerMetadataSummary {
    const summary: ContainerMetadataSummary = new ContainerMetadataSummary();
    ContainerMetadata.parsePng(bytes, summary, false);
    return summary;
  }

  static sanitizePng(bytes: Uint8Array): Uint8Array {
    const summary: ContainerMetadataSummary = new ContainerMetadataSummary();
    const output: Uint8Array = ContainerMetadata.parsePng(bytes, summary, true);
    const verified: ContainerMetadataSummary = ContainerMetadata.inspectPng(output);
    if (verified.textCount !== 0) throw new Error('PNG text metadata remained after rewriting.');
    return output;
  }

  static inspectWebp(bytes: Uint8Array): ContainerMetadataSummary {
    const summary: ContainerMetadataSummary = new ContainerMetadataSummary();
    ContainerMetadata.parseWebp(bytes, summary, false);
    return summary;
  }

  static sanitizeWebp(bytes: Uint8Array): Uint8Array {
    const summary: ContainerMetadataSummary = new ContainerMetadataSummary();
    const output: Uint8Array = ContainerMetadata.parseWebp(bytes, summary, true);
    const verified: ContainerMetadataSummary = ContainerMetadata.inspectWebp(output);
    if (verified.exifCount !== 0 || verified.xmpCount !== 0) {
      throw new Error('WebP metadata remained after rewriting.');
    }
    return output;
  }

  private static parsePng(bytes: Uint8Array, summary: ContainerMetadataSummary,
    sanitize: boolean): Uint8Array {
    if (!ContainerMetadata.isPng(bytes)) throw new Error('Invalid PNG signature.');
    const outputs: Uint8Array[] = [bytes.subarray(0, 8)];
    let outputLength: number = 8;
    let cursor: number = 8;
    let sawHeader: boolean = false;
    let sawEnd: boolean = false;
    while (cursor < bytes.length) {
      if (cursor + 12 > bytes.length) throw new Error('Truncated PNG chunk.');
      const length: number = ContainerMetadata.uint32Be(bytes, cursor);
      const end: number = cursor + 12 + length;
      if (end > bytes.length) throw new Error('Invalid PNG chunk length.');
      const type: string = ContainerMetadata.ascii(bytes, cursor + 4, 4);
      if (!sawHeader && type !== 'IHDR') throw new Error('PNG header chunk is missing.');
      if (type === 'IHDR') sawHeader = true;
      const textual: boolean = type === 'tEXt' || type === 'zTXt' || type === 'iTXt';
      if (textual) summary.textCount++;
      if (type === 'eXIf') summary.exifCount++;
      if (!sanitize || !textual) {
        const part: Uint8Array = bytes.subarray(cursor, end);
        outputs.push(part);
        outputLength += part.length;
      }
      cursor = end;
      if (type === 'IEND') {
        sawEnd = true;
        break;
      }
    }
    if (!sawHeader || !sawEnd || cursor !== bytes.length) throw new Error('Invalid PNG container.');
    return ContainerMetadata.join(outputs, outputLength);
  }

  private static parseWebp(bytes: Uint8Array, summary: ContainerMetadataSummary,
    sanitize: boolean): Uint8Array {
    if (!ContainerMetadata.isWebp(bytes)) throw new Error('Invalid WebP signature.');
    const declaredSize: number = ContainerMetadata.uint32Le(bytes, 4) + 8;
    if (declaredSize !== bytes.length) throw new Error('Invalid WebP RIFF size.');
    const chunks: Uint8Array[] = [];
    let payloadLength: number = 4; // WEBP form type.
    let cursor: number = 12;
    while (cursor < bytes.length) {
      if (cursor + 8 > bytes.length) throw new Error('Truncated WebP chunk.');
      const type: string = ContainerMetadata.ascii(bytes, cursor, 4);
      const length: number = ContainerMetadata.uint32Le(bytes, cursor + 4);
      const paddedLength: number = length + (length & 1);
      const end: number = cursor + 8 + paddedLength;
      if (end > bytes.length) throw new Error('Invalid WebP chunk length.');
      const exif: boolean = type === 'EXIF';
      const xmp: boolean = type === 'XMP ';
      if (exif) summary.exifCount++;
      if (xmp) summary.xmpCount++;
      if (!sanitize || (!exif && !xmp)) {
        const part: Uint8Array = bytes.subarray(cursor, end);
        chunks.push(part);
        payloadLength += part.length;
      }
      cursor = end;
    }
    if (!sanitize) return bytes;
    const output: Uint8Array = new Uint8Array(payloadLength + 8);
    output[0] = 0x52; output[1] = 0x49; output[2] = 0x46; output[3] = 0x46;
    ContainerMetadata.writeUint32Le(output, 4, payloadLength);
    output[8] = 0x57; output[9] = 0x45; output[10] = 0x42; output[11] = 0x50;
    let outputCursor: number = 12;
    for (let index: number = 0; index < chunks.length; index++) {
      output.set(chunks[index], outputCursor);
      outputCursor += chunks[index].length;
    }
    return output;
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

  private static uint32Be(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] * 0x1000000) + (bytes[offset + 1] << 16) +
      (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
  }

  private static uint32Le(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] + (bytes[offset + 1] << 8) + (bytes[offset + 2] << 16) +
      (bytes[offset + 3] * 0x1000000)) >>> 0;
  }

  private static writeUint32Le(bytes: Uint8Array, offset: number, value: number): void {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >>> 8) & 0xFF;
    bytes[offset + 2] = (value >>> 16) & 0xFF;
    bytes[offset + 3] = (value >>> 24) & 0xFF;
  }

  private static ascii(bytes: Uint8Array, start: number, length: number): string {
    let value: string = '';
    for (let index: number = start; index < start + length && index < bytes.length; index++) {
      value += String.fromCharCode(bytes[index]);
    }
    return value;
  }
}
