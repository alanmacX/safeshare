import { common } from '@kit.AbilityKit';
import { PrivacyFinding, PrivacyScanResult, RedactionAction, SanitizedFile } from '../models/PrivacyModels';
import { MetadataSanitizer } from '../metadata/MetadataSanitizer';
import { PrivacyScanner } from '../privacy/PrivacyScanner';
import { PrivacyProcessor } from './PrivacyProcessor';
import { TempFileManager } from '../storage/TempFileManager';
import { MetadataPolicy } from '../metadata/MetadataPolicy';

export class ImagePrivacyProcessor implements PrivacyProcessor {
  private scanner: PrivacyScanner;
  private sanitizer: MetadataSanitizer;
  private tempFiles: TempFileManager;

  constructor(context: common.UIAbilityContext) {
    this.scanner = new PrivacyScanner(context);
    this.sanitizer = new MetadataSanitizer(context);
    this.tempFiles = new TempFileManager(context);
  }

  canHandle(uri: string): boolean {
    return uri.startsWith('file://') || uri.startsWith('datashare://') || uri.startsWith('content://');
  }

  scan(uri: string): Promise<PrivacyScanResult> {
    return this.scanner.scan(uri);
  }

  async sanitize(uri: string, actions: RedactionAction[], policy: MetadataPolicy = new MetadataPolicy()): Promise<SanitizedFile> {
    const file: SanitizedFile = await this.sanitizer.sanitize(uri, actions, policy);
    if (actions.length === 0) {
      return file;
    }
    try {
      const remaining: PrivacyFinding[] = await this.scanner.verifyVisual(file.uri, actions);
      if (remaining.length > 0) {
        throw new Error('Visual privacy verification failed.');
      }
      return file;
    } catch (_) {
      await this.tempFiles.remove(file.path);
      throw new Error('Unable to verify visual redaction.');
    }
  }

  dispose(): Promise<void> {
    return this.scanner.dispose();
  }
}
