import { liveViewManager } from '@kit.LiveViewKit';

/**
 * Best-effort Live View for a user-started batch export. It deliberately
 * carries counts only: no source URI, filename, metadata value or finding is
 * ever copied into the system surface.
 *
 * Live View is entitlement-gated and unavailable on the emulator, so every
 * API failure degrades silently to the in-app progress UI.
 */
export class BatchLiveViewService {
  private liveViewId: number = 0;
  private sequence: number = 0;
  private active: boolean = false;
  private lastUpdateAt: number = 0;
  private lastProgress: number = 0;
  private runVersion: number = 0;

  begin(total: number): void {
    const version: number = ++this.runVersion;
    if (total < 2) return;
    // Do not flash a system surface for batches that finish quickly.
    setTimeout(() => this.startIfCurrent(total, version), 1500);
  }

  private async startIfCurrent(total: number, version: number): Promise<void> {
    if (version !== this.runVersion || this.active) return;
    try {
      if (!await liveViewManager.isLiveViewEnabled()) return;
      if (version !== this.runVersion) return;
      this.liveViewId = Math.floor(Date.now() % 2000000000);
      this.sequence = 0;
      this.lastProgress = 0;
      await liveViewManager.startLiveView(this.buildView(0, total, false, true));
      if (version !== this.runVersion) {
        this.sequence++;
        await liveViewManager.stopLiveView(this.buildView(0, total, true, false));
        this.clear();
        return;
      }
      this.active = true;
      this.lastUpdateAt = Date.now();
    } catch (_) {
      this.clear();
    }
  }

  async update(completed: number, total: number): Promise<void> {
    if (!this.active || total < 1) return;
    const progress: number = Math.min(99, Math.max(0, Math.round(completed * 100 / total)));
    const now: number = Date.now();
    // Huawei recommends at least a one-second interval. Per-file callbacks
    // can be much faster, so intermediate updates are coalesced.
    if (progress <= this.lastProgress || now - this.lastUpdateAt < 1000) return;
    try {
      this.sequence++;
      await liveViewManager.updateLiveView(this.buildView(completed, total, false, true));
      this.lastProgress = progress;
      this.lastUpdateAt = now;
    } catch (_) {
      // Keep the batch running even if the system surface rejects an update.
    }
  }

  async finish(success: boolean, total: number): Promise<void> {
    this.runVersion++;
    if (!this.active) return;
    try {
      this.sequence++;
      await liveViewManager.stopLiveView(this.buildView(success ? total : 0, total, true, success));
    } catch (_) {
    } finally {
      this.clear();
    }
  }

  private buildView(completed: number, total: number, finished: boolean,
    success: boolean): liveViewManager.LiveView {
    const safeTotal: number = Math.max(1, total);
    const progress: number = success ? Math.min(100,
      Math.max(0, Math.round(completed * 100 / safeTotal))) : this.lastProgress;
    const title: string = finished ? (success ? '安全副本已生成' : '批量处理未完成') : '正在生成安全副本';
    const content: string = finished ? (success ? `共完成 ${safeTotal} 个文件` : '请返回净享重试') :
      `已完成 ${Math.min(completed, safeTotal)}/${safeTotal} 个文件`;
    return {
      id: this.liveViewId,
      event: 'PROGRESS',
      sequence: this.sequence,
      isMute: !finished,
      liveViewData: {
        primary: {
          title: title,
          content: [{ text: content }],
          keepTime: finished ? 300000 : 0,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: progress,
            color: '#FF087D68',
            backgroundColor: '#FFE4F3EF',
            lineType: liveViewManager.LineType.LINE_TYPE_THICK_SOLID_LINE
          }
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_PROGRESS,
          status: finished ? 0 : 1,
          backgroundColor: '#FF087D68',
          max: 100,
          progress: progress,
          indeterminate: false,
          content: `${progress}%`
        }
      }
    };
  }

  private clear(): void {
    this.active = false;
    this.liveViewId = 0;
    this.sequence = 0;
    this.lastUpdateAt = 0;
    this.lastProgress = 0;
  }
}
