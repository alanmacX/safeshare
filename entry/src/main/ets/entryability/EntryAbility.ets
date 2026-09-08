import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TempFileManager } from '../storage/TempFileManager';

/**
 * Base for the single SafeShare receiving entry. Every incoming record keeps
 * its own UTD so mixed image, document and media batches route independently.
 */
export abstract class ShareEntryAbility extends UIAbility {
  protected abstract featureMode(): string;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('sharedUrisPayload', '');
    AppStorage.setOrCreate('sharedUtdsPayload', '');
    AppStorage.setOrCreate('shareArrival', 0);
    AppStorage.setOrCreate('shareReceiveError', '');
    AppStorage.setOrCreate('shareReceivePending', false);
    AppStorage.setOrCreate('shareFeatureMode', '');
    this.receiveShare(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.receiveShare(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', () => {
      // The error is intentionally handled without logging user data.
    });
    this.applyImmersiveWindow(windowStage);
  }

  /**
   * Immersive unified layout: content draws edge-to-edge behind both system
   * bars with fully transparent bar backgrounds so the page background is
   * never visually split. The status-bar content color (dark icons vs white)
   * is owned by the page, which knows its actual background and theme.
   */
  private async applyImmersiveWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000'
      });
    } catch (_) {
      // Never log user data; fall back to system default safe-area layout.
    }
  }

  private async receiveShare(want: Want): Promise<void> {
    if (want.action !== 'ohos.want.action.sendData') {
      return;
    }
    AppStorage.set('shareFeatureMode', this.featureMode());
    AppStorage.set('shareReceivePending', true);
    hilog.error(0x8801, 'SafeShareFlow', 'receive_share_begin');
    try {
      const sharedData: systemShare.SharedData = await systemShare.getSharedData(want);
      const records: systemShare.SharedRecord[] = sharedData.getRecords();
      const uris: string[] = [];
      const utds: string[] = [];
      for (let index: number = 0; index < records.length; index++) {
        const uri: string | undefined = records[index].uri;
        if (uri === undefined || uri.length === 0) {
          continue;
        }
        if (uris.length < 50 && uris.indexOf(uri) < 0) {
          uris.push(uri);
          utds.push(records[index].utd ?? '');
        }
      }
      // Run stale cleanup only after resolving the active share and protect
      // every incoming URI. A cold launch used to delete a SafeShare output
      // before it could be scanned again.
      hilog.error(0x8801, 'SafeShareFlow', `receive_records=${uris.length}`);
      new TempFileManager(this.context).removeStaleFiles(uris);
      hilog.error(0x8801, 'SafeShareFlow', 'stale_cleanup_done');
      if (uris.length > 0) {
        AppStorage.set('shareReceiveError', '');
        AppStorage.set('sharedUrisPayload', JSON.stringify(uris));
        AppStorage.set('sharedUtdsPayload', JSON.stringify(utds));
        AppStorage.set('shareArrival', Date.now());
      } else {
        AppStorage.set('sharedUrisPayload', '');
        AppStorage.set('sharedUtdsPayload', '');
        AppStorage.set('shareReceiveError', '分享内容中没有可处理的文件，支持图片、PDF、Word、Excel、PPT 和音视频。');
        AppStorage.set('shareArrival', Date.now());
      }
    } catch (_) {
      // Provider/Share Kit exception text can contain a URI or file name.
      // Log only a fixed stage marker so diagnostics never expose user data.
      hilog.error(0x8801, 'SafeShareFlow', 'receive_share_failed');
      AppStorage.set('sharedUrisPayload', '');
      AppStorage.set('sharedUtdsPayload', '');
      AppStorage.set('shareReceiveError', '未能读取分享内容，请返回图库后重试。');
      AppStorage.set('shareArrival', Date.now());
    } finally {
      AppStorage.set('shareReceivePending', false);
    }
  }
}

export default class EntryAbility extends ShareEntryAbility {
  protected featureMode(): string {
    return '';
  }
}
