import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export type HandSide = 'left' | 'right';

/**
 * Multimodal Awareness Kit — 获取用户动作
 * https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/motion-guidelines
 *
 * operatingHandChanged — API 15+（谁在点屏幕）
 * holdingHandChanged  — API 20+（握持手 / 智感握姿）
 *
 * Both need ohos.permission.DETECT_GESTURE (or ACTIVITY_MOTION for operating).
 * holdingHandChanged returns 801 when Settings → 系统 → 智感握姿 is missing.
 */
export class MotionHandService {
  private holdingCallback: ((status: motion.HoldingHandStatus) => void) | undefined = undefined;
  private operatingCallback: ((status: motion.OperatingHandStatus) => void) | undefined = undefined;
  private started: boolean = false;

  /** Returns true when at least one subscription is active. */
  start(onHand: (hand: HandSide) => void): boolean {
    if (this.started) return true;
    this.operatingCallback = (status: motion.OperatingHandStatus): void => {
      const hand: HandSide | undefined = MotionHandService.operatingToSide(status);
      hilog.info(0x8801, 'SafeShareHand', `operating=${status} hand=${hand ?? '-'}`);
      if (hand !== undefined) onHand(hand);
    };
    this.holdingCallback = (status: motion.HoldingHandStatus): void => {
      const hand: HandSide | undefined = MotionHandService.holdingToSide(status);
      hilog.info(0x8801, 'SafeShareHand', `holding=${status} hand=${hand ?? '-'}`);
      if (hand !== undefined) onHand(hand);
    };
    let operatingOk: boolean = false;
    let holdingOk: boolean = false;
    try {
      motion.on('operatingHandChanged', this.operatingCallback);
      operatingOk = true;
    } catch (err) {
      const code: number = (err as BusinessError).code ?? -1;
      hilog.warn(0x8801, 'SafeShareHand', `on_operating_failed code=${code}`);
    }
    try {
      motion.on('holdingHandChanged', this.holdingCallback);
      holdingOk = true;
    } catch (err) {
      const code: number = (err as BusinessError).code ?? -1;
      hilog.warn(0x8801, 'SafeShareHand', `on_holding_failed code=${code}`);
    }
    this.started = operatingOk || holdingOk;
    if (!this.started) {
      // Keep callbacks only when a subscription is live.
      this.operatingCallback = undefined;
      this.holdingCallback = undefined;
    }
    return this.started;
  }

  stop(): void {
    if (!this.started) return;
    this.started = false;
    try {
      if (this.operatingCallback !== undefined) {
        motion.off('operatingHandChanged', this.operatingCallback);
      }
    } catch (_) {}
    try {
      if (this.holdingCallback !== undefined) {
        motion.off('holdingHandChanged', this.holdingCallback);
      }
    } catch (_) {}
    this.operatingCallback = undefined;
    this.holdingCallback = undefined;
  }

  static holdingToSide(status: motion.HoldingHandStatus): HandSide | undefined {
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) return 'left';
    if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) return 'right';
    return undefined;
  }

  static operatingToSide(status: motion.OperatingHandStatus): HandSide | undefined {
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) return 'left';
    if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) return 'right';
    return undefined;
  }
}
