import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

const TEMP_PREFIX: string = 'safeshare-';

export class WatermarkAsset {
  path: string;
  uri: string;
  width: number;
  height: number;

  constructor(path: string, uri: string, width: number, height: number) {
    this.path = path;
    this.uri = uri;
    this.width = width;
    this.height = height;
  }
}

export class TempFileManager {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  sandboxDir(): string {
    return this.context.cacheDir;
  }

  createPath(extension: string = 'jpg'): string {
    const randomPart: string = Math.random().toString(36).slice(2, 12);
    return `${this.context.cacheDir}/${TEMP_PREFIX}${Date.now()}-${randomPart}.${extension}`;
  }

  /**
   * Creates an isolated output directory while keeping the visible basename
   * identical to the source. Isolation prevents collisions when a batch
   * contains files with the same name; the directory itself is never shared.
   */
  createOutputPath(sourceUri: string, fallbackExtension: string): string {
    const randomPart: string = Math.random().toString(36).slice(2, 12);
    const directory: string = `${this.context.cacheDir}/${TEMP_PREFIX}${Date.now()}-${randomPart}`;
    try {
      fileIo.mkdirSync(directory);
    } catch (_) {
      throw new Error('Unable to prepare the temporary output directory.');
    }
    return `${directory}/${this.displayNameForUri(sourceUri, fallbackExtension)}`;
  }

  displayNameForUri(uri: string, fallbackExtension: string): string {
    let value: string = uri;
    const query: number = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    const fragment: number = value.indexOf('#');
    if (fragment >= 0) value = value.substring(0, fragment);
    const slash: number = value.lastIndexOf('/');
    value = slash >= 0 ? value.substring(slash + 1) : value;
    try { value = decodeURIComponent(value); } catch (_) {}
    value = value.replace(/[\\/\u0000-\u001f\u007f]/g, '_').trim();
    const hasExtension: boolean = value.lastIndexOf('.') > 0;
    if (value.length === 0 || value === '.' || value === '..' || !hasExtension) {
      const extension: string = fallbackExtension.replace(/^\./, '');
      return `文件.${extension}`;
    }
    return value.slice(0, 180);
  }

  async remove(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (_) {
      // Cleanup is idempotent. The file may already be gone.
    }
    // Named outputs live one level below a unique safeshare-* directory.
    // Remove that empty parent as part of the same cleanup lifecycle.
    const slash: number = path.lastIndexOf('/');
    if (slash > this.context.cacheDir.length) {
      const parent: string = path.substring(0, slash);
      const name: string = parent.substring(parent.lastIndexOf('/') + 1);
      if (parent.startsWith(`${this.context.cacheDir}/`) && name.startsWith(TEMP_PREFIX)) {
        try { await fileIo.rmdir(parent); } catch (_) {}
      }
    }
  }

  async importWatermark(sourceUri: string): Promise<WatermarkAsset> {
    const path: string = this.createPath('watermark');
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    try {
      source = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      destination = await fileIo.open(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await fileIo.copyFile(source.fd, destination.fd);
      const imageSource: image.ImageSource = image.createImageSource(destination.fd);
      try {
        const info: image.ImageInfo = await imageSource.getImageInfo();
        return new WatermarkAsset(path, fileUri.getUriFromPath(path), info.size.width, info.size.height);
      } finally {
        try { imageSource.release(); } catch (_) {}
      }
    } catch (_) {
      await this.remove(path);
      throw new Error('Unable to import watermark image.');
    } finally {
      if (destination !== undefined) {
        try { fileIo.closeSync(destination); } catch (_) {}
      }
      if (source !== undefined) {
        try { fileIo.closeSync(source); } catch (_) {}
      }
    }
  }

  scheduleRemoval(path: string, delayMs: number = 120000): void {
    setTimeout(() => {
      this.remove(path);
    }, delayMs);
  }

  async removeStaleFiles(protectedUris: string[] = []): Promise<void> {
    try {
      const names: string[] = await fileIo.listFile(this.context.cacheDir);
      for (let index: number = 0; index < names.length; index++) {
        const name: string = names[index];
        if (name.startsWith(TEMP_PREFIX)) {
          let protectedEntry: boolean = false;
          for (let protectedIndex: number = 0; protectedIndex < protectedUris.length; protectedIndex++) {
            let protectedUri: string = protectedUris[protectedIndex];
            try { protectedUri = decodeURIComponent(protectedUri); } catch (_) {}
            if (protectedUri.indexOf(`/${name}/`) >= 0 || protectedUri.endsWith(`/${name}`)) {
              protectedEntry = true;
              break;
            }
          }
          if (protectedEntry) continue;
          const path: string = `${this.context.cacheDir}/${name}`;
          try {
            const stat: fileIo.Stat = fileIo.statSync(path);
            if (stat.isDirectory()) {
              const children: string[] = await fileIo.listFile(path);
              for (let childIndex: number = 0; childIndex < children.length; childIndex++) {
                try { await fileIo.unlink(`${path}/${children[childIndex]}`); } catch (_) {}
              }
              try { await fileIo.rmdir(path); } catch (_) {}
            } else {
              await this.remove(path);
            }
          } catch (_) {}
        }
      }
    } catch (_) {
      // A missing or inaccessible cache directory must not block app startup.
    }
  }
}
