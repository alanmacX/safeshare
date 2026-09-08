import { PrivacyScanResult, RedactionAction, SanitizedFile } from '../models/PrivacyModels';
import { MetadataPolicy } from '../metadata/MetadataPolicy';

export interface PrivacyProcessor {
  canHandle(uri: string): boolean;
  scan(uri: string): Promise<PrivacyScanResult>;
  sanitize(uri: string, actions: RedactionAction[], policy?: MetadataPolicy): Promise<SanitizedFile>;
  dispose(): Promise<void>;
}
