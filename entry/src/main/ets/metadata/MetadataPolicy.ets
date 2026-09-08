import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export enum MetadataMode {
  RECOMMENDED = 'RECOMMENDED',
  DEEP_CLEAN = 'DEEP_CLEAN',
  CUSTOM = 'CUSTOM'
}

export class MetadataReplacement {
  subtype: string = '';
  value: string = '';

  constructor(subtype: string, value: string) {
    this.subtype = subtype;
    this.value = value;
  }
}

export class MetadataPolicy {
  mode: MetadataMode = MetadataMode.RECOMMENDED;
  preserveCaptureTime: boolean = false;
  preserveCameraInfo: boolean = false;
  preservePhotographyInfo: boolean = true;
  deleteDetectedMetadataByDefault: boolean = true;
  redactFacesByDefault: boolean = true;
  redactQrByDefault: boolean = true;
  defaultPreservedSubtypes: string[] = [];
  // Document defaults (Word/Excel/PPT/PDF): which finding groups are deleted
  // by default. Groups map to concrete subtypes in the page layer.
  docIdentityDefault: boolean = true;
  docOrgDefault: boolean = true;
  docContentTimeDefault: boolean = true;
  preserveSubtypes: string[] = [];
  replacements: MetadataReplacement[] = [];
  captureTime: string = '';
  cameraMake: string = '';
  cameraModel: string = '';
  author: string = '';
  copyright: string = '';
  description: string = '';
  gpsLatitude: string = '';
  gpsLongitude: string = '';
  purposeWatermark: string = '';
  watermarkOpacity: number = 0.22;
  watermarkAngle: number = -24;
  watermarkScale: number = 1;
  watermarkSpacing: number = 1;
  watermarkDarkText: boolean = false;
  watermarkColor: string = '#FFFFFF';
  imageWatermarkUri: string = '';
  imageWatermarkOpacity: number = 0.55;
  imageWatermarkScale: number = 0.24;
  imageWatermarkAngle: number = 0;
  imageWatermarkTiled: boolean = false;
  imageWatermarkPosition: number = 8;
  imageWatermarkMargin: number = 0.035;
  watermarkSlots: string[] = ['仅供办理本次业务使用', '仅供实名认证使用', '仅供资料审核使用'];
}

export class MetadataPolicyStore {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async load(): Promise<MetadataPolicy> {
    const policy: MetadataPolicy = new MetadataPolicy();
    try {
      const store: preferences.Preferences = await preferences.getPreferences(this.context, 'privacy_defaults');
      const modeValue: preferences.ValueType = await store.get('metadata_mode', MetadataMode.RECOMMENDED);
      const mode: string = modeValue.toString();
      if (mode === MetadataMode.DEEP_CLEAN || mode === MetadataMode.CUSTOM) {
        policy.mode = mode as MetadataMode;
      }
      policy.preserveCaptureTime = Boolean(await store.get('preserve_capture_time', false));
      policy.preserveCameraInfo = Boolean(await store.get('preserve_camera_info', false));
      policy.preservePhotographyInfo = Boolean(await store.get('preserve_photography_info', true));
      policy.deleteDetectedMetadataByDefault = Boolean(await store.get('delete_detected_metadata_default', true));
      policy.redactFacesByDefault = Boolean(await store.get('redact_faces_default', true));
      policy.redactQrByDefault = Boolean(await store.get('redact_qr_default', true));
      policy.docIdentityDefault = Boolean(await store.get('doc_identity_default', true));
      policy.docOrgDefault = Boolean(await store.get('doc_org_default', true));
      policy.docContentTimeDefault = Boolean(await store.get('doc_content_time_default', true));
      try {
        const preservedJson: string = (await store.get('default_preserved_subtypes', '[]')).toString();
      policy.defaultPreservedSubtypes = JSON.parse(preservedJson) as string[];
      } catch (_) {
        policy.defaultPreservedSubtypes = [];
      }
      try {
        const slotsJson: string = (await store.get('watermark_slots',
          '["仅供办理本次业务使用","仅供实名认证使用","仅供资料审核使用"]')).toString();
        policy.watermarkSlots = JSON.parse(slotsJson) as string[];
      } catch (_) {
        policy.watermarkSlots = ['仅供办理本次业务使用', '仅供实名认证使用', '仅供资料审核使用'];
      }
      policy.captureTime = (await store.get('replacement_capture_time', '')).toString();
      policy.cameraMake = (await store.get('replacement_camera_make', '')).toString();
      policy.cameraModel = (await store.get('replacement_camera_model', '')).toString();
      policy.author = (await store.get('replacement_author', '')).toString();
      policy.copyright = (await store.get('replacement_copyright', '')).toString();
      policy.description = (await store.get('replacement_description', '')).toString();
      const storedWatermarkColor: string = (await store.get('watermark_color', '#FFFFFF')).toString();
      if (/^#[0-9A-Fa-f]{6}$/.test(storedWatermarkColor)) {
        policy.watermarkColor = storedWatermarkColor.toUpperCase();
        policy.watermarkDarkText = policy.watermarkColor === '#000000';
      }
    } catch (_) {
      return policy;
    }
    return policy;
  }

  async save(policy: MetadataPolicy): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(this.context, 'privacy_defaults');
      await store.put('metadata_mode', policy.mode);
      await store.put('preserve_capture_time', policy.preserveCaptureTime);
      await store.put('preserve_camera_info', policy.preserveCameraInfo);
      await store.put('preserve_photography_info', policy.preservePhotographyInfo);
      await store.put('delete_detected_metadata_default', policy.deleteDetectedMetadataByDefault);
      await store.put('redact_faces_default', policy.redactFacesByDefault);
      await store.put('redact_qr_default', policy.redactQrByDefault);
      await store.put('doc_identity_default', policy.docIdentityDefault);
      await store.put('doc_org_default', policy.docOrgDefault);
      await store.put('doc_content_time_default', policy.docContentTimeDefault);
      await store.put('default_preserved_subtypes', JSON.stringify(policy.defaultPreservedSubtypes));
      await store.put('watermark_slots', JSON.stringify(policy.watermarkSlots));
      await store.put('replacement_capture_time', policy.captureTime);
      await store.put('replacement_camera_make', policy.cameraMake);
      await store.put('replacement_camera_model', policy.cameraModel);
      await store.put('replacement_author', policy.author);
      await store.put('replacement_copyright', policy.copyright);
      await store.put('replacement_description', policy.description);
      await store.put('watermark_color', policy.watermarkColor);
      await store.flush();
    } catch (_) {
      // Defaults remain usable for the current session if persistent storage is unavailable.
    }
  }
}
