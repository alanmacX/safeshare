import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import zlib from '@ohos.zlib';

function zipLog(message: string): void {
  hilog.info(0x8801, 'SafeShareZip', `${message}`);
}

/**
 * Minimal deterministic ZIP container reader/writer used for OOXML
 * sanitization. Entries are copied byte-for-byte; only rewritten entries are
 * stored uncompressed. This avoids any zip tool that could add its own
 * metadata and keeps the sanitized document structurally faithful.
 */

const LOCAL_HEADER_SIGNATURE: number = 0x04034b50;
const CENTRAL_HEADER_SIGNATURE: number = 0x02014b50;
const EOCD_SIGNATURE: number = 0x06054b50;
const EOCD_MIN_LENGTH: number = 22;
const EOCD_MAX_COMMENT: number = 65536;

export class ZipEntry {
  name: string = '';
  flags: number = 0;
  method: number = 0;
  crc32: number = 0;
  compressedSize: number = 0;
  uncompressedSize: number = 0;
  dataOffset: number = 0;

  constructor(name: string, flags: number, method: number, crc32: number,
    compressedSize: number, uncompressedSize: number, dataOffset: number) {
    this.name = name;
    this.flags = flags;
    this.method = method;
    this.crc32 = crc32;
    this.compressedSize = compressedSize;
    this.uncompressedSize = uncompressedSize;
    this.dataOffset = dataOffset;
  }
}

class Crc32Table {
  static readonly INSTANCE: Uint32Array = Crc32Table.build();

  private static build(): Uint32Array {
    const table: Uint32Array = new Uint32Array(256);
    for (let index: number = 0; index < 256; index++) {
      let value: number = index;
      for (let bit: number = 0; bit < 8; bit++) {
        value = (value & 1) === 1 ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
      }
      table[index] = value >>> 0;
    }
    return table;
  }
}

