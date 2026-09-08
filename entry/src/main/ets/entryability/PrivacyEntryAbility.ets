import { ShareEntryAbility } from './EntryAbility';

/**
 * The only system share-panel entry for SafeShare. File types are routed
 * after receipt; the system no longer presents separate feature sub-entries.
 */
export default class PrivacyEntryAbility extends ShareEntryAbility {
  protected featureMode(): string {
    return 'PRIVACY';
  }
}
