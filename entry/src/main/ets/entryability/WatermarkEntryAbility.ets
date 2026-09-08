import { ShareEntryAbility } from './EntryAbility';

/**
 * Share-panel entry for the watermark pipeline. Appears in the system share
 * sheet as its own icon+label so users can share photos straight into
 * purpose-watermark processing without an in-app mode picker.
 */
export default class WatermarkEntryAbility extends ShareEntryAbility {
  protected featureMode(): string {
    return 'WATERMARK';
  }
}
