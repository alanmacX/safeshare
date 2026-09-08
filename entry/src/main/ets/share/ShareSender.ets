import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { SanitizedFile } from '../models/PrivacyModels';
import { TempFileManager } from '../storage/TempFileManager';

export class ShareSender {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async share(files: SanitizedFile[]): Promise<void> {
    if (files.length === 0) {
      throw new Error('No sanitized file is available to share.');
    }
    const firstRecord: systemShare.SharedRecord = {
      utd: files[0].utd,
      uri: files[0].uri,
      title: files.length === 1 ? this.fileName(files[0]) : `${this.fileName(files[0])} 等 ${files.length} 个文件`,
      description: '由净享在本机生成的临时副本'
    };
    const data: systemShare.SharedData = new systemShare.SharedData(firstRecord);
    try {
      for (let index: number = 1; index < files.length; index++) {
        data.addRecord({
          utd: files[index].utd,
          uri: files[index].uri,
          title: this.fileName(files[index]),
          description: '由净享在本机生成的临时副本'
        });
      }
    } catch (_) {
      const failedManager: TempFileManager = new TempFileManager(this.context);
      this.scheduleAll(failedManager, files, 0);
      throw new Error('Unable to prepare all files for sharing.');
    }
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    const manager: TempFileManager = new TempFileManager(this.context);
    controller.on('shareCompleted', () => {
      this.scheduleAll(manager, files);
    });
    controller.on('dismiss', () => {
      this.scheduleAll(manager, files);
    });
    try {
      await controller.show(this.context, { previewMode: systemShare.SharePreviewMode.DEFAULT });
    } catch (_) {
      this.scheduleAll(manager, files, 0);
      throw new Error('Unable to present the system share panel.');
    }
  }

  private scheduleAll(manager: TempFileManager, files: SanitizedFile[], delayMs: number = 120000): void {
    for (let index: number = 0; index < files.length; index++) {
      manager.scheduleRemoval(files[index].path, delayMs);
    }
  }

  private fileName(file: SanitizedFile): string {
    const slash: number = file.path.lastIndexOf('/');
    return slash >= 0 ? file.path.substring(slash + 1) : file.path;
  }
}
