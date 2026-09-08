import { fileIo } from '@kit.CoreFileKit';
import { FileKind, FileTypeRouter } from './FileTypeRouter';
import { ZipContainer, ZipEntry } from '../metadata/ZipContainer';

/**
 * Resolves extensionless/provider-backed URIs from a small read-only header.
 * No paths or payload bytes are logged or retained.
 */
export class FileSignatureRouter {
  // Large enough to cover the OLE2 stream directory that names the Office
  // family (.xls "Workbook" / .doc "WordDocument"); short files simply read less.
  private static readonly HEADER_BYTES: number = 2048;

  static async detect(uri: string): Promise<FileKind> {
    let source: fileIo.File | undefined = undefined;
    try {
      source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      // The provider's own display name is the strongest identity signal for
      // share URIs whose path form hides the extension (datashare://…,
      // stripped tmp names). Extension-first keeps the ZIP sniff below as the
      // per-file source of truth inside the OOXML families.
      const nameKind: FileKind = FileTypeRouter.detect(source.name ?? '', '');
      const buffer: ArrayBuffer = new ArrayBuffer(FileSignatureRouter.HEADER_BYTES);
      const count: number = fileIo.readSync(source.fd, buffer,
        { length: FileSignatureRouter.HEADER_BYTES });
      const header: Uint8Array = new Uint8Array(buffer, 0, Math.max(0, count));
      const headerKind: FileKind = FileSignatureRouter.detectBytes(header);
      // DOCX/XLSX/PPTX are all ZIP files. Share providers may attach the UTD
      // of only the first selected record to an entire mixed batch, so the
      // OOXML package structure is the only per-file source of truth.
      if (FileSignatureRouter.isZip(header)) {
        return await FileSignatureRouter.detectOoxml(source);
      }
      if (nameKind !== FileKind.UNKNOWN) {
        return nameKind;
      }
      return headerKind;
    } catch (_) {
      return FileKind.UNKNOWN;
    } finally {
      try {
        if (source !== undefined) fileIo.closeSync(source);
      } catch (_) {
      }
    }
  }

  private static isZip(bytes: Uint8Array): boolean {
    return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4B &&
      ((bytes[2] === 0x03 && bytes[3] === 0x04) ||
        (bytes[2] === 0x05 && bytes[3] === 0x06) ||
        (bytes[2] === 0x07 && bytes[3] === 0x08));
  }

  private static async detectOoxml(source: fileIo.File): Promise<FileKind> {
    try {
      // Reuse the descriptor that already succeeded above. Some share/file
      // providers grant a URI for one open operation only; reopening the URI
      // made the signature probe fail and the whole mixed batch then fell
      // back to the first record's UTD (for example, every item became Word).
      const size: number = fileIo.statSync(source.fd).size;
      if (size <= 0) return FileKind.UNKNOWN;
      fileIo.lseek(source.fd, 0, fileIo.WhenceType.SEEK_SET);
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = await fileIo.read(source.fd, buffer);
      if (read !== size) return FileKind.UNKNOWN;
      const bytes: Uint8Array = new Uint8Array(buffer);
      const entries: ZipEntry[] = ZipContainer.readEntries(bytes);
      let hasWord: boolean = false;
      let hasExcel: boolean = false;
      let hasPowerPoint: boolean = false;
      for (let index: number = 0; index < entries.length; index++) {
        const name: string = entries[index].name.toLowerCase();
        if (name.startsWith('word/')) hasWord = true;
        if (name.startsWith('xl/')) hasExcel = true;
        if (name.startsWith('ppt/')) hasPowerPoint = true;
      }
      if (hasWord && !hasExcel && !hasPowerPoint) return FileKind.WORD;
      if (hasExcel && !hasWord && !hasPowerPoint) return FileKind.EXCEL;
      if (hasPowerPoint && !hasWord && !hasExcel) return FileKind.POWERPOINT;
      return FileKind.UNKNOWN;
    } catch (_) {
      return FileKind.UNKNOWN;
    }
  }