export class ZipContainer {
  static crc32(data: Uint8Array): number {
    const table: Uint32Array = Crc32Table.INSTANCE;
    let crc: number = 0xffffffff;
    for (let index: number = 0; index < data.length; index++) {
      crc = (table[(crc ^ data[index]) & 0xff] ^ (crc >>> 8)) >>> 0;
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  /**
   * Locates the End Of Central Directory record and parses every central
   * directory entry. ZIP64 archives are rejected (OOXML documents are small);
   * callers surface a clear capability warning instead of producing a broken
   * sanitized copy.
   */
  static readEntries(bytes: Uint8Array): ZipEntry[] {
    const eocdOffset: number = ZipContainer.locateEocd(bytes);
    if (eocdOffset < 0) {
      throw new Error('ZIP end of central directory not found.');
    }
    const view: DataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (view.getUint32(eocdOffset + 4, true) === 0xffffffff ||
      view.getUint32(eocdOffset + 16, true) === 0xffffffff) {
      throw new Error('ZIP64 archives are not supported.');
    }
    const entryCount: number = view.getUint16(eocdOffset + 10, true);
    let cursor: number = view.getUint32(eocdOffset + 16, true);
    const entries: ZipEntry[] = [];
    for (let index: number = 0; index < entryCount; index++) {
      if (cursor + 46 > bytes.length || view.getUint32(cursor, true) !== CENTRAL_HEADER_SIGNATURE) {
        throw new Error('ZIP central directory is corrupted.');
      }
      const flags: number = view.getUint16(cursor + 8, true);
      const method: number = view.getUint16(cursor + 10, true);
      const crc32: number = view.getUint32(cursor + 16, true);
      const compressedSize: number = view.getUint32(cursor + 20, true);
      const uncompressedSize: number = view.getUint32(cursor + 24, true);
      const nameLength: number = view.getUint16(cursor + 28, true);
      const extraLength: number = view.getUint16(cursor + 30, true);
      const commentLength: number = view.getUint16(cursor + 32, true);
      const localHeaderOffset: number = view.getUint32(cursor + 42, true);
      const name: string = ZipContainer.decodeName(bytes, cursor + 46, nameLength, flags);
      if (localHeaderOffset + 30 > bytes.length ||
        view.getUint32(localHeaderOffset, true) !== LOCAL_HEADER_SIGNATURE) {
        throw new Error('ZIP local header is corrupted.');
      }
      const localNameLength: number = view.getUint16(localHeaderOffset + 26, true);
      const localExtraLength: number = view.getUint16(localHeaderOffset + 28, true);
      const dataOffset: number = localHeaderOffset + 30 + localNameLength + localExtraLength;
      if (dataOffset + compressedSize > bytes.length) {
        throw new Error('ZIP entry data is out of bounds.');
      }
      entries.push(new ZipEntry(name, flags, method, crc32, compressedSize,
        uncompressedSize, dataOffset));
      cursor += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
  }

  /**
   * Decompresses a raw deflate stream (ZIP method 8) using the on-device zlib
   * runtime through a Zip instance (inflateInit2/inflate/inflateEnd are
   * instance members). Output is sized from the ZIP-declared uncompressed
   * size; callers verify content against the entry's declared CRC32.
   */
  static async inflateRaw(compressed: Uint8Array, uncompressedSize: number): Promise<Uint8Array> {
    // Refuse absurd declared sizes from hostile containers: the output buffer
    // is allocated up front and a crafted header must not amplify memory.
    const MAX_ENTRY_BYTES: number = 256 * 1024 * 1024;
    if (uncompressedSize > MAX_ENTRY_BYTES) {
      throw new Error('ZIP entry declares an unsupported uncompressed size.');
    }
    const capacity: number = uncompressedSize > 0 ? uncompressedSize :
      Math.max(65536, compressed.length * 4);
    let zip: zlib.Zip;
    try {
      zip = zlib.createZipSync();
    } catch (_) {
      zipLog('createZip failed');
      throw new Error('zlib zip instance unavailable.');
    }
    // The object returned by getZStream() is a native-hosted proxy that
    // rejects property writes ("Obj is not a Valid object"). Build a plain
    // ZStream value ourselves and pass it through the whole lifecycle.
    const stream: zlib.ZStream = {
      nextIn: compressed.buffer.slice(compressed.byteOffset,
        compressed.byteOffset + compressed.byteLength),
      availableIn: compressed.length,
      nextOut: new ArrayBuffer(capacity),
      availableOut: capacity
    };
    let initStatus: zlib.ReturnStatus;
    try {
      initStatus = await zip.inflateInit2(stream, -15);
    } catch (_) {
      zipLog('inflateInit2 failed');
      throw new Error('zlib inflateInit2 threw.');
    }
    if (initStatus !== zlib.ReturnStatus.OK) {
      throw new Error('zlib inflateInit2 failed.');
    }
    let status: zlib.ReturnStatus;
    try {
      status = await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
    } catch (_) {
      zipLog('inflate failed');
      throw new Error('zlib inflate threw.');
    }
    if (status !== zlib.ReturnStatus.STREAM_END && status !== zlib.ReturnStatus.OK) {
      await zip.inflateEnd(stream);
      throw new Error('zlib inflate failed.');
    }
    await zip.inflateEnd(stream);
    // The native layer does not write totalOut/availableIn/availableOut back
    // into the caller's ZStream value in this SDK version. The buffer was
    // sized from the ZIP-declared uncompressed size and inflate reached
    // STREAM_END, so the buffer holds exactly the decoded entry. Callers
    // verify the result against the entry's declared CRC32, which fails
    // closed on any length or content mismatch.
    if (uncompressedSize <= 0) {
      throw new Error('zlib inflate has no declared output size.');
    }
    const output: ArrayBuffer = stream.nextOut as ArrayBuffer;
    return new Uint8Array(output, 0, uncompressedSize);
  }

  /**
   * Reassembles a ZIP from copied raw entries plus any entries whose bytes
   * were rewritten (stored uncompressed). All timestamps are a fixed value so
   * the output carries no build-time fingerprint.
   */
  static assemble(originalBytes: Uint8Array, entries: ZipEntry[],
    rewritten: Map<string, Uint8Array>): Uint8Array {
    const outputs: Uint8Array[] = [];
    const offsets: number[] = [];
    let outputLength: number = 0;
    const dosTime: number = 0;
    const dosDate: number = 0x2821; // fixed 2010-01-01, deterministic output

    for (let index: number = 0; index < entries.length; index++) {
      const entry: ZipEntry = entries[index];
      const replacement: Uint8Array | undefined = rewritten.get(entry.name);
      const header: Uint8Array = new Uint8Array(30 + entry.name.length);
      const view: DataView = new DataView(header.buffer);
      view.setUint32(0, LOCAL_HEADER_SIGNATURE, true);
      view.setUint16(4, 20, true);
      view.setUint16(6, 0x0800, true);
      view.setUint16(8, replacement !== undefined ? 0 : entry.method, true);
      view.setUint16(10, dosTime, true);
      view.setUint16(12, dosDate, true);
      if (replacement !== undefined) {
        view.setUint32(14, ZipContainer.crc32(replacement), true);
        view.setUint32(18, replacement.length, true);
        view.setUint32(22, replacement.length, true);
      } else {
        view.setUint32(14, entry.crc32, true);
        view.setUint32(18, entry.compressedSize, true);
        view.setUint32(22, entry.uncompressedSize, true);
      }
      view.setUint16(26, entry.name.length, true);
      view.setUint16(28, 0, true);
      ZipContainer.writeName(header, 30, entry.name);
      offsets.push(outputLength);
      outputs.push(header);
      outputLength += header.length;
      if (replacement !== undefined) {
        outputs.push(replacement);
        outputLength += replacement.length;
      } else {
        const data: Uint8Array = originalBytes.subarray(entry.dataOffset,
          entry.dataOffset + entry.compressedSize);
        const copy: Uint8Array = new Uint8Array(data.length);
        copy.set(data);
        outputs.push(copy);
        outputLength += copy.length;
      }
    }

    const centralStart: number = outputLength;
    for (let index: number = 0; index < entries.length; index++) {
      const entry: ZipEntry = entries[index];
      const replacement: Uint8Array | undefined = rewritten.get(entry.name);
      const central: Uint8Array = new Uint8Array(46 + entry.name.length);
      const view: DataView = new DataView(central.buffer);
      view.setUint32(0, CENTRAL_HEADER_SIGNATURE, true);
      view.setUint16(4, 20, true);
      view.setUint16(6, 20, true);
      view.setUint16(8, 0x0800, true);
      view.setUint16(10, replacement !== undefined ? 0 : entry.method, true);
      view.setUint16(12, dosTime, true);
      view.setUint16(14, dosDate, true);
      if (replacement !== undefined) {
        view.setUint32(16, ZipContainer.crc32(replacement), true);
        view.setUint32(20, replacement.length, true);
        view.setUint32(24, replacement.length, true);
      } else {
        view.setUint32(16, entry.crc32, true);
        view.setUint32(20, entry.compressedSize, true);
        view.setUint32(24, entry.uncompressedSize, true);
      }
      view.setUint16(28, entry.name.length, true);
      view.setUint16(30, 0, true);
      view.setUint16(32, 0, true);
      view.setUint16(34, 0, true);
      view.setUint16(36, 0, true);
      view.setUint32(38, 0, true);
      view.setUint32(42, offsets[index], true);
      ZipContainer.writeName(central, 46, entry.name);
      outputs.push(central);
      outputLength += central.length;
    }

    const eocd: Uint8Array = new Uint8Array(EOCD_MIN_LENGTH);
    const eocdView: DataView = new DataView(eocd.buffer);
    eocdView.setUint32(0, EOCD_SIGNATURE, true);
    eocdView.setUint16(8, entries.length, true);
    eocdView.setUint16(10, entries.length, true);
    eocdView.setUint32(12, outputLength - centralStart, true);
    eocdView.setUint32(16, centralStart, true);
    outputs.push(eocd);
    outputLength += eocd.length;

    const result: Uint8Array = new Uint8Array(outputLength);
    let position: number = 0;
    for (let index: number = 0; index < outputs.length; index++) {
      result.set(outputs[index], position);
      position += outputs[index].length;
    }
    return result;
  }

  static async readFileBytes(path: string): Promise<Uint8Array> {
    const stat: fileIo.Stat = fileIo.statSync(path);
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = await fileIo.read(file.fd, buffer);
      if (read !== stat.size) {
        throw new Error('Short read on document file.');
      }
      return new Uint8Array(buffer);
    } finally {
      try { fileIo.closeSync(file.fd); } catch (_) {
      }
    }
  }

  static async writeFileBytes(path: string, bytes: Uint8Array): Promise<void> {
    const file: fileIo.File = await fileIo.open(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, bytes.buffer);
    } finally {
      try { fileIo.closeSync(file.fd); } catch (_) {
      }
    }
  }

  private static locateEocd(bytes: Uint8Array): number {
    const view: DataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const minStart: number = Math.max(0, bytes.length - EOCD_MIN_LENGTH - EOCD_MAX_COMMENT);
    for (let offset: number = bytes.length - EOCD_MIN_LENGTH; offset >= minStart; offset--) {
      if (view.getUint32(offset, true) === EOCD_SIGNATURE) {
        return offset;
      }
    }
    return -1;
  }

  private static decodeName(bytes: Uint8Array, offset: number, length: number,
    flags: number): string {
    const raw: Uint8Array = bytes.subarray(offset, offset + length);
    if ((flags & 0x0800) !== 0) {
      return ZipContainer.utf8Decode(raw);
    }
    // OOXML defines ASCII entry names; fall back to UTF-8 which matches it.
    return ZipContainer.utf8Decode(raw);
  }

  private static utf8Decode(raw: Uint8Array): string {
    let result: string = '';
    let index: number = 0;
    while (index < raw.length) {
      const byte: number = raw[index];
      if (byte < 0x80) {
        result += String.fromCharCode(byte);
        index += 1;
      } else if (byte < 0xe0) {
        result += String.fromCharCode(((byte & 0x1f) << 6) | (raw[index + 1] & 0x3f));
        index += 2;
      } else if (byte < 0xf0) {
        result += String.fromCharCode(((byte & 0x0f) << 12) |
          ((raw[index + 1] & 0x3f) << 6) | (raw[index + 2] & 0x3f));
        index += 3;
      } else {
        const codePoint: number = ((byte & 0x07) << 18) | ((raw[index + 1] & 0x3f) << 12) |
          ((raw[index + 2] & 0x3f) << 6) | (raw[index + 3] & 0x3f);
        result += String.fromCharCode(codePoint);
        index += 4;
      }
    }
    return result;
  }

  private static writeName(target: Uint8Array, offset: number, name: string): void {
    for (let index: number = 0; index < name.length; index++) {
      const code: number = name.charCodeAt(index);
      if (code > 0x7f) {
        throw new Error('Non-ASCII ZIP entry name is not supported.');
      }
      target[offset + index] = code;
    }
  }
}
