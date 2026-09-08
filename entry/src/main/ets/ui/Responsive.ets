import { mediaquery } from '@kit.ArkUI';
import { MediaQuery } from '@ohos.arkui.UIContext';

/**
 * Device breakpoint, mirroring the official ArkUI 一多 (adaptive layout)
 * breakpoints: xs < 600vp, sm 600–840vp, md 840–1440vp, lg ≥ 1440vp.
 * All responsive decisions in the UI must derive from these instead of
 * ad-hoc width/height heuristics, so phone / foldable / tablet / PC-like
 * canvases behave consistently.
 */
export type DeviceBreakpoint = 'xs' | 'sm' | 'md' | 'lg';

export class BreakpointThresholds {
  static readonly SM: string = '(min-width:600vp)';
  static readonly MD: string = '(min-width:840vp)';
  static readonly LG: string = '(min-width:1440vp)';
}

/**
 * Observes the window width against the official thresholds and reports the
 * active breakpoint. Media-query listeners keep the value live across
 * rotation, folding and window resize without any per-frame polling.
 */
export class BreakpointWatcher {
  private smQuery: mediaquery.MediaQueryListener;
  private mdQuery: mediaquery.MediaQueryListener;
  private lgQuery: mediaquery.MediaQueryListener;
  private handler: ((breakpoint: DeviceBreakpoint) => void) | undefined = undefined;

  constructor(uiContext: UIContext) {
    const mq: MediaQuery = uiContext.getMediaQuery();
    this.smQuery = mq.matchMediaSync(BreakpointThresholds.SM);
    this.mdQuery = mq.matchMediaSync(BreakpointThresholds.MD);
    this.lgQuery = mq.matchMediaSync(BreakpointThresholds.LG);
    const notify = (): void => {
      if (this.handler !== undefined) {
        this.handler(this.current());
      }
    };
    this.smQuery.on('change', notify);
    this.mdQuery.on('change', notify);
    this.lgQuery.on('change', notify);
  }

  current(): DeviceBreakpoint {
    if (this.lgQuery.matches) {
      return 'lg';
    }
    if (this.mdQuery.matches) {
      return 'md';
    }
    if (this.smQuery.matches) {
      return 'sm';
    }
    return 'xs';
  }

  onChange(handler: (breakpoint: DeviceBreakpoint) => void): void {
    this.handler = handler;
    handler(this.current());
  }

  off(): void {
    try {
      this.smQuery.off('change');
      this.mdQuery.off('change');
      this.lgQuery.off('change');
    } catch (_) {
      // Listeners may already be detached during teardown.
    }
    this.handler = undefined;
  }
}