  private static detectBytes(bytes: Uint8Array): FileKind {
    // Legacy OLE2 compound files (.doc/.xls/.ppt). The family is decided by
    // the caller through extension/UTD; the magic here only prevents these
    // documents from being reported as anonymous unknown files.
    if (bytes.length >= 8 && bytes[0] === 0xD0 && bytes[1] === 0xCF &&
      bytes[2] === 0x11 && bytes[3] === 0xE0 && bytes[4] === 0xA1 &&
      bytes[5] === 0xB1 && bytes[6] === 0x1A && bytes[7] === 0xE1) {
      return FileSignatureRouter.detectOleFamily(bytes);
    }
    if (bytes.length >= 5 && FileSignatureRouter.ascii(bytes, 0, 5) === '%PDF-') {
      return FileKind.PDF;
    }
    if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
      return FileKind.IMAGE;
    }
    if (bytes.length >= 8 && bytes[0] === 0x89 &&
      FileSignatureRouter.ascii(bytes, 1, 3) === 'PNG') {
      return FileKind.IMAGE;
    }
    if (bytes.length >= 6) {
      const gif: string = FileSignatureRouter.ascii(bytes, 0, 6);
      if (gif === 'GIF87a' || gif === 'GIF89a') return FileKind.IMAGE;
    }
    if (bytes.length >= 12 && FileSignatureRouter.ascii(bytes, 0, 4) === 'RIFF') {
      const riffKind: string = FileSignatureRouter.ascii(bytes, 8, 4);
      if (riffKind === 'WEBP') return FileKind.IMAGE;
      if (riffKind === 'WAVE' || riffKind === 'AVI ') return FileKind.AUDIO_VIDEO;
    }
    if (bytes.length >= 2 && FileSignatureRouter.ascii(bytes, 0, 2) === 'BM') {
      return FileKind.IMAGE;
    }
    if (bytes.length >= 12 && FileSignatureRouter.ascii(bytes, 4, 4) === 'ftyp') {
      const brand: string = FileSignatureRouter.ascii(bytes, 8, 4).toLowerCase();
      if (FileSignatureRouter.isStillImageBrand(brand)) return FileKind.IMAGE;
      return FileKind.AUDIO_VIDEO;
    }
    if (bytes.length >= 4) {
      const magic: string = FileSignatureRouter.ascii(bytes, 0, 4);
      if (magic === 'fLaC' || magic === 'OggS') return FileKind.AUDIO_VIDEO;
    }
    if (bytes.length >= 3 && FileSignatureRouter.ascii(bytes, 0, 3) === 'ID3') {
      return FileKind.AUDIO_VIDEO;
    }
    if (bytes.length >= 6 && FileSignatureRouter.ascii(bytes, 0, 6) === '#!AMR\n') {
      return FileKind.AUDIO_VIDEO;
    }
    return FileKind.UNKNOWN;
  }

  /**
   * OLE2 documents store their stream directory near the file head, so the
   * well-known stream names identify the Office family without parsing the
   * full compound-file structure.
   */
  private static detectOleFamily(bytes: Uint8Array): FileKind {
    const window: string = FileSignatureRouter.ascii(bytes, 0,
      Math.min(bytes.length, 1536));
    if (window.indexOf('Workbook') >= 0 || window.indexOf('Book') >= 0) {
      return FileKind.EXCEL;
    }
    if (window.indexOf('WordDocument') >= 0) {
      return FileKind.WORD;
    }
    if (window.indexOf('PowerPoint') >= 0 || window.indexOf('Current User') >= 0) {
      return FileKind.POWERPOINT;
    }
    return FileKind.UNKNOWN;
  }

  private static isStillImageBrand(brand: string): boolean {
    return ['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1', 'avif', 'avis']
      .indexOf(brand) >= 0;
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
