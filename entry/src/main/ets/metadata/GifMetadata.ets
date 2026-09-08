/**
 * Minimal, fail-closed GIF container parser.
 *
 * Metadata-only cleaning must not decode the animation. We retain the header,
 * palettes, image data, graphic-control/plain-text blocks and the two standard
 * animation-loop application extensions byte-for-byte. Comments and every
 * other application extension are removed because GIF application payloads
 * are an unrestricted metadata channel (including XMP/ICC/vendor data).
 */
export class GifMetadataSummary {
  commentCount: number = 0;
  applicationMetadataCount: number = 0;
}

class GifBlock {
  start: number;
  end: number;
  keep: boolean;

  constructor(start: number, end: number, keep: boolean) {
    this.start = start;
    this.end = end;
    this.keep = keep;
  }
}

export class GifMetadata {
  static isGif(bytes: Uint8Array): boolean {
    return bytes.length >= 6 &&
      (GifMetadata.ascii(bytes, 0, 6) === 'GIF87a' || GifMetadata.ascii(bytes, 0, 6) === 'GIF89a');
  }

  static inspect(bytes: Uint8Array): GifMetadataSummary {
    const summary: GifMetadataSummary = new GifMetadataSummary();
    GifMetadata.parse(bytes, summary);
    return summary;
  }

  static sanitize(bytes: Uint8Array): Uint8Array {
    const summary: GifMetadataSummary = new GifMetadataSummary();
    const blocks: GifBlock[] = GifMetadata.parse(bytes, summary);
    let length: number = 0;
    for (let index: number = 0; index < blocks.length; index++) {
      if (blocks[index].keep) length += blocks[index].end - blocks[index].start;
    }
    const output: Uint8Array = new Uint8Array(length);
    let cursor: number = 0;
    for (let index: number = 0; index < blocks.length; index++) {
      const block: GifBlock = blocks[index];
      if (!block.keep) continue;
      const part: Uint8Array = bytes.subarray(block.start, block.end);
      output.set(part, cursor);
      cursor += part.length;
    }
    // Parse the result as a postcondition, rather than trusting our offsets.
    const verification: GifMetadataSummary = GifMetadata.inspect(output);
    if (verification.commentCount !== 0 || verification.applicationMetadataCount !== 0) {
      throw new Error('GIF metadata remained after rewriting.');
    }
    return output;
  }

  private static parse(bytes: Uint8Array, summary: GifMetadataSummary): GifBlock[] {
    if (!GifMetadata.isGif(bytes) || bytes.length < 13) throw new Error('Invalid GIF header.');
    const blocks: GifBlock[] = [];
    let cursor: number = 13;
    const packed: number = bytes[10];
    if ((packed & 0x80) !== 0) cursor += 3 * (1 << ((packed & 0x07) + 1));
    if (cursor > bytes.length) throw new Error('Invalid GIF global palette.');
    blocks.push(new GifBlock(0, cursor, true));

    while (cursor < bytes.length) {
      const start: number = cursor;
      const marker: number = bytes[cursor++];
      if (marker === 0x3B) {
        if (cursor !== bytes.length) throw new Error('Unexpected data after GIF trailer.');
        blocks.push(new GifBlock(start, cursor, true));
        return blocks;
      }
      if (marker === 0x2C) {
        if (cursor + 9 > bytes.length) throw new Error('Truncated GIF image descriptor.');
        const imagePacked: number = bytes[cursor + 8];
        cursor += 9;
        if ((imagePacked & 0x80) !== 0) cursor += 3 * (1 << ((imagePacked & 0x07) + 1));
        if (cursor >= bytes.length) throw new Error('Truncated GIF image data.');
        cursor++; // LZW minimum code size.
        cursor = GifMetadata.skipSubBlocks(bytes, cursor);
        blocks.push(new GifBlock(start, cursor, true));
        continue;
      }
      if (marker !== 0x21 || cursor >= bytes.length) throw new Error('Invalid GIF block marker.');
      const label: number = bytes[cursor++];
      if (label === 0xF9) {
        if (cursor >= bytes.length) throw new Error('Truncated GIF graphic control block.');
        const size: number = bytes[cursor++];
        cursor += size;
        if (cursor >= bytes.length || bytes[cursor++] !== 0) {
          throw new Error('Invalid GIF graphic control terminator.');
        }
        blocks.push(new GifBlock(start, cursor, true));
        continue;
      }
      if (label === 0xFF) {
        if (cursor >= bytes.length) throw new Error('Truncated GIF application block.');
        const headerSize: number = bytes[cursor++];
        if (cursor + headerSize > bytes.length) throw new Error('Truncated GIF application identifier.');
        const identifier: string = GifMetadata.ascii(bytes, cursor, headerSize);
        cursor += headerSize;
        cursor = GifMetadata.skipSubBlocks(bytes, cursor);
        const animationControl: boolean = identifier === 'NETSCAPE2.0' || identifier === 'ANIMEXTS1.0';
        if (!animationControl) summary.applicationMetadataCount++;
        blocks.push(new GifBlock(start, cursor, animationControl));
        continue;
      }
      cursor = GifMetadata.skipSubBlocks(bytes, cursor);
      const comment: boolean = label === 0xFE;
      if (comment) summary.commentCount++;
      // Plain Text (0x01) is visible media content; unknown extensions are
      // retained because only 0xFF is defined as an application data channel.
      blocks.push(new GifBlock(start, cursor, !comment));
    }
    throw new Error('GIF trailer is missing.');
  }

  private static skipSubBlocks(bytes: Uint8Array, start: number): number {
    let cursor: number = start;
    while (cursor < bytes.length) {
      const size: number = bytes[cursor++];
      if (size === 0) return cursor;
      cursor += size;
      if (cursor > bytes.length) throw new Error('Truncated GIF data sub-block.');
    }
    throw new Error('GIF data sub-block terminator is missing.');
  }

  private static ascii(bytes: Uint8Array, start: number, length: number): string {
    if (start < 0 || start + length > bytes.length) return '';
    let value: string = '';
    for (let index: number = start; index < start + length; index++) {
      value += String.fromCharCode(bytes[index]);
    }
    return value;
  }
}
