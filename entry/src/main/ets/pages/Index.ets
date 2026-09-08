import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics, SymbolGlyphModifier, ColorMetrics, display, mediaquery, window } from '@kit.ArkUI';
import { TabSegmentButtonV2, SegmentButtonV2Items } from '@ohos.arkui.advanced.SegmentButtonV2';
import { hdsMaterial, HdsNavigation, HdsNavDestination, ScrollEffectType,
  BlurStrategy, HdsListItemCard, SuffixArrow, SuffixSwitch, HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { image } from '@kit.ImageKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { unifiedDataChannel } from '@kit.ArkData';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RedactionAction, RedactionStyle, RiskLevel,
  SanitizedFile, SensitiveRegion } from '../models/PrivacyModels';
import { SafeShareService } from '../services/SafeShareService';
import { RedactionPixels } from '../privacy/RedactionPixels';
import { runRedaction } from '../privacy/RedactionTask';
import { MetadataMode, MetadataPolicy, MetadataPolicyStore, MetadataReplacement } from '../metadata/MetadataPolicy';
import { BreakpointWatcher, DeviceBreakpoint } from '../ui/Responsive';
import { TutorialOverlay } from './TutorialOverlay';
import { preferences } from '@kit.ArkData';
import { WatermarkAsset } from '../storage/TempFileManager';
import { PdfWatermarkOptions } from '../processors/DocumentPrivacyProcessor';
import { FileKind, FileTypeRouter } from '../processors/FileTypeRouter';
import { BatchLiveViewService } from '../services/BatchLiveViewService';

enum PageStatus {
  HOME = 'HOME',
  SCANNING = 'SCANNING',
  RESULT = 'RESULT',
  SANITIZING = 'SANITIZING',
  READY = 'READY',
  ERROR = 'ERROR'
}

enum FeatureMode {
  PRIVACY = 'PRIVACY',
  WATERMARK = 'WATERMARK'
}

enum HomeTab {
  PHOTO = 'PHOTO',
  FILES = 'FILES'
}

class ScanPageParam {
}

/** Document finding groups backing the 文件 default settings toggles. */
const DOC_IDENTITY_SUBTYPES: string[] = ['DOCX_AUTHOR', 'DOCX_LAST_MODIFIED_BY', 'DOCX_MANAGER',
  'PDF_AUTHOR'];
const DOC_ORG_SUBTYPES: string[] = ['DOCX_COMPANY', 'DOCX_HYPERLINK_BASE', 'DOCX_CUSTOM_PROPS'];
const DOC_CONTENT_TIME_SUBTYPES: string[] = ['DOCX_TITLE', 'DOCX_SUBJECT', 'DOCX_DESCRIPTION',
  'DOCX_KEYWORDS', 'DOCX_CREATE_TIME', 'DOCX_MODIFY_TIME', 'PDF_TITLE', 'PDF_SUBJECT',
  'PDF_KEYWORDS', 'PDF_CREATOR', 'PDF_PRODUCER', 'PDF_CREATE_TIME', 'PDF_MODIFY_TIME'];

class MetadataDefaultOption {
  subtype: string;
  title: string;

  constructor(subtype: string, title: string) {
    this.subtype = subtype;
    this.title = title;
  }
}

const METADATA_DEFAULT_OPTIONS: MetadataDefaultOption[] = [
  new MetadataDefaultOption('GPS', '精确拍摄位置'),
  new MetadataDefaultOption('CAPTURE_TIME', '拍摄时间'),
  new MetadataDefaultOption('MODIFY_TIME', '修改时间'),
  new MetadataDefaultOption('DIGITIZED_TIME', '数字化时间'),
  new MetadataDefaultOption('DEVICE_MAKE', '设备品牌'),
  new MetadataDefaultOption('DEVICE_MODEL', '设备型号'),
  new MetadataDefaultOption('LENS_MODEL', '镜头型号'),
  new MetadataDefaultOption('SOFTWARE', '处理软件'),
  new MetadataDefaultOption('AUTHOR', '作者信息'),
  new MetadataDefaultOption('COPYRIGHT', '版权信息'),
  new MetadataDefaultOption('COMMENT', '图片备注'),
  new MetadataDefaultOption('DESCRIPTION', '图片描述'),
  new MetadataDefaultOption('CAMERA_OWNER', '设备所有者'),
  new MetadataDefaultOption('BODY_SERIAL', '机身序列号'),
  new MetadataDefaultOption('LENS_SERIAL', '镜头序列号'),
  new MetadataDefaultOption('GPS_ALTITUDE', '拍摄海拔'),
  new MetadataDefaultOption('GPS_DATE', '定位日期'),
  new MetadataDefaultOption('GPS_METHOD', '定位方式'),
  new MetadataDefaultOption('GPS_AREA', '定位区域')
];

@Entry
@Component
struct Index {
  @StorageLink('sharedUrisPayload') sharedUrisPayload: string = '';
  @StorageLink('sharedUtdsPayload') sharedUtdsPayload: string = '';
  @StorageLink('shareArrival') @Watch('onShareArrivalChanged') shareArrival: number = 0;
  @StorageLink('shareReceiveError') shareReceiveError: string = '';
  @StorageLink('shareReceivePending') @Watch('onSharePendingChanged') shareReceivePending: boolean = false;
  @StorageLink('shareFeatureMode') shareFeatureMode: string = '';
  @State status: PageStatus = PageStatus.HOME;
  @State selectedUri: string = '';
  @State selectedUris: string[] = [];
  @State findings: PrivacyFinding[] = [];
  @State message: string = '';
  @State sanitizedFiles: SanitizedFile[] = [];
  @State capabilityWarnings: string[] = [];
  @State showSafePreview: boolean = false;
  @State appliedVisualCount: number = 0;
  @State removedEntryCount: number = 0;
  // True while the option pane is sliding out (生成副本). The pane keeps its
  // offset until the status actually flips in the animation's onFinish, so
  // the progress card can never inherit the exit motion.
  @State optionsOut: boolean = false;
  // True after the exit animation finished: the pane unmounts so the content
  // behind it backfills the vacated space (both orientations).
  @State optionsRemoved: boolean = false;
  @State previewIndex: number = 0;
  @State redactionStyle: RedactionStyle = RedactionStyle.AUTO;
  @State watermarkApplied: boolean = false;
  @State derivedFindings: PrivacyFinding[] = [];
  @State viewportWidth: number = 400;
  @State viewportHeight: number = 800;
  @State featureMode: FeatureMode = FeatureMode.PRIVACY;
  @State homeTab: HomeTab = HomeTab.PHOTO;
  @State homeTabPhotoMode: FeatureMode = FeatureMode.PRIVACY;
  @State showSettingsSheet: boolean = false;
  // In-sheet two-level navigation: 'menu' or one of the category pages.
  @State settingsPage: string = 'menu';
  @State isDropTargetActive: boolean = false;
  @State showMetadataDetails: boolean = true;
  @State expandedMetadataId: string = '';
  @State replacementSheetVisible: boolean = false;
  @State replacementFindingId: string = '';
  @State replacementDraft: string = '';
  @State metadataMode: MetadataMode = MetadataMode.RECOMMENDED;
  @State preserveCaptureTime: boolean = false;
  @State preserveCameraInfo: boolean = false;
  @State preservePhotographyInfo: boolean = true;
  @State deleteDetectedMetadataByDefault: boolean = true;
  @State redactFacesByDefault: boolean = true;
  @State redactQrByDefault: boolean = true;
  @State defaultPreservedSubtypes: string[] = [];
  @State docIdentityDefault: boolean = true;
  @State docOrgDefault: boolean = true;
  @State docContentTimeDefault: boolean = true;
  @State replacementCaptureTime: string = '';
  @State replacementCameraMake: string = '';
  @State replacementCameraModel: string = '';
  @State replacementAuthor: string = '';
  @State replacementCopyright: string = '';
  @State replacementDescription: string = '';
  @State replacementGpsLatitude: string = '';
  @State replacementGpsLongitude: string = '';
  @State purposeWatermark: string = '';
  @State watermarkSlots: string[] = ['仅供办理本次业务使用', '仅供实名认证使用', '仅供资料审核使用'];
  @State watermarkCustomMode: boolean = false;
  @State selectedWatermarkSlot: number = 0;
  @State watermarkOpacity: number = 0.22;
  @State watermarkAngle: number = -24;
  @State watermarkScale: number = 1;
  @State watermarkSpacing: number = 1;
  @State watermarkDarkText: boolean = false;
  @State watermarkColor: string = '#FFFFFF';
  @State customWatermarkColor: string = '#007D6E';
  @State colorPickerVisible: boolean = false;
  @State colorPickerDraft: string = '#007D6E';
  @State colorPickerRed: number = 0;
  @State colorPickerGreen: number = 125;
  @State colorPickerBlue: number = 110;
  @State imageWatermarkUri: string = '';
  @State imageWatermarkPath: string = '';
  @State imageWatermarkAspect: number = 1;
  @State imageWatermarkOpacity: number = 0.55;
  @State imageWatermarkScale: number = 0.24;
  @State imageWatermarkAngle: number = 0;
  @State imageWatermarkTiled: boolean = false;
  @State imageWatermarkPosition: number = 8;
  @State imageWatermarkMargin: number = 0.035;
  private scanResults: PrivacyScanResult[] = [];
  private lastHandledArrival: number = -1;
  private pathStack: NavPathStack = new NavPathStack();
  private tabController: HdsTabsController = new HdsTabsController();
  private operationVersion: number = 0;
  private lastScanKey: string = '';
  private lastScanStart: number = 0;
  // True while a scan is executing; share arrivals can fire twice (Watch
  // callback + onPageShow) inside one tick and a key-only guard proved
  // insufficient.
  private scanInFlight: boolean = false;
  private service: SafeShareService | undefined = undefined;
  private defaultsReady: Promise<void> = Promise.resolve();
  private policySaveQueue: Promise<void> = Promise.resolve();
  // @State Map so every set()/clear() re-renders the FindingOverlay images
  // that read from it; a plain Map never triggers the builder again.
  @State redactedPreviewUris: Map<string, string> = new Map();
  private redactedPreviewJobs: Map<string, Promise<void>> = new Map();
  // Bumped whenever the preview context changes (new scan, preview swipe);
  // in-flight preview jobs compare against it and discard their output
  // instead of writing stale state or leaking files.
  private previewGeneration: number = 0;
  // Tracked copy of the current preview's file kind: ArkUI only re-evaluates
  // if-branches on tracked state, and batch previews can mix image and
  // document kinds.
  @State trackedFileKind: FileKind = FileKind.IMAGE;
  private selectedUtds: string[] = [];
  // Stable per-record routing result. Never fall back to the first record's
  // UTD after a later record fails to scan.
  private resolvedFileKinds: FileKind[] = [];
  // Measured on-screen size of the preview Image; drives all overlay geometry.
  @State previewSurfaceWidthState: number = 0;
  @State previewSurfaceHeightState: number = 0;
  // Tracked mirror of the current photo's pixel size (scanResults is a plain
  // array, so attribute closures reading it never re-evaluate on scan).
  @State previewPixelWidthState: number = 0;
  @State previewPixelHeightState: number = 0;
  @State mediaPreviewPixelMap: image.PixelMap | undefined = undefined;
  // Official 一多 breakpoint (xs/sm/md/lg); drives every responsive decision.
  @State breakpoint: DeviceBreakpoint = 'xs';
  // Expanded foldable inner displays can remain just below the 840vp md
  // breakpoint. Treat their landscape canvas as a tablet workspace.
  @State expandedFoldInnerDisplay: boolean = false;
  // First-launch tutorial; re-openable from the settings menu.
  @State showTutorial: boolean = false;
  // PDF watermark — session-scoped and fully independent from the photo
  // watermark settings (审核要求：仅 PDF 可用，不与照片水印混用).
  @State pdfWatermarkOn: boolean = false;
  @State pdfWatermarkText: string = '';
  @State pdfWatermarkOpacity: number = 0.22;
  @State pdfWatermarkAngle: number = -24;
  @State pdfWatermarkScale: number = 1;
  @State pdfWatermarkDarkText: boolean = false;
  @State pdfPreviewPixelMap: image.PixelMap | undefined = undefined;
  private pdfPreviewUri: string = '';
  @State tutorialCardVisible: boolean = false;
  @State tutorialSessionId: number = 0;
  private batchLiveView: BatchLiveViewService = new BatchLiveViewService();
  private tutorialTransitionGeneration: number = 0;
  private darkModeListener: mediaquery.MediaQueryListener | undefined = undefined;
  private breakpointWatcher: BreakpointWatcher | undefined = undefined;
  private foldDisplayModeListener: ((mode: display.FoldDisplayMode) => void) | undefined = undefined;

  aboutToAppear(): void {
    this.defaultsReady = this.loadMetadataDefaults();
    this.loadOnboardingFlag();
    this.watchStatusBarContrast();
    this.breakpointWatcher =
      new BreakpointWatcher(this.getUIContext());
    this.breakpointWatcher.onChange((breakpoint: DeviceBreakpoint) => {
      this.breakpoint = breakpoint;
    });
    this.watchFoldDisplayMode();
    if (this.shareReceivePending) {
      this.ensureScanPage();
      this.status = PageStatus.SCANNING;
      this.message = '正在读取分享内容…';
    }
    if (this.sharedUrisPayload.length > 0) {
      this.lastHandledArrival = this.shareArrival;
      this.applySharedFeatureMode();
      this.startScan(this.parseSharedUris(), this.parseSharedUtds());
    }
  }

  aboutToDisappear(): void {
    if (this.darkModeListener !== undefined) {
      try {
        this.darkModeListener.off('change');
      } catch (_) {
      }
      this.darkModeListener = undefined;
    }
    if (this.breakpointWatcher !== undefined) {
      this.breakpointWatcher.off();
      this.breakpointWatcher = undefined;
    }
    if (this.foldDisplayModeListener !== undefined) {
      try {
        display.off('foldDisplayModeChange', this.foldDisplayModeListener);
      } catch (_) {
      }
      this.foldDisplayModeListener = undefined;
    }
  }

  private watchFoldDisplayMode(): void {
    try {
      if (!display.isFoldable()) {
        this.expandedFoldInnerDisplay = false;
        return;
      }
      const update = (mode: display.FoldDisplayMode): void => {
        this.expandedFoldInnerDisplay = mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL;
      };
      this.foldDisplayModeListener = update;
      update(display.getFoldDisplayMode());
      display.on('foldDisplayModeChange', update);
    } catch (_) {
      // Width breakpoints remain the safe fallback on devices without the
      // fold-display service.
      this.expandedFoldInnerDisplay = false;
      this.foldDisplayModeListener = undefined;
    }
  }

  /**
   * Status-bar adaptation: the window is laid out fully behind a transparent
   * status bar, so the bar area shows the page background itself (one
   * cohesive surface, never a split strip). This keeps the bar content color
   * readable against that background and re-applies it when the system
   * switches between light and dark appearance.
   */
  private watchStatusBarContrast(): void {
    try {
      this.darkModeListener = this.getUIContext().getMediaQuery().matchMediaSync('(dark-mode: true)');
      this.darkModeListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.applyStatusBarContentColor(result.matches as boolean);
      });
      this.applyStatusBarContentColor(this.darkModeListener.matches as boolean);
    } catch (_) {
      // Without a listener the system default content color remains visible.
    }
  }

  private applyStatusBarContentColor(isDark: boolean): void {
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      return;
    }
    window.getLastWindow(context).then((mainWindow: window.Window) => {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: isDark ? '#FFFFFF' : '#1F2329',
        navigationBarColor: '#00000000'
      }).catch(() => {
      });
    }).catch(() => {
    });
  }

  /** The single share entry always opens the type-routed privacy scan. */
  private applySharedFeatureMode(): void {
    if (this.shareFeatureMode.length > 0) {
      this.featureMode = FeatureMode.PRIVACY;
      this.purposeWatermark = '';
      this.watermarkApplied = false;
    }
    AppStorage.set('shareFeatureMode', '');
  }

  private async loadMetadataDefaults(): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const policy: MetadataPolicy = await new MetadataPolicyStore(context).load();
    this.metadataMode = policy.mode;
    this.preserveCaptureTime = policy.preserveCaptureTime;
    this.preserveCameraInfo = policy.preserveCameraInfo;
    this.preservePhotographyInfo = policy.preservePhotographyInfo;
    this.deleteDetectedMetadataByDefault = policy.deleteDetectedMetadataByDefault;
    this.redactFacesByDefault = policy.redactFacesByDefault;
    this.redactQrByDefault = policy.redactQrByDefault;
    this.defaultPreservedSubtypes = policy.defaultPreservedSubtypes;
    this.docIdentityDefault = policy.docIdentityDefault;
    this.docOrgDefault = policy.docOrgDefault;
    this.docContentTimeDefault = policy.docContentTimeDefault;
    this.replacementCaptureTime = policy.captureTime;
    this.replacementCameraMake = policy.cameraMake;
    this.replacementCameraModel = policy.cameraModel;
    this.replacementAuthor = policy.author;
    this.replacementCopyright = policy.copyright;
    this.replacementDescription = policy.description;
    this.watermarkSlots = policy.watermarkSlots;
    this.watermarkColor = policy.watermarkColor;
    this.watermarkDarkText = policy.watermarkColor === '#000000';
    if (policy.watermarkColor !== '#FFFFFF' && policy.watermarkColor !== '#000000') {
      this.customWatermarkColor = policy.watermarkColor;
    }
  }

  private currentMetadataPolicy(): MetadataPolicy {
    const policy: MetadataPolicy = new MetadataPolicy();
    policy.mode = this.metadataMode;
    policy.preserveCaptureTime = this.preserveCaptureTime;
    policy.preserveCameraInfo = this.preserveCameraInfo;
    policy.preservePhotographyInfo = this.preservePhotographyInfo;
    policy.deleteDetectedMetadataByDefault = this.deleteDetectedMetadataByDefault;
    policy.redactFacesByDefault = this.redactFacesByDefault;
    policy.redactQrByDefault = this.redactQrByDefault;
    policy.defaultPreservedSubtypes = this.defaultPreservedSubtypes;
    policy.docIdentityDefault = this.docIdentityDefault;
    policy.docOrgDefault = this.docOrgDefault;
    policy.docContentTimeDefault = this.docContentTimeDefault;
    policy.captureTime = this.replacementCaptureTime;
    policy.cameraMake = this.replacementCameraMake;
    policy.cameraModel = this.replacementCameraModel;
    policy.author = this.replacementAuthor;
    policy.copyright = this.replacementCopyright;
    policy.description = this.replacementDescription;
    policy.gpsLatitude = this.replacementGpsLatitude;
    policy.gpsLongitude = this.replacementGpsLongitude;
    policy.purposeWatermark = this.purposeWatermark;
    policy.watermarkOpacity = this.watermarkOpacity;
    policy.watermarkAngle = this.watermarkAngle;
    policy.watermarkScale = this.watermarkScale;
    policy.watermarkSpacing = this.watermarkSpacing;
    policy.watermarkDarkText = this.watermarkDarkText;
    policy.watermarkColor = this.watermarkColor;
    policy.imageWatermarkUri = this.imageWatermarkUri;
    policy.imageWatermarkOpacity = this.imageWatermarkOpacity;
    policy.imageWatermarkScale = this.imageWatermarkScale;
    policy.imageWatermarkAngle = this.imageWatermarkAngle;
    policy.imageWatermarkTiled = this.imageWatermarkTiled;
    policy.imageWatermarkPosition = this.imageWatermarkPosition;
    policy.imageWatermarkMargin = this.imageWatermarkMargin;
    policy.watermarkSlots = this.watermarkSlots;
    return policy;
  }

  /** Builds one independent policy from the findings of exactly one file. */
  private metadataPolicyForFile(sourceIndex: number): MetadataPolicy {
    const policy: MetadataPolicy = this.currentMetadataPolicy();
    policy.mode = MetadataMode.CUSTOM;
    policy.preserveCaptureTime = false;
    policy.preserveCameraInfo = false;
    policy.preservePhotographyInfo = false;
    policy.captureTime = '';
    policy.cameraMake = '';
    policy.cameraModel = '';
    policy.author = '';
    policy.copyright = '';
    policy.description = '';
    policy.gpsLatitude = '';
    policy.gpsLongitude = '';
    policy.preserveSubtypes = [];
    policy.replacements = [];
    for (let index: number = 0; index < this.findings.length; index++) {
      const finding: PrivacyFinding = this.findings[index];
      if (finding.sourceIndex !== sourceIndex || finding.category !== FindingCategory.METADATA) continue;
      if (finding.replacementValue.length > 0) {
        policy.replacements.push(new MetadataReplacement(finding.subtype, finding.replacementValue));
      } else if (!finding.selectedForRemoval) {
        policy.preserveSubtypes.push(finding.subtype);
      }
    }
    return policy;
  }

  private saveMetadataDefaults(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const policy: MetadataPolicy = this.currentMetadataPolicy();
    this.policySaveQueue = this.policySaveQueue.then(async () => {
      await new MetadataPolicyStore(context).save(policy);
    });
  }

  private docFindingDefaultDeleted(subtype: string): boolean {
    if (DOC_IDENTITY_SUBTYPES.indexOf(subtype) >= 0) return this.docIdentityDefault;
    if (DOC_ORG_SUBTYPES.indexOf(subtype) >= 0) return this.docOrgDefault;
    if (DOC_CONTENT_TIME_SUBTYPES.indexOf(subtype) >= 0) return this.docContentTimeDefault;
    return true;
  }

  private isDocumentMetadataSubtype(subtype: string): boolean {
    return subtype.startsWith('DOCX_') || subtype.startsWith('PDF_');
  }

  private defaultKeepsSubtype(subtype: string): boolean {
    return this.defaultPreservedSubtypes.indexOf(subtype) >= 0;
  }

  private setDefaultSubtypePreserved(subtype: string, preserved: boolean): void {
    const next: string[] = this.defaultPreservedSubtypes.filter((value: string) => value !== subtype);
    if (preserved) next.push(subtype);
    this.defaultPreservedSubtypes = next;
    this.deleteDetectedMetadataByDefault = next.length === 0;
    this.saveMetadataDefaults();
  }

  private metadataModeIndex(): number {
    if (this.metadataMode === MetadataMode.DEEP_CLEAN) return 1;
    if (this.metadataMode === MetadataMode.CUSTOM) return 2;
    return 0;
  }

  private setMetadataMode(index: number): void {
    const modes: MetadataMode[] = [MetadataMode.RECOMMENDED, MetadataMode.DEEP_CLEAN, MetadataMode.CUSTOM];
    if (index >= 0 && index < modes.length) {
      this.metadataMode = modes[index];
      this.saveMetadataDefaults();
    }
  }

  private setSessionMetadataMode(index: number): void {
    const modes: MetadataMode[] = [MetadataMode.RECOMMENDED, MetadataMode.DEEP_CLEAN, MetadataMode.CUSTOM];
    if (index >= 0 && index < modes.length) {
      this.metadataMode = modes[index];
    }
  }

  onPageShow(): void {
    if (this.sharedUrisPayload.length > 0 && this.shareArrival !== this.lastHandledArrival) {
      this.lastHandledArrival = this.shareArrival;
      this.applySharedFeatureMode();
      this.startScan(this.parseSharedUris(), this.parseSharedUtds());
    }
  }


  private onShareArrivalChanged(): void {
    if (this.shareArrival === this.lastHandledArrival) {
      return;
    }
    this.lastHandledArrival = this.shareArrival;
    if (this.sharedUrisPayload.length > 0) {
      this.applySharedFeatureMode();
      this.startScan(this.parseSharedUris(), this.parseSharedUtds());
    } else if (this.shareReceiveError.length > 0) {
      this.message = this.shareReceiveError;
      this.status = PageStatus.ERROR;
      this.ensureScanPage();
    }
  }

  private onSharePendingChanged(): void {
    if (this.shareReceivePending && this.sharedUrisPayload.length === 0) {
      // Only the claiming instance shows the scanning placeholder; the other
      // ability's page keeps its previous state.
      this.ensureScanPage();
      this.status = PageStatus.SCANNING;
      this.message = '正在读取分享内容…';
    }
  }

  private flowLog(stage: string, detail: string = ''): void {
    hilog.error(0x8801, 'SafeShareFlow', `stage=${stage}${detail.length > 0 ? ` ${detail}` : ''}`);
  }

  private async syncPdfPreview(): Promise<void> {
    const uri: string = this.currentPreviewUri();
    const isPdf: boolean = this.statusNotReady() && this.trackedFileKind === FileKind.PDF;
    if (!isPdf || uri.length === 0 || uri === this.pdfPreviewUri) {
      if (!isPdf && this.pdfPreviewPixelMap !== undefined) {
        this.pdfPreviewPixelMap.release().catch(() => {
        });
        this.pdfPreviewPixelMap = undefined;
        this.pdfPreviewUri = '';
      }
      return;
    }
    this.pdfPreviewUri = uri;
    try {
      const map: image.PixelMap | undefined = await this.getService().renderPdfFirstPage(uri);
      if (this.pdfPreviewUri !== uri) {
        if (map !== undefined) map.release().catch(() => {
        });
        return;
      }
      if (map !== undefined) {
        this.pdfPreviewPixelMap = map;
      }
      this.flowLog('pdf_preview', `rendered=${map !== undefined ? 1 : 0}`);
    } catch (_) {
      this.flowLog('pdf_preview', 'rendered=0 err');
    }
  }

  private releasePdfPreview(): void {
    if (this.pdfPreviewPixelMap !== undefined) {
      const map: image.PixelMap = this.pdfPreviewPixelMap;
      this.pdfPreviewPixelMap = undefined;
      map.release().catch(() => {
      });
    }
    this.pdfPreviewUri = '';
  }

  private pdfWatermarkRequest(): PdfWatermarkOptions | undefined {
    if (!this.pdfWatermarkOn || this.pdfWatermarkText.trim().length === 0) {
      return undefined;
    }
    const request: PdfWatermarkOptions = new PdfWatermarkOptions(this.pdfWatermarkText.trim());
    request.opacity = this.pdfWatermarkOpacity;
    request.rotation = this.pdfWatermarkAngle;
    request.darkText = this.pdfWatermarkDarkText;
    request.textSize = Math.round(48 * this.pdfWatermarkScale);
    return request;
  }

  private getService(): SafeShareService {
    if (this.service !== undefined) {
      return this.service;
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.service = new SafeShareService(context);
    return this.service;
  }

  private async loadOnboardingFlag(): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store: preferences.Preferences =
        await preferences.getPreferences(context, 'privacy_defaults');
      const done: boolean = Boolean(await store.get('onboarding_done', false));
      if (!done) {
        this.openTutorial();
      }
    } catch (_) {
      // A failed read must not block the first-run experience.
    }
  }








  private async markOnboardingDone(): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store: preferences.Preferences =
        await preferences.getPreferences(context, 'privacy_defaults');
      await store.put('onboarding_done', true);
      await store.flush();
    } catch (_) {
    }
  }

  private openTutorial(): void {
    const generation: number = ++this.tutorialTransitionGeneration;
    this.tutorialSessionId++;
    this.tutorialCardVisible = false;
    this.showTutorial = true;
    setTimeout(() => {
      if (generation !== this.tutorialTransitionGeneration) return;
      this.getUIContext().animateTo({ duration: 420, curve: Curve.Friction }, () => {
        this.tutorialCardVisible = true;
      });
    }, 16);
  }

  private closeTutorial(): void {
    const generation: number = ++this.tutorialTransitionGeneration;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseIn }, () => {
      this.tutorialCardVisible = false;
    });
    setTimeout(() => {
      if (generation === this.tutorialTransitionGeneration) this.showTutorial = false;
    }, 260);
    this.markOnboardingDone();
  }

  private openSettings(): void {
    this.settingsPage = 'menu';
    this.showSettingsSheet = true;
  }

  private animateSettingsTo(page: string): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.settingsPage = page;
    });
  }

  /**
   * Retry entry after a scan failure: reopens the picker matching the
   * pipeline that produced the failure instead of always reopening photos.
   */
  private repickCurrent(): void {
    const sourceUri: string = this.selectedUris.length > 0 ? this.selectedUris[0] : '';
    const sourceKind: FileKind = sourceUri.length > 0 ? FileTypeRouter.detect(sourceUri) : FileKind.UNKNOWN;
    if (sourceKind === FileKind.PDF || sourceKind === FileKind.WORD ||
      sourceKind === FileKind.EXCEL || sourceKind === FileKind.POWERPOINT) {
      this.chooseDocument();
    } else if (sourceKind === FileKind.AUDIO_VIDEO) {
      this.chooseMedia();
    } else {
      this.chooseImage();
    }
  }

  private switchHomeTab(index: number): void {
    // Tab visibility is owned by HdsTabs natively. This only records the
    // active tab so share arrivals and the title bar stay in sync.
    const tabs: HomeTab[] = [HomeTab.PHOTO, HomeTab.FILES];
    if (index >= 0 && index < tabs.length) {
      this.homeTab = tabs[index];
    }
  }

  private homeTabIndex(): number {
    return this.homeTab === HomeTab.FILES ? 1 : 0;
  }

  private homeTitle(): string {
    if (this.homeTab === HomeTab.FILES) {
      return '文件检查';
    }
    return this.homeTabPhotoMode === FeatureMode.WATERMARK ? '水印' : '净享SafeShare';
  }

  private tabSymbol(normalName: string, selectedName: string): TabBarSymbol {
    // TabBarSymbol is an ambient component class that may be absent at
    // runtime on some builds; fall back to object-literal form which the
    // framework accepts structurally.
    try {
      const symbol: TabBarSymbol = new TabBarSymbol();
      symbol.normal = new SymbolGlyphModifier($r(normalName));
      symbol.selected = new SymbolGlyphModifier($r(selectedName));
      return symbol;
    } catch (_) {
      const fallback: TabBarSymbol = {
        normal: new SymbolGlyphModifier($r(normalName)),
        selected: new SymbolGlyphModifier($r(selectedName))
      } as TabBarSymbol;
      return fallback;
    }
  }

  private async chooseImage(): Promise<void> {
    // Photo picks always run the mode currently selected on the photo tab.
    this.featureMode = this.homeTabPhotoMode;
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      const imageFilter: photoAccessHelper.MimeTypeFilter = new photoAccessHelper.MimeTypeFilter();
      imageFilter.mimeTypeArray = ['image/*'];
      options.mimeTypeFilter = imageFilter;
      options.maxSelectNumber = 50;
      const viewPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await viewPicker.select(options);
      if (result.photoUris.length > 0) {
        const imageUris: string[] = this.imageUrisOnly(result.photoUris);
        if (imageUris.length === 0) {
          this.getUIContext().getPromptAction().showToast({ message: '请选择图片，视频不会进入照片处理' });
          return;
        }
        await this.startScan(imageUris);
      }
    } catch (_) {
      this.message = '未能读取所选图片，请重新选择。';
      this.status = PageStatus.ERROR;
    }
  }

  /**
   * Dedicated document picker. Each family gets its own filtered picker so a
   * PDF entry only offers PDFs — mixing types in one picker felt chaotic.
   * The center "选择文档" button passes undefined for the full doc set.
   */
  private async chooseDocument(kind?: FileKind): Promise<void> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      if (kind === FileKind.PDF) {
        options.fileSuffixFilters = ['.pdf'];
      } else if (kind === FileKind.WORD) {
        options.fileSuffixFilters = ['.docx'];
      } else if (kind === FileKind.EXCEL) {
        options.fileSuffixFilters = ['.xlsx', '.xlsm'];
      } else if (kind === FileKind.POWERPOINT) {
        options.fileSuffixFilters = ['.pptx'];
      } else {
        options.fileSuffixFilters = ['.pdf', '.docx', '.xlsx', '.xlsm', '.pptx'];
      }
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await viewPicker.select(options);
      if (uris.length > 0) {
        await this.startScan(uris);
      }
    } catch (_) {
      this.message = '未能读取所选文档，请重新选择。';
      this.status = PageStatus.ERROR;
    }
  }

  /** Dedicated media picker. Video can be cleaned; audio remains scan-only. */
  private async chooseMedia(): Promise<void> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 10;
      options.fileSuffixFilters = [
        '视频|.mp4,.mov,.m4v,.3gp,.mkv,.webm',
        '音频|.mp3,.m4a,.wav,.aac,.flac,.ogg,.amr'
      ];
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await viewPicker.select(options);
      if (uris.length > 0) {
        await this.startScan(uris);
      }
    } catch (_) {
      this.message = '未能读取所选音视频，请重新选择。';
      this.status = PageStatus.ERROR;
    }
  }

  private async chooseImageWatermark(): Promise<void> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      const imageFilter: photoAccessHelper.MimeTypeFilter = new photoAccessHelper.MimeTypeFilter();
      imageFilter.mimeTypeArray = ['image/*'];
      options.mimeTypeFilter = imageFilter;
      options.maxSelectNumber = 1;
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length === 0) return;
      const imageUris: string[] = this.imageUrisOnly(result.photoUris);
      if (imageUris.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '水印素材必须是图片' });
        return;
      }
      const asset: WatermarkAsset = await this.getService().importWatermarkAsset(imageUris[0]);
      const previousPath: string = this.imageWatermarkPath;
      this.imageWatermarkPath = asset.path;
      this.imageWatermarkUri = asset.uri;
      this.imageWatermarkAspect = Math.max(0.05, asset.width / Math.max(1, asset.height));
      if (previousPath.length > 0) this.getService().removeTemporaryPath(previousPath);
    } catch (_) {
      this.message = '未能读取水印图片，请换一张图片重试。';
    }
  }

  private imageUrisOnly(uris: string[]): string[] {
    const images: string[] = [];
    for (let index: number = 0; index < uris.length; index++) {
      if (this.getService().kindOf(uris[index]) === FileKind.IMAGE) images.push(uris[index]);
    }
    return images;
  }

  private removeImageWatermark(): void {
    const path: string = this.imageWatermarkPath;
    this.imageWatermarkPath = '';
    this.imageWatermarkUri = '';
    this.imageWatermarkAspect = 1;
    if (path.length > 0) this.getService().removeTemporaryPath(path);
  }

  private handleImageDrop(event: DragEvent): void {
    const uris: string[] = [];
    try {
      const records: unifiedDataChannel.UnifiedRecord[] = event.getData().getRecords();
      for (let index: number = 0; index < records.length && uris.length < 50; index++) {
        let uri: string = '';
        if (records[index] instanceof unifiedDataChannel.Image) {
          const imageRecord: unifiedDataChannel.Image = records[index] as unifiedDataChannel.Image;
          uri = imageRecord.imageUri.length > 0 ? imageRecord.imageUri : imageRecord.uri;
        } else if (records[index] instanceof unifiedDataChannel.File) {
          uri = (records[index] as unifiedDataChannel.File).uri;
        }
        if (uri.length > 0 && uris.indexOf(uri) < 0) {
          uris.push(uri);
        }
      }
      if (uris.length > 0) {
        event.dragBehavior = DragBehavior.COPY;
        event.setResult(DragResult.DRAG_SUCCESSFUL);
        this.startScan(uris);
      } else {
        event.setResult(DragResult.DRAG_FAILED);
        this.message = '请拖入可读取的图片或文档文件。';
      }
    } catch (_) {
      event.setResult(DragResult.DRAG_FAILED);
      this.message = '未能读取拖入的内容，请重试。';
    }
    this.isDropTargetActive = false;
  }

  private parseSharedUris(): string[] {
    try {
      const parsed: string[] = JSON.parse(this.sharedUrisPayload) as string[];
      return parsed.filter((uri: string) => uri.length > 0).slice(0, 50);
    } catch (_) {
      return [];
    }
  }

  private parseSharedUtds(): string[] {
    try {
      const parsed: string[] = JSON.parse(this.sharedUtdsPayload) as string[];
      return parsed.slice(0, 50);
    } catch (_) {
      return [];
    }
  }

  private currentFileKind(): FileKind {
    if (this.previewIndex < this.scanResults.length) {
      return this.scanResults[this.previewIndex].fileKind as FileKind;
    }
    if (this.previewIndex < this.resolvedFileKinds.length) {
      return this.resolvedFileKinds[this.previewIndex];
    }
    if (this.selectedUris.length > 0) {
      const index: number = Math.min(this.previewIndex, this.selectedUris.length - 1);
      return FileTypeRouter.detect(this.selectedUris[index], this.selectedUtds[index] ?? '');
    }
    return FileKind.IMAGE;
  }

  /**
   * Mirrors the current preview's file kind into tracked state. Build-time
   * if-branches only re-evaluate on tracked state, so the image vs document
   * preview branch reads this copy, never the plain method.
   */
  private syncTrackedFileKind(): void {
    if (this.previewIndex < this.scanResults.length) {
      this.trackedFileKind = this.scanResults[this.previewIndex].fileKind as FileKind;
    } else if (this.previewIndex < this.resolvedFileKinds.length) {
      this.trackedFileKind = this.resolvedFileKinds[this.previewIndex];
    } else if (this.previewIndex < this.selectedUris.length) {
      this.trackedFileKind = FileTypeRouter.detect(this.selectedUris[this.previewIndex],
        this.selectedUtds[this.previewIndex] ?? '');
    } else {
      this.trackedFileKind = this.currentFileKind();
    }
  }

  private isDocumentSession(): boolean {
    const kind: FileKind = this.currentFileKind();
    return kind === FileKind.PDF || kind === FileKind.WORD ||
      kind === FileKind.EXCEL || kind === FileKind.POWERPOINT;
  }

  private isAvSession(): boolean {
    return this.currentFileKind() === FileKind.AUDIO_VIDEO;
  }

  private isCurrentFileReadOnly(): boolean {
    if (this.previewIndex < this.scanResults.length) {
      return this.scanResults[this.previewIndex].readOnlyTool;
    }
    return this.isAvSession() && FileTypeRouter.isAudioUri(this.currentPreviewUri());
  }

  private currentMediaMimeType(): string {
    if (this.status === PageStatus.READY && this.showSafePreview) {
      const safeFile: SanitizedFile | undefined = this.sanitizedFileForSource(this.previewIndex);
      if (safeFile !== undefined && safeFile.mimeType.length > 0) return safeFile.mimeType;
    }
    if (this.previewIndex < this.scanResults.length &&
      this.scanResults[this.previewIndex].mimeType.length > 0) {
      return this.scanResults[this.previewIndex].mimeType;
    }
    return FileTypeRouter.mimeTypeForUri(this.currentPreviewUri(), FileKind.AUDIO_VIDEO);
  }

  private isVideoSession(): boolean {
    return this.isAvSession() && (this.currentMediaMimeType().startsWith('video/') ||
      FileTypeRouter.isVideoUri(this.currentPreviewUri()));
  }

  private isImageSession(): boolean {
    return this.currentFileKind() === FileKind.IMAGE;
  }

  private sanitizableFileCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.selectedUris.length; index++) {
      const kind: FileKind = index < this.scanResults.length ?
        this.scanResults[index].fileKind as FileKind :
        (index < this.resolvedFileKinds.length ? this.resolvedFileKinds[index] :
          FileTypeRouter.detect(this.selectedUris[index], this.selectedUtds[index] ?? ''));
      const readOnly: boolean = index < this.scanResults.length ? this.scanResults[index].readOnlyTool :
        (kind === FileKind.AUDIO_VIDEO && FileTypeRouter.isAudioUri(this.selectedUris[index]));
      if (kind !== FileKind.UNKNOWN && !readOnly) count++;
    }
    return count;
  }

  private hasSanitizableFiles(): boolean {
    return this.sanitizableFileCount() > 0;
  }

  private statusReady(): boolean {
    return this.status === PageStatus.READY;
  }

  private statusNotReady(): boolean {
    return this.status !== PageStatus.READY;
  }
  private kindLabel(): string {
    return this.getService().labelOf(this.currentFileKind());
  }

  private scanNoun(): string {
    if (this.isAvSession()) return '音视频';
    if (this.isDocumentSession()) return this.kindLabel();
    return this.featureMode === FeatureMode.WATERMARK ? '照片' : '图片';
  }

  private async startScan(uris: string[], utds: string[] = []): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    // Share arrivals can fire from both the @Watch callback and onPageShow.
    // Deduplicate by content + time window — NOT by UI status: the cold-start
    // share flow presets status to SCANNING in aboutToAppear before calling
    // here, and a status-based guard aborted exactly that flow, leaving the
    // page on the loading card forever.
    const scanKey: string = uris.join('|');
    const now: number = Date.now();
    if (this.scanInFlight || (scanKey === this.lastScanKey && now - this.lastScanStart < 800)) {
      return;
    }
    this.lastScanKey = scanKey;
    this.lastScanStart = now;
    this.scanInFlight = true;
    this.flowLog('start_scan', `n=${uris.length}`);
    try {
      await this.defaultsReady;
      await this.runScan(uris, utds);
    } finally {
      this.scanInFlight = false;
    }
  }

  private async runScan(uris: string[], utds: string[] = []): Promise<void> {
    const operation: number = ++this.operationVersion;
    this.ensureScanPage();
    this.discardOutputs(uris);
    this.clearRedactedPreviews();
    this.selectedUris = uris.slice(0, 50);
    this.selectedUtds = utds.slice(0, this.selectedUris.length);
    while (this.selectedUtds.length < this.selectedUris.length) this.selectedUtds.push('');
    this.resolvedFileKinds = [];
    for (let kindIndex: number = 0; kindIndex < this.selectedUris.length; kindIndex++) {
      this.resolvedFileKinds.push(await this.getService().resolveKind(this.selectedUris[kindIndex],
        this.selectedUtds[kindIndex]));
    }
    this.selectedUri = this.selectedUris[0];
    this.findings = [];
    this.refreshDerivedFindings();
    this.releaseMediaPreviews();
    this.releasePdfPreview();
    this.scanResults = [];
    this.sanitizedFiles = [];
    this.capabilityWarnings = [];
    this.showSafePreview = false;
    this.appliedVisualCount = 0;
    this.removedEntryCount = 0;
    this.optionsOut = false;
    this.optionsRemoved = false;
    this.previewIndex = 0;
    this.syncTrackedFileKind();
    this.syncPreviewPixelSize();
    this.redactionStyle = RedactionStyle.AUTO;
    this.showMetadataDetails = true;
    // Media never enters the photo-watermark/redaction workflow.
    if (this.isAvSession()) {
      // Video uses metadata-only remuxing; audio stays scan-only.
      this.featureMode = FeatureMode.PRIVACY;
      this.watermarkApplied = false;
      this.purposeWatermark = '';
    } else if (this.featureMode !== FeatureMode.WATERMARK) {
      this.watermarkApplied = false;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.status = PageStatus.SCANNING;
    });
    this.message = this.featureMode === FeatureMode.WATERMARK ?
      (this.selectedUris.length === 1 ? '正在读取照片…' : `正在读取 ${this.selectedUris.length} 张照片…`) :
      (this.selectedUris.length === 1 ? `正在本机检查${this.scanNoun()}隐私信息…` :
        `正在本机检查 ${this.selectedUris.length} 个文件…`);
    try {
      const allFindings: PrivacyFinding[] = [];
      let failedCount: number = 0;
      for (let index: number = 0; index < this.selectedUris.length; index++) {
        this.message = this.featureMode === FeatureMode.WATERMARK ?
          `正在读取第 ${index + 1}/${this.selectedUris.length} 张…` :
          (this.selectedUris.length === 1 ? `正在本机检查${this.scanNoun()}隐私信息…` :
            `正在检查第 ${index + 1}/${this.selectedUris.length} 个文件…`);
        let result: PrivacyScanResult;
        try {
          this.flowLog('scan_file_begin', `i=${index} kind=${this.resolvedFileKinds[index]}`);
          result = await this.getService().scanPrivacy(this.selectedUris[index],
            this.selectedUtds[index], this.resolvedFileKinds[index]);
          this.flowLog('scan_file_done', `i=${index}`);
          if (result.scanFailed) failedCount++;
        } catch (scanError) {
          this.flowLog('scan_file_failed', `i=${index} err=${((scanError as Error).message ?? '').slice(0, 70)}`);
          result = new PrivacyScanResult(this.selectedUris[index], []);
          result.fileKind = this.resolvedFileKinds[index];
          result.scanFailed = true;
          result.capabilityWarnings = [(scanError as Error).message.indexOf('LEGACY_OFFICE_FORMAT') >= 0 ?
            `第 ${index + 1} 个文件是旧版 Office 格式（.doc/.xls/.ppt），暂不支持清理，请另存为新格式后重试` :
            `第 ${index + 1} 个文件未能完成检查，其他文件已继续处理`];
          failedCount++;
        }
        if (operation !== this.operationVersion) {
          return;
        }
        this.scanResults.push(result);
        this.syncPreviewPixelSize();
        for (let findingIndex: number = 0; findingIndex < result.findings.length; findingIndex++) {
          const finding: PrivacyFinding = result.findings[findingIndex];
          finding.sourceIndex = index;
          finding.id = `${index}-${finding.id}`;
          if (result.readOnlyTool) {
            finding.selectedForRemoval = false;
          } else if (finding.category === FindingCategory.METADATA) {
            finding.selectedForRemoval = this.isDocumentMetadataSubtype(finding.subtype) ?
              this.docFindingDefaultDeleted(finding.subtype) :
              !this.defaultKeepsSubtype(finding.subtype);
          } else if (finding.category === FindingCategory.FACE) {
            finding.selectedForRemoval = this.redactFacesByDefault;
          } else if (finding.category === FindingCategory.QR) {
            finding.selectedForRemoval = this.redactQrByDefault;
          }
          if (this.selectedUris.length > 1) {
            finding.title = `第 ${index + 1} 个 · ${finding.title}`;
          }
          allFindings.push(finding);
        }
      }
      this.findings = allFindings;
      this.refreshDerivedFindings();
      hilog.info(0x8801, 'SafeShareUI', `fm=${this.featureMode} n=${allFindings.length} metaN=${allFindings.filter((f: PrivacyFinding) => f.category === FindingCategory.METADATA).length}`);
      const warnings: string[] = [];
      for (let resultIndex: number = 0; resultIndex < this.scanResults.length; resultIndex++) {
        const resultWarnings: string[] = this.scanResults[resultIndex].capabilityWarnings;
        for (let warningIndex: number = 0; warningIndex < resultWarnings.length; warningIndex++) {
          if (warnings.indexOf(resultWarnings[warningIndex]) < 0) {
            warnings.push(resultWarnings[warningIndex]);
          }
        }
      }
      this.capabilityWarnings = warnings;
      this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
        this.status = PageStatus.RESULT;
      });
      if (this.trackedFileKind === FileKind.PDF) {
        this.syncPdfPreview();
      }
      this.message = failedCount > 0 ?
        `${this.selectedUris.length - failedCount}/${this.selectedUris.length} 个文件已完成检查` :
        (this.featureMode === FeatureMode.WATERMARK ? '照片已就绪，请设置水印' :
        (this.isAvSession() ? (allFindings.length === 0 ? '未发现可读取的隐私元数据' :
          `已读取 ${allFindings.length} 项音视频隐私元数据`) :
          (allFindings.length === 0 ? '已完成的检查中未发现常见隐私风险' :
            `${this.selectedUris.length} 个文件发现 ${allFindings.length} 项可清理信息`)));
    } catch (_) {
      if (operation !== this.operationVersion) {
        return;
      }
      this.message = '暂时无法检查这个文件。文件可能已损坏或格式暂不支持。';
      this.status = PageStatus.ERROR;
    }
  }

  private async createSafeCopy(): Promise<void> {
    if (this.status === PageStatus.SANITIZING) {
      // A run is already in flight; a second tap must not start a competing
      // pipeline over the same source files.
      return;
    }
    if (!this.hasSanitizableFiles()) {
      this.message = '所选文件目前只能查看元数据，无法生成清理副本。';
      return;
    }
    const operation: number = ++this.operationVersion;
    // Native two-phase exit: slide the option pane fully off screen first;
    // only in the animation's onFinish does the status flip to SANITIZING.
    // The pane is already invisible when it unmounts, so the progress card
    // that replaces it can never replay or reverse the exit motion.
    this.getUIContext().animateTo({
      duration: 300,
      curve: Curve.EaseIn,
      onFinish: () => {
        // The pipeline can finish faster than this 300ms exit (small images
        // take ~70ms) and flip the status to READY/ERROR first. Only move to
        // SANITIZING if the run is genuinely still pending, otherwise the
        // callback would overwrite the final state and the UI would spin
        // forever on the loading card.
        // Collapse the exited pane from the layout so the progress/summary
        // content backfills the vacated space instead of leaving a gap.
        this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
          this.optionsRemoved = true;
        });
        if (this.status === PageStatus.RESULT) {
          this.status = PageStatus.SANITIZING;
        }
      }
    }, () => {
      this.optionsOut = true;
    });
    this.message = this.featureMode === FeatureMode.WATERMARK ? '正在生成水印副本…' :
      '正在生成不含原始元数据的安全副本…';
    try {
      const actionsByFile: RedactionAction[][] = [];
      for (let index: number = 0; index < this.selectedUris.length; index++) {
        actionsByFile.push([]);
      }
      const policiesByFile: MetadataPolicy[] = [];
      for (let index: number = 0; index < this.selectedUris.length; index++) {
        policiesByFile.push(this.metadataPolicyForFile(index));
      }
      for (let findingIndex: number = 0; findingIndex < this.findings.length; findingIndex++) {
        const finding: PrivacyFinding = this.findings[findingIndex];
        if (finding.selectedForRemoval && finding.region !== undefined &&
          finding.sourceIndex < actionsByFile.length) {
          this.appendUniqueAction(actionsByFile[finding.sourceIndex], finding);
        }
      }
      this.batchLiveView.begin(this.sanitizableFileCount());
      const resolvedKinds: FileKind[] = this.scanResults.map((result: PrivacyScanResult) =>
        result.fileKind as FileKind);
      const readOnlyFiles: boolean[] = this.scanResults.map((result: PrivacyScanResult) =>
        result.readOnlyTool || result.scanFailed);
      this.flowLog('ui_sanitize_begin');
      const pdfWatermark: PdfWatermarkOptions | undefined =
        this.trackedFileKind === FileKind.PDF ? this.pdfWatermarkRequest() : undefined;
      this.flowLog('pdf_wm_request',
        `on=${this.pdfWatermarkOn ? 1 : 0} text=${this.pdfWatermarkText.trim().length > 0 ? 1 : 0} ` +
        `send=${pdfWatermark !== undefined ? 1 : 0}`);
      const files: SanitizedFile[] = await this.getService().sanitizeFiles(this.selectedUris, actionsByFile,
        this.currentMetadataPolicy(), policiesByFile, this.selectedUtds, resolvedKinds, readOnlyFiles,
        async (completed: number, total: number): Promise<void> => {
          await this.batchLiveView.update(completed, total);
        }, pdfWatermark);
      if (operation !== this.operationVersion) {
        await this.getService().discardSanitized(files);
        await this.batchLiveView.finish(false, this.selectedUris.length);
        return;
      }
      this.sanitizedFiles = files;
      let visualCount: number = 0;
      for (let imageIndex: number = 0; imageIndex < actionsByFile.length; imageIndex++) {
        visualCount += actionsByFile[imageIndex].length;
      }
      this.appliedVisualCount = visualCount;
      // Count only entries whose file actually produced a verified copy. A
      // file that failed or was skipped contributes nothing to the success
      // message — no success is claimed where none happened.
      let removedEntries: number = 0;
      for (let fileIndex: number = 0; fileIndex < files.length; fileIndex++) {
        for (let findingIndex: number = 0; findingIndex < this.findings.length; findingIndex++) {
          const finding: PrivacyFinding = this.findings[findingIndex];
          if (finding.sourceIndex === files[fileIndex].sourceIndex && finding.selectedForRemoval &&
            finding.category === FindingCategory.METADATA) {
            removedEntries++;
          }
        }
      }
      this.removedEntryCount = removedEntries;
      this.flowLog('ui_sanitize_done', `files=${files.length}`);
      this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
        this.status = PageStatus.READY;
        this.showSafePreview = true;
      });
      const skippedMedia: number = this.selectedUris.length - files.length;
      const removedPhrase: string = removedEntries > 0 ? `，已删除 ${removedEntries} 项隐私条目` : '';
      this.message = files.length === 1 ?
        (skippedMedia > 0 ? `安全副本已生成${removedPhrase}；只读文件未处理` :
          `安全副本已生成${removedPhrase}，隐私复检通过`) :
        (skippedMedia > 0 ? `${files.length} 个安全副本已生成${removedPhrase}；只读文件未处理` :
          `${files.length} 个安全副本均已复检${removedPhrase}`);
      await this.batchLiveView.finish(true, files.length);
    } catch (error) {
      if (operation !== this.operationVersion) {
        return;
      }
      const stage: string = (error as Error).message;
      this.flowLog('sanitize_failed', `err=${stage.slice(0, 80)}`);
      if (stage.indexOf('PDF_COPY_FAILED') >= 0) {
        const code: string = stage.replace('PDF_COPY_FAILED:', '');
        const reasons: string[] = [
          '文件无法解析，可能已损坏或已加密', '文档没有可处理的页面',
          '系统 PDF 服务创建文档失败', '系统 PDF 服务写出文件失败',
          '替换值无法写入该文件的结构'];
        const codes: string[] = ['SOURCE_PARSE', 'EMPTY_DOCUMENT', 'CREATE_DOCUMENT',
          'SAVE_DOCUMENT', 'REPLACE_LAYOUT'];
        const index: number = codes.indexOf(code);
        this.message = 'PDF 副本生成失败：' + (index >= 0 ? reasons[index] : code) +
          '。原文件未发生任何改变。';
      } else if (stage.indexOf('TRACK_SETUP_FAILED') >= 0) {
        this.message = '视频包含当前系统封装器不支持的轨道，未生成副本。';
      } else if (stage.indexOf('SAMPLE_READ_FAILED') >= 0 || stage.indexOf('SAMPLE_TOO_LARGE') >= 0) {
        this.message = '读取视频帧失败，原视频未发生任何改变。';
      } else if (stage.indexOf('SAMPLE_WRITE_FAILED') >= 0 || stage.indexOf('MUXER_') >= 0) {
        this.message = '写入视频副本失败，原视频未发生任何改变。';
      } else if (stage.indexOf('METADATA_REMAINS') >= 0 || stage.indexOf('CONTAINER_TIME_CLEAR_FAILED') >= 0) {
        this.message = '视频副本复检未通过，已自动删除失败副本。';
      } else if (stage.indexOf('PREVIEW_UNAVAILABLE') >= 0) {
        this.message = '视频副本无法正常预览，已自动删除失败副本。';
      } else {
        this.message = '安全副本生成失败，原文件未发生任何改变。';
      }
      this.removedEntryCount = 0;
      this.status = PageStatus.ERROR;
      await this.batchLiveView.finish(false, this.selectedUris.length);
    }
  }

  private async shareAgain(): Promise<void> {
    if (this.sanitizedFiles.length === 0) {
      return;
    }
    try {
      await this.getService().shareSanitized(this.sanitizedFiles);
    } catch (_) {
      // The copy stays in place so the user can retry; surfaces the failure
      // instead of leaking an unhandled rejection from the click handler.
      this.message = '未能打开系统分享面板，请重试。';
    }
  }

  /**
   * Discards previous outputs. Incoming URIs are protected: the share-entry
   * recursion (sharing a SafeShare copy back into SafeShare) scans exactly
   * those files, so discarding them before the scan destroyed the input.
   */
  private discardOutputs(protectedUris: string[] = []): void {
    if (this.sanitizedFiles.length === 0) {
      return;
    }
    const doomed: SanitizedFile[] = this.sanitizedFiles.filter((file: SanitizedFile) =>
      !this.uriMatchesFile(protectedUris, file));
    if (doomed.length > 0) {
      this.getService().discardSanitized(doomed);
    }
    this.sanitizedFiles = [];
  }

  private uriMatchesFile(uris: string[], file: SanitizedFile): boolean {
    for (let index: number = 0; index < uris.length; index++) {
      let candidate: string = uris[index];
      try { candidate = decodeURIComponent(candidate); } catch (_) {}
      const query: number = candidate.indexOf('?');
      if (query >= 0) candidate = candidate.substring(0, query);
      if (candidate === file.uri || candidate === `file://${file.path}` ||
        candidate.endsWith(`/${file.path.substring(file.path.lastIndexOf('/') + 1)}`)) {
        return true;
      }
    }
    return false;
  }

  private reset(): void {
    this.operationVersion++;
    this.batchLiveView.finish(false, this.selectedUris.length);
    this.discardOutputs();
    this.clearRedactedPreviews();
    this.sharedUrisPayload = '';
    this.sharedUtdsPayload = '';
    this.selectedUri = '';
    this.selectedUris = [];
    this.selectedUtds = [];
    this.findings = [];
    this.releaseMediaPreviews();
    this.releasePdfPreview();
    this.pdfWatermarkOn = false;
    this.scanResults = [];
    this.resolvedFileKinds = [];
    this.sanitizedFiles = [];
    this.capabilityWarnings = [];
    this.showSafePreview = false;
    this.appliedVisualCount = 0;
    this.removedEntryCount = 0;
    this.optionsOut = false;
    this.optionsRemoved = false;
    this.previewIndex = 0;
    this.syncTrackedFileKind();
    this.syncPreviewPixelSize();
    this.redactionStyle = RedactionStyle.AUTO;
    this.showMetadataDetails = true;
    this.watermarkApplied = false;
    this.purposeWatermark = '';
    this.removeImageWatermark();
    this.status = PageStatus.HOME;
    this.message = '';
    this.loadMetadataDefaults();
    if (this.service !== undefined) {
      const service: SafeShareService = this.service;
      this.service = undefined;
      service.dispose();
    }
  }

  private releaseMediaPreviews(): void {
    this.mediaPreviewPixelMap = undefined;
    for (let index: number = 0; index < this.scanResults.length; index++) {
      const preview: image.PixelMap | undefined = this.scanResults[index].previewPixelMap;
      if (preview !== undefined) {
        preview.release().catch(() => {
        });
        this.scanResults[index].previewPixelMap = undefined;
      }
    }
  }

  private ensureScanPage(): void {
    if (this.pathStack.getAllPathName().indexOf('scan') < 0) {
      try {
        this.pathStack.pushPathByName('scan', new ScanPageParam());
      } catch (_) {
      }
    }
  }

  private closeScan(): void {
    this.pathStack.pop();
    this.reset();
  }

  private displayValue(finding: PrivacyFinding): string {
    if (finding.subtype === 'GPS' || finding.subtype.startsWith('GPS_')) {
      return '已检测到坐标数据';
    }
    if (finding.rawValue.length > 36) {
      return `${finding.rawValue.slice(0, 33)}…`;
    }
    return finding.rawValue;
  }

  private toggleFinding(finding: PrivacyFinding): void {
    if (finding.region === undefined) {
      return;
    }
    finding.selectedForRemoval = !finding.selectedForRemoval;
    this.findings = this.findings.slice();
    this.refreshDerivedFindings();
  }

  private invalidateRedactedPreviews(): void {
    this.clearRedactedPreviews();
  }

  /**
   * Returns a cached file URI whose pixels are the redacted region produced by
   * the exact same routine as the final sanitized copy (RedactionPixels), so
   * the on-screen preview is pixel-identical to the delivered image.
   */
  private redactedPreviewUri(finding: PrivacyFinding): string {
    const region: SensitiveRegion | undefined = finding.region;
    if (region === undefined) {
      return '';
    }
    const key: string = `${finding.id}-${this.previewIndex}-${this.styleForFinding(finding)}`;
    const cached: string | undefined = this.redactedPreviewUris.get(key);
    if (cached !== undefined) {
      return cached;
    }
    if (!this.redactedPreviewJobs.has(key)) {
      // Resolve the source URI now: the preview the overlay belongs to is the
      // one on screen at scheduling time, not whatever is on screen when the
      // background job resumes after an await.
      const uri: string = this.currentPreviewUri();
      const generation: number = this.previewGeneration;
      const job: Promise<void> = this.buildRedactedPreview(key, finding, region, uri, generation)
        .finally(() => this.redactedPreviewJobs.delete(key));
      this.redactedPreviewJobs.set(key, job);
    }
    return '';
  }

  private async buildRedactedPreview(key: string, finding: PrivacyFinding,
    region: SensitiveRegion, uri: string, generation: number): Promise<void> {
    if (FileTypeRouter.detect(uri) !== FileKind.IMAGE) {
      return;
    }
    let sourceFile: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(sourceFile.fd);
      // Decode downscaled: the preview box is small, so a 512px-side decode
      // keeps the per-pixel effect trivial even for 50MP shots. Region
      // coordinates are full-res oriented pixels and must be scaled too.
      const fullInfo: image.ImageInfo = await source.getImageInfo();
      const previewScale: number = Math.min(1, 512 /
        Math.max(fullInfo.size.width, fullInfo.size.height));
      const decodeWidth: number = Math.max(1,
        Math.round(fullInfo.size.width * previewScale));
      const decodeHeight: number = Math.max(1,
        Math.round(fullInfo.size.height * previewScale));
      pixelMap = await source.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: decodeWidth, height: decodeHeight }
      });
      const info: image.ImageInfo = await pixelMap.getImageInfo();
      const scale: number = info.size.width / Math.max(1, fullInfo.size.width);
      const padding: number = Math.max(2, Math.round(
        RedactionPixels.paddingFor(finding.category, region.width, region.height) * scale));
      const left: number = Math.max(0, Math.floor(region.left * scale) - padding);
      const top: number = Math.max(0, Math.floor(region.top * scale) - padding);
      const right: number = Math.min(info.size.width,
        Math.ceil((region.left + region.width) * scale) + padding);
      const bottom: number = Math.min(info.size.height,
        Math.ceil((region.top + region.height) * scale) + padding);
      const width: number = right - left;
      const height: number = bottom - top;
      if (width <= 0 || height <= 0) {
        return;
      }
      const stride: number = width * 4;
      const buffer: ArrayBuffer = new ArrayBuffer(stride * height);
      const area: image.PositionArea = {
        pixels: buffer,
        offset: 0,
        stride: stride,
        region: { x: left, y: top, size: { width: width, height: height } }
      };
      await pixelMap.readPixels(area);
      const style: RedactionStyle = this.styleForFinding(finding);
      const styleNumber: number = style === RedactionStyle.PIXELATE ? 1 :
        style === RedactionStyle.BLUR ? 2 : 0;
      // Off-main-thread: same taskpool routine as the final export.
      const processed: ArrayBuffer = await runRedaction(buffer, stride,
        width, height, styleNumber);
      const regionPixelMap: image.PixelMap = await image.createPixelMap(processed,
        { size: { width: width, height: height }, pixelFormat: image.PixelMapFormat.RGBA_8888 });
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path: string = `${context.cacheDir}/safeshare-prev-${Date.now()}-${finding.id.replace(/[^a-z0-9]/gi, '')}.png`;
      const target: fileIo.File = await fileIo.open(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const packer: image.ImagePacker = image.createImagePacker();
      await packer.packToFile(regionPixelMap, target.fd, { format: 'image/png', quality: 100 });
      packer.release();
      regionPixelMap.release();
      await fileIo.closeSync(target);
      if (generation !== this.previewGeneration) {
        // The preview context moved on while this job was decoding; drop the
        // output so no orphan file survives and no stale entry repopulates.
        fileIo.unlinkSync(path);
        return;
      }
      this.redactedPreviewUris.set(key, `file://${path}`);
      this.findings = this.findings.slice();
      this.refreshDerivedFindings();
    } catch (_) {
      // Preview falls back to a plain dark fill if pixel extraction fails.
    } finally {
      if (pixelMap !== undefined) {
        try { pixelMap.release(); } catch (_) {}
      }
      if (source !== undefined) {
        try { source.release(); } catch (_) {}
      }
      if (sourceFile !== undefined) {
        try { await fileIo.closeSync(sourceFile); } catch (_) {}
      }
    }
  }

  private clearRedactedPreviews(): void {
    this.previewGeneration++;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.redactedPreviewUris.forEach((uri: string) => {
      const path: string = uri.replace('file://', '');
      fileIo.unlink(path).catch(() => {});
    });
    this.redactedPreviewUris.clear();
    this.redactedPreviewJobs.clear();
  }

  private metadataFindingById(id: string): PrivacyFinding | undefined {
    // IDs are globally prefixed with the source index during batch scans.
    // Do not couple an already-open editor to the live carousel index.
    return this.findings.find((finding: PrivacyFinding) => finding.id === id);
  }

  private toggleMetadataDetails(finding: PrivacyFinding): void {
    this.expandedMetadataId = this.expandedMetadataId === finding.id ? '' : finding.id;
  }

  private clearReplacementFor(finding: PrivacyFinding): void {
    finding.replacementValue = '';
    if (finding.subtype === 'CAPTURE_TIME') this.replacementCaptureTime = '';
    if (finding.subtype === 'DEVICE_MAKE') this.replacementCameraMake = '';
    if (finding.subtype === 'DEVICE_MODEL') this.replacementCameraModel = '';
    if (finding.subtype === 'AUTHOR') this.replacementAuthor = '';
    if (finding.subtype === 'COPYRIGHT') this.replacementCopyright = '';
    if (finding.subtype === 'DESCRIPTION') this.replacementDescription = '';
    if (finding.subtype === 'GPS') {
      this.replacementGpsLatitude = '';
      this.replacementGpsLongitude = '';
    }
  }

  /**
   * Single state machine for every metadata row: replaced / deleted / kept.
   * The row header and both action buttons derive from these helpers only,
   * so the displayed state and the button actions can never disagree.
   */
  private isMetadataDeleted(finding: PrivacyFinding): boolean {
    return finding.selectedForRemoval && !this.isMetadataReplacementSelected(finding);
  }

  private metadataStateLabel(finding: PrivacyFinding): string {
    if (this.isMetadataReplacementSelected(finding)) return '已替换';
    return finding.selectedForRemoval ? '已删除' : '已保留';
  }

  private chooseMetadataDeletion(finding: PrivacyFinding): void {
    if (this.isMetadataReplacementSelected(finding)) {
      // 保留 on a replaced row: drop the replacement and keep the original.
      this.clearReplacementFor(finding);
      finding.selectedForRemoval = false;
    } else {
      finding.selectedForRemoval = !finding.selectedForRemoval;
    }
    this.metadataMode = MetadataMode.CUSTOM;
    this.findings = this.findings.slice();
    this.refreshDerivedFindings();
  }

  private isMetadataReplacementSelected(finding: PrivacyFinding): boolean {
    if (finding.replacementValue.length > 0) return true;
    if (finding.subtype === 'CAPTURE_TIME') return this.replacementCaptureTime.length > 0;
    if (finding.subtype === 'DEVICE_MAKE') return this.replacementCameraMake.length > 0;
    if (finding.subtype === 'DEVICE_MODEL') return this.replacementCameraModel.length > 0;
    if (finding.subtype === 'AUTHOR') return this.replacementAuthor.length > 0;
    if (finding.subtype === 'COPYRIGHT') return this.replacementCopyright.length > 0;
    if (finding.subtype === 'DESCRIPTION') return this.replacementDescription.length > 0;
    if (finding.subtype === 'GPS') return this.replacementGpsLatitude.length > 0 &&
      this.replacementGpsLongitude.length > 0;
    return false;
  }

  private canReplaceMetadata(finding: PrivacyFinding): boolean {
    // AVMuxer can omit source container metadata during remux, but it does
    // not promise arbitrary replacement of vendor/private QuickTime keys.
    if (this.isAvSession()) return false;
    return ['GPS', 'GPS_DATE', 'CAPTURE_TIME', 'MODIFY_TIME', 'DIGITIZED_TIME', 'DEVICE_MODEL',
      'DEVICE_MAKE', 'SOFTWARE', 'AUTHOR', 'COPYRIGHT', 'COMMENT', 'DESCRIPTION', 'CAMERA_OWNER',
      'BODY_SERIAL', 'LENS_SERIAL', 'LENS_MODEL', 'GPS_ALTITUDE', 'GPS_METHOD', 'GPS_AREA',
      'DOCX_AUTHOR', 'DOCX_LAST_MODIFIED_BY', 'DOCX_SUBJECT', 'DOCX_TITLE', 'DOCX_DESCRIPTION',
      'DOCX_KEYWORDS', 'DOCX_CREATE_TIME', 'DOCX_MODIFY_TIME', 'DOCX_COMPANY', 'DOCX_MANAGER',
      'DOCX_HYPERLINK_BASE', 'PDF_AUTHOR', 'PDF_TITLE', 'PDF_SUBJECT', 'PDF_KEYWORDS',
      'PDF_CREATOR', 'PDF_PRODUCER', 'PDF_CREATE_TIME', 'PDF_MODIFY_TIME']
      .indexOf(finding.subtype) >= 0;
  }

  private padDatePart(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  private showMetadataTimePicker(finding: PrivacyFinding): void {
    const parts: string[] | null = finding.rawValue.match(/\d+/g);
    let initial: Date = new Date();
    if (parts !== null && parts.length >= 3) {
      initial = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]),
        parts.length > 3 ? Number(parts[3]) : 0, parts.length > 4 ? Number(parts[4]) : 0,
        parts.length > 5 ? Number(parts[5]) : 0);
    }
    this.getUIContext().showDatePickerDialog({
      selected: initial,
      onDateAccept: (selectedDate: Date) => {
        const year: number = selectedDate.getFullYear();
        const month: number = selectedDate.getMonth() + 1;
        const day: number = selectedDate.getDate();
        this.getUIContext().showTimePickerDialog({
          selected: initial,
          useMilitaryTime: true,
          onAccept: (timeResult: TimePickerResult) => {
            const hour: number = timeResult.hour ?? initial.getHours();
            const minute: number = timeResult.minute ?? initial.getMinutes();
            const replacement: string = finding.subtype.startsWith('DOCX_') ||
              finding.subtype.startsWith('PDF_') ?
              new Date(year, month - 1, day, hour, minute, 0).toISOString() :
              `${year}:${this.padDatePart(month)}:${this.padDatePart(day)} ` +
                `${this.padDatePart(hour)}:${this.padDatePart(minute)}:00`;
            finding.replacementValue = replacement;
            if (finding.subtype === 'CAPTURE_TIME') this.replacementCaptureTime = replacement;
            finding.selectedForRemoval = false;
            this.metadataMode = MetadataMode.CUSTOM;
            this.findings = this.findings.slice();
            this.refreshDerivedFindings();
          }
        });
      }
    });
  }

  private beginMetadataReplacement(finding: PrivacyFinding): void {
    if (finding.subtype === 'CAPTURE_TIME' || finding.subtype === 'MODIFY_TIME' ||
      finding.subtype === 'DIGITIZED_TIME' || finding.subtype === 'DOCX_CREATE_TIME' ||
      finding.subtype === 'DOCX_MODIFY_TIME' || finding.subtype === 'PDF_CREATE_TIME' ||
      finding.subtype === 'PDF_MODIFY_TIME') {
      // Defer dialogs until the metadata-row tap has fully completed. On
      // several devices opening a dialog inside the originating pointer event
      // causes it to receive the same outside-tap and disappear immediately.
      setTimeout(() => this.showMetadataTimePicker(finding), 16);
      return;
    }
    this.replacementFindingId = finding.id;
    this.replacementDraft = finding.rawValue;
    setTimeout(() => this.replacementSheetVisible = true, 16);
  }

  private commitMetadataReplacement(): void {
    const finding: PrivacyFinding | undefined = this.metadataFindingById(this.replacementFindingId);
    if (finding === undefined || this.replacementDraft.trim().length === 0) return;
    const value: string = this.replacementDraft.trim();
    finding.replacementValue = value;
    if (finding.subtype === 'DEVICE_MAKE') this.replacementCameraMake = value;
    if (finding.subtype === 'DEVICE_MODEL') this.replacementCameraModel = value;
    if (finding.subtype === 'AUTHOR') this.replacementAuthor = value;
    if (finding.subtype === 'COPYRIGHT') this.replacementCopyright = value;
    if (finding.subtype === 'DESCRIPTION') this.replacementDescription = value;
    if (finding.subtype === 'GPS') {
      const coordinates: string[] = value.split('|');
      if (coordinates.length !== 2) return;
      this.replacementGpsLatitude = coordinates[0].trim();
      this.replacementGpsLongitude = coordinates[1].trim();
    }
    finding.selectedForRemoval = false;
    this.metadataMode = MetadataMode.CUSTOM;
    this.findings = this.findings.slice();
    this.refreshDerivedFindings();
    this.replacementSheetVisible = false;
  }

  private styleForFinding(finding: PrivacyFinding): RedactionStyle {
    if (this.redactionStyle !== RedactionStyle.AUTO) {
      return this.redactionStyle;
    }
    if (finding.category === FindingCategory.MANUAL) {
      return RedactionStyle.PIXELATE;
    }
    if (finding.category === FindingCategory.QR || finding.subtype === 'ID_CARD_LIKE' ||
      finding.subtype === 'BANK_CARD_LIKE' || finding.subtype === 'OTP_LIKE' ||
      finding.subtype === 'DEVICE_IDENTIFIER') {
      return RedactionStyle.SOLID;
    }
    if (finding.category === FindingCategory.FACE) {
      return RedactionStyle.PIXELATE;
    }
    if (finding.category === FindingCategory.OBJECT) {
      return RedactionStyle.PIXELATE;
    }
    return RedactionStyle.BLUR;
  }

  private appendUniqueAction(actions: RedactionAction[], finding: PrivacyFinding): void {
    if (finding.region === undefined) {
      return;
    }
    for (let index: number = 0; index < actions.length; index++) {
      if (this.regionOverlap(actions[index].region, finding.region) >= 0.8) {
        return;
      }
    }
    actions.push(new RedactionAction(finding.region, this.styleForFinding(finding), finding.category, finding.subtype));
  }

  private regionOverlap(first: SensitiveRegion, second: SensitiveRegion): number {
    const left: number = Math.max(first.left, second.left);
    const top: number = Math.max(first.top, second.top);
    const right: number = Math.min(first.left + first.width, second.left + second.width);
    const bottom: number = Math.min(first.top + first.height, second.top + second.height);
    if (right <= left || bottom <= top) {
      return 0;
    }
    const intersection: number = (right - left) * (bottom - top);
    const smallerArea: number = Math.min(first.width * first.height, second.width * second.height);
    return smallerArea > 0 ? intersection / smallerArea : 0;
  }

  private redactionStyleIndex(): number {
    if (this.redactionStyle === RedactionStyle.BLUR) {
      return 1;
    }
    if (this.redactionStyle === RedactionStyle.PIXELATE) {
      return 2;
    }
    if (this.redactionStyle === RedactionStyle.SOLID) {
      return 3;
    }
    return 0;
  }

  private redactionStyleLabel(): string {
    const labels: string[] = ['智能推荐', '强模糊', '马赛克', '纯色遮盖'];
    return labels[this.redactionStyleIndex()];
  }

  private setRedactionStyle(index: number): void {
    const styles: RedactionStyle[] = [RedactionStyle.AUTO, RedactionStyle.BLUR,
      RedactionStyle.PIXELATE, RedactionStyle.SOLID];
    if (index >= 0 && index < styles.length) {
      this.redactionStyle = styles[index];
      this.clearRedactedPreviews();
    }
  }

  private isIdentityDocumentCandidate(): boolean {
    return this.visibleVisualFindings().some((finding: PrivacyFinding) =>
      finding.subtype === 'ID_CARD_LIKE' || finding.subtype === 'BANK_CARD_LIKE');
  }

  private applyIdentityProtection(): void {
    for (let index: number = 0; index < this.findings.length; index++) {
      const finding: PrivacyFinding = this.findings[index];
      if (finding.sourceIndex !== this.previewIndex || finding.region === undefined) continue;
      if (finding.subtype === 'ID_CARD_LIKE' || finding.subtype === 'BANK_CARD_LIKE' ||
        finding.subtype === 'ADDRESS_LIKE') {
        finding.selectedForRemoval = true;
      }
    }
    this.findings = this.findings.slice();
    this.refreshDerivedFindings();
    if (this.purposeWatermark.length === 0) this.purposeWatermark = '仅供办理本次业务使用';
  }

  private applyRecommendedProtection(): void {
    for (let index: number = 0; index < this.findings.length; index++) {
      const finding: PrivacyFinding = this.findings[index];
      if (finding.region === undefined) continue;
      finding.selectedForRemoval = finding.risk === RiskLevel.HIGH ||
        finding.category === FindingCategory.FACE || finding.category === FindingCategory.QR;
    }
    this.findings = this.findings.slice();
    this.refreshDerivedFindings();
  }

  private setPurposeWatermark(index: number): void {
    if (index >= 0 && index < this.watermarkSlots.length) {
      this.watermarkCustomMode = false;
      this.selectedWatermarkSlot = index;
      this.purposeWatermark = this.watermarkSlots[index];
    } else if (index === this.watermarkSlots.length) {
      this.watermarkCustomMode = true;
      this.selectedWatermarkSlot = -1;
      this.purposeWatermark = '';
    }
  }

  private updateWatermarkSlot(index: number, value: string): void {
    if (index < 0 || index >= this.watermarkSlots.length) return;
    const slots: string[] = this.watermarkSlots.slice();
    slots[index] = value.slice(0, 40);
    this.watermarkSlots = slots;
    this.saveMetadataDefaults();
  }

  private watermarkColorMode(): number {
    if (this.watermarkColor === '#FFFFFF') return 0;
    if (this.watermarkColor === '#000000') return 1;
    return 2;
  }

  private setWatermarkColorMode(index: number): void {
    if (index === 0) {
      this.watermarkColor = '#FFFFFF';
    } else if (index === 1) {
      this.watermarkColor = '#000000';
    } else {
      this.watermarkColor = this.customWatermarkColor;
    }
    this.watermarkDarkText = this.watermarkColor === '#000000';
    this.saveMetadataDefaults();
  }

  private updateCustomWatermarkColor(value: string): void {
    let candidate: string = value.trim().toUpperCase();
    if (!candidate.startsWith('#')) candidate = `#${candidate}`;
    this.customWatermarkColor = candidate.slice(0, 7);
    if (/^#[0-9A-F]{6}$/.test(this.customWatermarkColor)) {
      this.watermarkColor = this.customWatermarkColor;
      this.watermarkDarkText = false;
      this.saveMetadataDefaults();
    }
  }

  private openWatermarkColorPicker(): void {
    const source: string = /^#[0-9A-Fa-f]{6}$/.test(this.watermarkColor) ?
      this.watermarkColor : this.customWatermarkColor;
    this.setColorPickerHex(source);
    this.colorPickerVisible = true;
  }

  private setColorPickerHex(value: string): void {
    let candidate: string = value.trim().toUpperCase();
    if (!candidate.startsWith('#')) candidate = `#${candidate}`;
    this.colorPickerDraft = candidate.slice(0, 7);
    if (!/^#[0-9A-F]{6}$/.test(this.colorPickerDraft)) return;
    this.colorPickerRed = Number.parseInt(this.colorPickerDraft.substring(1, 3), 16);
    this.colorPickerGreen = Number.parseInt(this.colorPickerDraft.substring(3, 5), 16);
    this.colorPickerBlue = Number.parseInt(this.colorPickerDraft.substring(5, 7), 16);
  }

  private updateColorChannel(channel: number, value: number): void {
    const next: number = Math.max(0, Math.min(255, Math.round(value)));
    if (channel === 0) this.colorPickerRed = next;
    if (channel === 1) this.colorPickerGreen = next;
    if (channel === 2) this.colorPickerBlue = next;
    this.colorPickerDraft = `#${this.hexChannel(this.colorPickerRed)}` +
      `${this.hexChannel(this.colorPickerGreen)}${this.hexChannel(this.colorPickerBlue)}`;
  }

  private hexChannel(value: number): string {
    const text: string = Math.max(0, Math.min(255, Math.round(value))).toString(16).toUpperCase();
    return text.length === 1 ? `0${text}` : text;
  }

  private confirmWatermarkColor(): void {
    if (!/^#[0-9A-F]{6}$/.test(this.colorPickerDraft)) return;
    this.customWatermarkColor = this.colorPickerDraft;
    this.watermarkColor = this.colorPickerDraft;
    this.watermarkDarkText = this.watermarkColor === '#000000';
    this.colorPickerVisible = false;
    this.saveMetadataDefaults();
  }

  private currentPreviewUri(): string {
    if (this.status === PageStatus.READY && this.showSafePreview) {
      const safeFile: SanitizedFile | undefined = this.sanitizedFileForSource(this.previewIndex);
      if (safeFile !== undefined) return safeFile.uri;
    }
    if (this.previewIndex < this.selectedUris.length) {
      return this.selectedUris[this.previewIndex];
    }
    return this.selectedUri;
  }

  private async openFullFilePreview(): Promise<void> {
    try {
      const mimeType: string = this.isAvSession() ? this.currentMediaMimeType() : '';
      const opened: boolean = await this.getService().openFilePreview(this.currentPreviewUri(), mimeType);
      if (!opened) {
        this.getUIContext().getPromptAction().showToast({ message: '系统暂不支持预览此文件' });
      }
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: '暂时无法打开完整预览' });
    }
  }

  private isLandscapeWindow(): boolean {
    return this.viewportWidth > this.viewportHeight * 1.08;
  }

  private isExpandedWindow(): boolean {
    return this.viewportWidth >= 840;
  }

  /**
   * Two-pane preview+details from the official md breakpoint (≥840vp).
   * Landscape phones reach md too, and the landscape previewHeight branch
   * keeps the preview compact enough for the side-by-side layout.
   */
  private useTwoPaneLayout(): boolean {
    // FULL means the unfolded inner display. Book-style foldables such as
    // many book-style devices are close to square, so orientation is not a
    // useful signal: both rotations keep the tablet workspace instead of
    // falling back to the phone stack on the slightly narrower side.
    return this.expandedFoldInnerDisplay || this.breakpoint === 'md' || this.breakpoint === 'lg';
  }

  private useDocumentWorkspace(): boolean {
    return this.useTwoPaneLayout() && !this.isAvSession() && this.trackedFileKind !== FileKind.IMAGE;
  }

  private imagePaneRatio(): number {
    // Editing controls are the primary task. Keep the photo subordinate and
    // give metadata labels/actions a stable majority of the canvas.
    return 0.45;
  }

  private primaryPaneWidth(): string {
    if (this.useDocumentWorkspace()) return '32%';
    if (!this.useTwoPaneLayout()) return '100%';
    return '45%';
  }

  private inspectorPaneWidth(): string {
    if (this.useDocumentWorkspace()) return '68%';
    if (!this.useTwoPaneLayout()) return '100%';
    return '55%';
  }

  private tabletUiScale(): number {
    if (this.breakpoint === 'lg') return 1.16;
    if (this.breakpoint === 'md' || this.expandedFoldInnerDisplay) return 1.10;
    return 1;
  }

  private documentFileIndexes(): number[] {
    const indexes: number[] = [];
    for (let index: number = 0; index < this.selectedUris.length; index++) indexes.push(index);
    return indexes;
  }

  private findingCountForSource(sourceIndex: number): number {
    let count: number = 0;
    for (let index: number = 0; index < this.findings.length; index++) {
      if (this.findings[index].sourceIndex === sourceIndex) count++;
    }
    return count;
  }

  private inspectorFindingCount(): number {
    return this.useDocumentWorkspace() ? this.visibleFindings().length : this.findings.length;
  }

  private inspectorSummary(): string {
    if (this.status === PageStatus.READY) return this.message;
    if (this.previewIndex < this.scanResults.length && this.scanResults[this.previewIndex].scanFailed) {
      return '这个文件未完成检查';
    }
    if (this.isAvSession()) {
      return this.inspectorFindingCount() === 0 ? '未发现可读取的隐私元数据' :
        `${this.inspectorFindingCount()} 项容器元数据`;
    }
    if (!this.useDocumentWorkspace()) {
      return this.inspectorFindingCount() === 0 ? '未发现常见隐私风险' :
        `${this.selectedUris.length} 个文件已完成检查`;
    }
    return `文件 ${this.previewIndex + 1} · ${this.fileKindLabelAt(this.previewIndex)} · ` +
      `${this.visibleFindings().length} 项可清理信息`;
  }

  private fileKindLabelAt(sourceIndex: number): string {
    if (sourceIndex < 0 || sourceIndex >= this.selectedUris.length) return '文件';
    const kind: FileKind = sourceIndex < this.scanResults.length ?
      this.scanResults[sourceIndex].fileKind as FileKind :
      (sourceIndex < this.resolvedFileKinds.length ? this.resolvedFileKinds[sourceIndex] :
        FileTypeRouter.detect(this.selectedUris[sourceIndex], this.selectedUtds[sourceIndex] ?? ''));
    return this.getService().labelOf(kind);
  }

  private selectPreview(sourceIndex: number): void {
    if (sourceIndex < 0 || sourceIndex >= this.selectedUris.length || sourceIndex === this.previewIndex) return;
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.previewIndex = sourceIndex;
      this.syncTrackedFileKind();
      this.syncPreviewPixelSize();
    });
    this.syncPdfPreview();
  }

  private previewHeight(): number {
    const availableWidth: number = Math.max(180, Math.min(this.viewportWidth - 40, 960));
    if (this.useTwoPaneLayout() && this.trackedFileKind === FileKind.IMAGE) {
      // The summary card sits directly below the preview. About 62% for the
      // image works in landscape; portrait uses a calmer 45% so the preview
      // never pushes the controls below the fold.
      const heightRatio: number = this.isLandscapeWindow() ? 0.62 : 0.45;
      return Math.max(240, Math.min(this.isLandscapeWindow() ? 650 : 560,
        this.viewportHeight * heightRatio));
    }
    if (this.isLandscapeWindow()) {
      if (this.useTwoPaneLayout()) {
        const reservedHeight: number = this.selectedUris.length > 1 ? 340 : 250;
        return Math.max(180, Math.min(520, this.viewportHeight - reservedHeight));
      }
      return Math.max(160, Math.min(320, this.viewportHeight * 0.46));
    }
    if (this.viewportWidth >= 600) {
      return Math.max(220, Math.min(560, Math.round(availableWidth * 0.72), this.viewportHeight * 0.45));
    }
    return Math.max(180, Math.min(400, Math.round(availableWidth * 0.78), this.viewportHeight * 0.45));
  }

  private previewWidth(): number {
    const contentWidth: number = this.useTwoPaneLayout() ?
      (this.viewportWidth - 40) * this.imagePaneRatio() :
      this.viewportWidth - 40;
    return Math.max(180, Math.min(contentWidth, 960));
  }

  /**
   * Overlay geometry must be derived from the preview Image's measured size,
   * not from a formula: the Image fills the available width and its Contain
   * letterbox differs per device, so any predicted size misplaces both the
   * redaction boxes and the watermark preview.
   */
  private previewSurfaceWidth(): number {
    return this.previewSurfaceWidthState > 0 ? this.previewSurfaceWidthState : this.previewWidth();
  }

  private previewSurfaceHeight(): number {
    return this.previewSurfaceHeightState > 0 ? this.previewSurfaceHeightState : this.previewHeight();
  }

  private useCoverPreview(): boolean {
    return this.useTwoPaneLayout() && this.trackedFileKind === FileKind.IMAGE;
  }

  private syncPreviewPixelSize(): void {
    if (this.previewIndex < this.scanResults.length) {
      this.previewPixelWidthState = this.scanResults[this.previewIndex].pixelWidth;
      this.previewPixelHeightState = this.scanResults[this.previewIndex].pixelHeight;
      this.mediaPreviewPixelMap = this.scanResults[this.previewIndex].previewPixelMap;
    } else {
      this.previewPixelWidthState = 0;
      this.previewPixelHeightState = 0;
      this.mediaPreviewPixelMap = undefined;
    }
  }

  private mediaPreviewHeight(): number {
    if (this.useTwoPaneLayout()) {
      return Math.max(220, Math.min(440, this.viewportHeight * 0.52));
    }
    return Math.max(190, Math.min(330, this.viewportHeight * 0.34));
  }

  private hasVideoPreview(): boolean {
    return this.trackedFileKind === FileKind.AUDIO_VIDEO && this.mediaPreviewPixelMap !== undefined;
  }

  private previewScale(): number {
    if (this.previewPixelWidthState <= 0 || this.previewPixelHeightState <= 0) return 1;
    const widthScale: number = this.previewSurfaceWidth() / this.previewPixelWidthState;
    const heightScale: number = this.previewSurfaceHeight() / this.previewPixelHeightState;
    return this.useCoverPreview() ? Math.max(widthScale, heightScale) :
      Math.min(widthScale, heightScale);
  }

  private previewOffsetX(): number {
    return (this.previewSurfaceWidth() - this.previewPixelWidthState * this.previewScale()) / 2;
  }

  private previewOffsetY(): number {
    return (this.previewSurfaceHeight() - this.previewPixelHeightState * this.previewScale()) / 2;
  }

  /** Displayed width of the photo itself (letterboxed inside the preview area). */
  private previewContentWidth(): number {
    if (this.previewPixelWidthState > 0) {
      return this.previewPixelWidthState * this.previewScale();
    }
    return this.previewSurfaceWidth();
  }

  private previewContentHeight(): number {
    if (this.previewPixelHeightState > 0) {
      return this.previewPixelHeightState * this.previewScale();
    }
    return this.previewSurfaceHeight();
  }

  private clampPreviewX(value: number): number {
    const left: number = this.previewOffsetX();
    const right: number = left + this.previewPixelWidthState * this.previewScale();
    return Math.max(left, Math.min(value, right));
  }

  private clampPreviewY(value: number): number {
    const top: number = this.previewOffsetY();
    const bottom: number = top + this.previewPixelHeightState * this.previewScale();
    return Math.max(top, Math.min(value, bottom));
  }

  @Builder
  FindingOverlay(finding: PrivacyFinding) {
    if (finding.region !== undefined) {
      Row() {
        if (finding.selectedForRemoval) {
          Image(this.redactedPreviewUri(finding))
            .width('100%').height('100%')
            .objectFit(ImageFit.Fill)
            .draggable(false)
            .interpolation(ImageInterpolation.None)
        }
      }
        .width(Math.max(8, finding.region.width * this.previewScale()))
        .height(Math.max(8, finding.region.height * this.previewScale()))
        .border({ width: finding.selectedForRemoval ? 3 : 2,
          color: finding.selectedForRemoval ? $r('app.color.accent') : $r('app.color.warning') })
        .borderRadius(5)
        .backgroundColor(Color.Transparent)
        .position({ x: this.previewOffsetX() + finding.region.left * this.previewScale(),
          y: this.previewOffsetY() + finding.region.top * this.previewScale() })
        .clip(true)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText(finding.selectedForRemoval ?
          '已选中的遮盖区域，点击取消遮盖' : '检测到的隐私区域，点击选择遮盖')
        .onClick(() => this.toggleFinding(finding))
    }
  }

  @Builder
  WatermarkPreviewOverlay() {
    // Live preview must follow the watermark toggle, not the share-entry
    // mode: users enable the watermark on the result page of a privacy run.
    if ((this.featureMode === FeatureMode.WATERMARK || this.watermarkApplied) &&
      this.purposeWatermark.trim().length > 0 && this.status !== PageStatus.READY) {
      Column({ space: 34 * this.watermarkSpacing }) {
        ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], (row: number) => {
          Row({ space: 54 * this.watermarkSpacing }) {
            ForEach([0, 1, 2, 3], (column: number) => {
              Text(this.purposeWatermark)
                .fontSize(18 * this.watermarkScale).fontWeight(FontWeight.Bold)
                .fontColor(this.watermarkColor)
                .opacity(Math.max(0.12, Math.min(0.55, this.watermarkOpacity)))
                .rotate({ angle: this.watermarkAngle })
                .maxLines(1)
            }, (column: number) => `${row}-${column}`)
          }.translate({ x: row % 2 === 0 ? -70 : -150 })
        }, (row: number) => `${row}`)
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center)
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  PdfWatermarkPreviewOverlay() {
    // Visual-density preview matching the pipeline's adaptive grid: cell
    // size scales with the text footprint and the font-size slider, so the
    // preview reads at the same density as the generated copy.
    if (this.pdfWatermarkOn && this.pdfWatermarkText.trim().length > 0) {
      Column() {
        ForEach(this.pdfPreviewRows(), (row: number) => {
          Row() {
            ForEach(this.pdfPreviewCols(), (column: number) => {
              Text(this.pdfWatermarkText)
                .fontSize(this.pdfPreviewCellFont()).fontWeight(FontWeight.Bold)
                .fontColor(this.pdfWatermarkDarkText ? Color.Black : Color.White)
                .opacity(Math.max(0.08, Math.min(0.9, this.pdfWatermarkOpacity)))
                .rotate({ angle: this.pdfWatermarkAngle })
                .maxLines(1)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            }, (column: number) => `pdf-${row}-${column}`)
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
        }, (row: number) => `pdf-row-${row}`)
      }
      .width('100%').height('100%')
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  private pdfPreviewCellFont(): number {
    const text: string = this.pdfWatermarkText.trim();
    let charWidthSum: number = 0;
    for (let i = 0; i < text.length; i++) {
      charWidthSum += text.charCodeAt(i) > 0x2E7F ? 1 : 0.58;
    }
    const cols: number = this.pdfPreviewCols().length;
    const cellW: number = Math.max(180, this.previewSurfaceWidth()) / cols;
    const cellH: number = Math.max(200, this.previewSurfaceHeight()) /
      this.pdfPreviewRows().length;
    return Math.max(6, Math.min(15 * this.pdfWatermarkScale,
      cellW * 0.92 / Math.max(0.6, charWidthSum), cellH / 2.4));
  }

  private pdfPreviewCols(): number[] {
    // Same density-first rule as the pipeline: at least 3 columns; long text
    // shrinks the per-cell font instead of collapsing the grid.
    const text: string = this.pdfWatermarkText.trim();
    let charWidthSum: number = 0;
    for (let i = 0; i < text.length; i++) {
      charWidthSum += text.charCodeAt(i) > 0x2E7F ? 15 : 9;
    }
    charWidthSum *= this.pdfWatermarkScale;
    const width: number = Math.max(180, this.previewSurfaceWidth());
    const cols: number = Math.floor(width /
      Math.max(charWidthSum * 1.15, width / 6));
    const count: number = Math.max(3, Math.min(8, cols));
    const out: number[] = [];
    for (let i = 0; i < count; i++) out.push(i);
    return out;
  }

  private pdfPreviewRows(): number[] {
    const height: number = Math.max(200, this.previewSurfaceHeight());
    const rows: number = Math.floor(height /
      Math.max(15 * 2.4 * this.pdfWatermarkScale, height / 8));
    const count: number = Math.max(4, Math.min(10, rows));
    const out: number[] = [];
    for (let i = 0; i < count; i++) out.push(i);
    return out;
  }

  @Builder
  PdfWatermarkCard() {
    // 仅 PDF 会话显示；状态与照片水印完全独立。
    Column({ space: 10 }) {
      Row() {
        Column({ space: 3 }) {
          Text('PDF 水印').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.pdfWatermarkOn ? '水印将写入 PDF 副本每一页' : '开启后为 PDF 副本整页添加水印')
            .fontSize(11).fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.pdfWatermarkOn })
          .onChange((value: boolean) => {
            this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
              this.pdfWatermarkOn = value;
            });
          })
      }.width('100%')
      if (this.pdfWatermarkOn) {
        TextInput({ placeholder: '输入 PDF 水印文字', text: this.pdfWatermarkText })
          .maxLength(60)
          .onChange((value: string) => this.pdfWatermarkText = value)
        Row() {
          Text('清晰度').fontSize(13).fontColor($r('app.color.text_secondary'))
          Slider({ value: this.pdfWatermarkOpacity * 100, min: 8, max: 90, step: 1 })
            .layoutWeight(1).selectedColor($r('app.color.accent'))
            .onChange((value: number) => this.pdfWatermarkOpacity = value / 100)
          Text(`${Math.round(this.pdfWatermarkOpacity * 100)}%`)
            .fontSize(12).fontColor($r('app.color.text_tertiary'))
        }.width('100%')
        Row() {
          Text('角度').fontSize(13).fontColor($r('app.color.text_secondary'))
          Slider({ value: this.pdfWatermarkAngle, min: -90, max: 90, step: 3 })
            .layoutWeight(1).selectedColor($r('app.color.accent'))
            .onChange((value: number) => this.pdfWatermarkAngle = value)
          Text(`${Math.round(this.pdfWatermarkAngle)}°`)
            .fontSize(12).fontColor($r('app.color.text_tertiary'))
        }.width('100%')
        Row() {
          Text('字号').fontSize(13).fontColor($r('app.color.text_secondary'))
          Slider({ value: this.pdfWatermarkScale * 100, min: 50, max: 250, step: 10 })
            .layoutWeight(1).selectedColor($r('app.color.accent'))
            .onChange((value: number) => this.pdfWatermarkScale = value / 100)
          Text(`${Math.round(this.pdfWatermarkScale * 100)}%`)
            .fontSize(12).fontColor($r('app.color.text_tertiary'))
        }.width('100%')
        Row({ space: 10 }) {
          Text('颜色').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          Stack() {
            Row().width(28).height(28).borderRadius(14).backgroundColor('#FFFFFF')
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
            if (!this.pdfWatermarkDarkText) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([Color.Black])
            }
          }.width(34).height(34).accessibilityText('白色水印')
            .onClick(() => this.pdfWatermarkDarkText = false)
          Stack() {
            Row().width(28).height(28).borderRadius(14).backgroundColor('#000000')
              .border({ width: 1, color: $r('app.color.surface_outline') })
            if (this.pdfWatermarkDarkText) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([Color.White])
            }
          }.width(34).height(34).accessibilityText('黑色水印')
            .onClick(() => this.pdfWatermarkDarkText = true)
        }.width('100%')
      }
    }.width('100%').padding(18).borderRadius(16).backgroundColor($r('app.color.surface'))
      .border({ width: 1.5, color: $r('app.color.surface_outline') })
      .transition(this.resultOptionCardTransition())
  }

  private previewImageWatermarkSize(): number {
    return Math.max(42, Math.min(this.previewWidth(), this.previewHeight()) *
      Math.max(0.08, Math.min(0.55, this.imageWatermarkScale)));
  }

  private previewImageWatermarkWidth(): number {
    const size: number = this.previewImageWatermarkSize();
    return this.imageWatermarkAspect >= 1 ? size : size * this.imageWatermarkAspect;
  }

  private previewImageWatermarkHeight(): number {
    const size: number = this.previewImageWatermarkSize();
    return this.imageWatermarkAspect >= 1 ? size / this.imageWatermarkAspect : size;
  }

  private previewImageWatermarkX(size: number): number {
    const column: number = this.imageWatermarkPosition % 3;
    const margin: number = Math.min(this.previewWidth(), this.previewHeight()) * this.imageWatermarkMargin;
    if (column === 0) return margin;
    if (column === 1) return (this.previewWidth() - size) / 2;
    return this.previewWidth() - size - margin;
  }

  private previewImageWatermarkY(size: number): number {
    const row: number = Math.floor(this.imageWatermarkPosition / 3);
    const margin: number = Math.min(this.previewWidth(), this.previewHeight()) * this.imageWatermarkMargin;
    if (row === 0) return margin;
    if (row === 1) return (this.previewHeight() - size) / 2;
    return this.previewHeight() - size - margin;
  }

  @Builder
  ImageWatermarkPreviewOverlay() {
    if ((this.featureMode === FeatureMode.WATERMARK || this.watermarkApplied) &&
      this.imageWatermarkUri.length > 0 && this.status !== PageStatus.READY) {
      if (this.imageWatermarkTiled) {
        ForEach([0, 1, 2, 3], (row: number) => {
          ForEach([0, 1, 2], (column: number) => {
            Image(this.imageWatermarkUri)
              .width(this.previewImageWatermarkWidth()).height(this.previewImageWatermarkHeight())
              .objectFit(ImageFit.Contain).opacity(this.imageWatermarkOpacity)
              .rotate({ angle: this.imageWatermarkAngle })
              .position({
                x: column * this.previewWidth() / 3 + (row % 2 === 0 ? -8 : 18),
                y: row * this.previewHeight() / 4
              })
          }, (column: number) => `image-mark-${row}-${column}`)
        }, (row: number) => `image-mark-row-${row}`)
      } else {
        Image(this.imageWatermarkUri)
          .width(this.previewImageWatermarkWidth()).height(this.previewImageWatermarkHeight())
          .objectFit(ImageFit.Contain).opacity(this.imageWatermarkOpacity)
          .rotate({ angle: this.imageWatermarkAngle })
          .position({ x: this.previewImageWatermarkX(this.previewImageWatermarkWidth()),
            y: this.previewImageWatermarkY(this.previewImageWatermarkHeight()) })
      }
    }
  }

  private visibleFindings(): PrivacyFinding[] {
    if (this.selectedUris.length <= 1) {
      return this.derivedFindings;
    }
    return this.derivedFindings.filter((finding: PrivacyFinding) => finding.sourceIndex === this.previewIndex);
  }

  /**
   * Rebuilds the derived (filtered) finding arrays. ArkUI only re-evaluates
   * conditional branches and ForEach sources that depend on tracked state;
   * plain method calls in if-conditions are evaluated once at branch
   * creation, so the result-page cards read these tracked copies instead.
   */
  private refreshDerivedFindings(): void {
    this.derivedFindings = this.findings.slice();
  }

  private visibleVisualFindings(): PrivacyFinding[] {
    return this.visibleFindings().filter((finding: PrivacyFinding) =>
      finding.category !== FindingCategory.METADATA);
  }

  private visibleOverlayFindings(): PrivacyFinding[] {
    return this.visibleFindings().filter((finding: PrivacyFinding) =>
      finding.category !== FindingCategory.METADATA);
  }

  private visibleMetadataFindings(): PrivacyFinding[] {
    return this.visibleFindings().filter((finding: PrivacyFinding) => finding.category === FindingCategory.METADATA);
  }

  private batchSummary(): string {
    let metadataCount: number = 0;
    let visualCount: number = 0;
    for (let index: number = 0; index < this.findings.length; index++) {
      if (this.findings[index].category === FindingCategory.METADATA) {
        metadataCount++;
      } else {
        visualCount++;
      }
    }
    let allImages: boolean = this.resolvedFileKinds.length === this.selectedUris.length;
    for (let kindIndex: number = 0; kindIndex < this.resolvedFileKinds.length; kindIndex++) {
      if (this.resolvedFileKinds[kindIndex] !== FileKind.IMAGE) allImages = false;
    }
    if (!allImages) {
      return `全部 ${this.selectedUris.length} 个文件：读取到元数据 ${metadataCount} 项`;
    }
    return `全部 ${this.selectedUris.length} 张：元数据 ${metadataCount} 项 · 视觉区域 ${visualCount} 处`;
  }

  private safeCopyDetails(): string {
    const file: SanitizedFile | undefined = this.sanitizedFileForSource(this.previewIndex);
    if (file === undefined) return '';
    const size: string = file.byteSize >= 1048576 ? `${(file.byteSize / 1048576).toFixed(1)} MB` :
      `${Math.max(1, Math.round(file.byteSize / 1024))} KB`;
    const kind: FileKind = FileTypeRouter.detect(file.uri, file.utd);
    if (kind === FileKind.IMAGE && file.pixelWidth > 0) {
      const format: string = file.mimeType.replace('image/', '').toUpperCase();
      return `${format} · ${file.pixelWidth} × ${file.pixelHeight} · ${size}`;
    }
    return `${FileTypeRouter.label(kind)} · ${size}`;
  }

  private sanitizedFileForSource(sourceIndex: number): SanitizedFile | undefined {
    for (let index: number = 0; index < this.sanitizedFiles.length; index++) {
      if (this.sanitizedFiles[index].sourceIndex === sourceIndex) return this.sanitizedFiles[index];
    }
    return undefined;
  }

  private previousPreview(): void {
    if (this.previewIndex > 0) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.previewIndex--;
        this.syncTrackedFileKind();
        this.syncPreviewPixelSize();
      });
    }
  }

  private nextPreview(): void {
    if (this.previewIndex + 1 < this.selectedUris.length) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.previewIndex++;
        this.syncTrackedFileKind();
        this.syncPreviewPixelSize();
      });
    }
  }

  @Builder
  MetadataFindingRow(finding: PrivacyFinding) {
    Column({ space: 0 }) {
      Row({ space: 12 * this.tabletUiScale() }) {
        Column() {
          Text(finding.risk === RiskLevel.HIGH ? '!' : '•')
            .fontSize(16 * this.tabletUiScale()).fontWeight(FontWeight.Bold)
            .fontColor(finding.risk === RiskLevel.HIGH ? $r('app.color.warning') : $r('app.color.accent'))
        }
        .width(32 * this.tabletUiScale()).height(32 * this.tabletUiScale())
        .justifyContent(FlexAlign.Center).borderRadius(16 * this.tabletUiScale())
        .backgroundColor(finding.risk === RiskLevel.HIGH ? $r('app.color.warning_soft') :
          $r('app.color.accent_soft'))
        Column({ space: 4 }) {
          Text(finding.title).fontSize(15 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.displayValue(finding)).fontSize(12 * this.tabletUiScale())
            .fontColor($r('app.color.text_secondary')).maxLines(1)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.isCurrentFileReadOnly() ? '仅查看' : this.metadataStateLabel(finding))
          .fontSize(12 * this.tabletUiScale())
          .fontColor(this.isCurrentFileReadOnly() ? $r('app.color.text_tertiary') :
            (this.isMetadataReplacementSelected(finding) ? $r('app.color.link') :
            (finding.selectedForRemoval ? $r('app.color.warning') : $r('app.color.text_tertiary'))))
        if (!this.isCurrentFileReadOnly()) {
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14 * this.tabletUiScale())
            .fontColor([$r('app.color.text_tertiary')])
            .rotate({ angle: this.expandedMetadataId === finding.id ? 180 : 0 })
            .animation({ duration: 220, curve: Curve.EaseOut })
        }
      }
      .width('100%').padding({ top: 14 * this.tabletUiScale(), bottom: 14 * this.tabletUiScale() })
      .onClick(() => {
        if (!this.isCurrentFileReadOnly()) this.toggleMetadataDetails(finding);
      })
      // Actions panel stays mounted so it grows out of the row (height
      // animation + clip) instead of flying in from off-screen.
      if (this.hasSanitizableFiles()) {
        Row({ space: 10 }) {
          Button(this.isMetadataDeleted(finding) ? '保留' : '删除',
            { type: ButtonType.Capsule })
            .layoutWeight(1).height(40 * this.tabletUiScale())
            .enabled(this.expandedMetadataId === finding.id)
            .fontColor(this.isMetadataDeleted(finding) ?
              $r('app.color.accent') : $r('app.color.warning'))
            .backgroundColor(this.isMetadataDeleted(finding) ?
              $r('app.color.accent_soft') : $r('app.color.warning_soft'))
            .onClick(() => this.chooseMetadataDeletion(finding))
          if (this.canReplaceMetadata(finding)) {
            Button(this.isMetadataReplacementSelected(finding) ? '重新替换' : '替换',
              { type: ButtonType.Capsule })
              .layoutWeight(1).height(40 * this.tabletUiScale())
              .enabled(this.expandedMetadataId === finding.id)
              .fontColor(this.isMetadataReplacementSelected(finding) ? $r('app.color.on_accent') :
                $r('app.color.link'))
              .backgroundColor(this.isMetadataReplacementSelected(finding) ? $r('app.color.link') :
                $r('app.color.accent_soft'))
              .onClick(() => this.beginMetadataReplacement(finding))
          }
        }
        .width('100%').padding({ left: 44, right: 4 })
        .constraintSize({ maxWidth: '100%' })
        .height(this.expandedMetadataId === finding.id ? 54 * this.tabletUiScale() : 0)
        .opacity(this.expandedMetadataId === finding.id ? 1 : 0)
        .animation({ duration: 240, curve: Curve.Friction })
        .clip(true)
      }
      Divider().color($r('app.color.divider'))
    }.width('100%')
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 96 }))
        .animation({ duration: 320, curve: Curve.EaseOut }))
  }

  @Builder
  FindingRow(finding: PrivacyFinding) {
    Row({ space: 12 }) {
      Column() {
        Text(finding.risk === RiskLevel.HIGH ? '!' : '•')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(finding.risk === RiskLevel.HIGH ? $r('app.color.warning') : $r('app.color.accent'))
      }
      .width(32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .borderRadius(16)
      .backgroundColor(finding.risk === RiskLevel.HIGH ? $r('app.color.warning_soft') : $r('app.color.accent_soft'))

      Column({ space: 4 }) {
        Text(finding.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.displayValue(finding)).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
        Text(finding.recommendation).fontSize(12).fontColor($r('app.color.accent'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)

      Column({ space: 3 }) {
        Text(finding.selectedForRemoval ? '遮盖' : '保留')
          .fontSize(11)
          .fontColor(finding.selectedForRemoval ? $r('app.color.accent') : $r('app.color.text_tertiary'))
        Toggle({ type: ToggleType.Switch, isOn: finding.selectedForRemoval })
          .onChange((selected: boolean) => {
            finding.selectedForRemoval = selected;
            this.findings = this.findings.slice();
            this.refreshDerivedFindings();
          })
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  MetadataToggleRow(title: string, detail: string, isOn: boolean, onChange: (value: boolean) => void) {
    HdsListItemCard({
      textItem: {
        primaryText: { text: title },
        secondaryText: { text: detail }
      },
      suffixItem: new SuffixSwitch({
        isCheck: isOn,
        onChange: (value: boolean) => onChange(value)
      })
    })
    .borderRadius(16)
  }

  @Builder
  MetadataDefaultsCard() {
    ListItemGroup({ style: ListItemGroupStyle.CARD }) {
      ListItem({ style: ListItemStyle.CARD }) {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text('默认元数据处理').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('每次可在检查结果中再调整')
              .fontSize(11).fontColor($r('app.color.text_tertiary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Select([{ value: '推荐清理' }, { value: '深度清理' }, { value: '自定义' }])
            .selected(this.metadataModeIndex())
            .value(this.metadataMode === MetadataMode.DEEP_CLEAN ? '深度清理' :
              (this.metadataMode === MetadataMode.CUSTOM ? '自定义' : '推荐清理'))
            .font({ size: 13 })
            .onSelect((index: number) => this.setMetadataMode(index))
        }.width('100%').padding(12)
      }
      if (this.metadataMode === MetadataMode.CUSTOM) {
        ListItem({ style: ListItemStyle.CARD }) {
          this.MetadataToggleRow('保留拍摄时间', '可能暴露行程，默认不保留', this.preserveCaptureTime,
            (value: boolean) => { this.preserveCaptureTime = value; this.saveMetadataDefaults(); })
        }
        ListItem({ style: ListItemStyle.CARD }) {
          this.MetadataToggleRow('保留相机信息', '品牌、型号和镜头；序列号仍始终清除', this.preserveCameraInfo,
            (value: boolean) => { this.preserveCameraInfo = value; this.saveMetadataDefaults(); })
        }
        ListItem({ style: ListItemStyle.CARD }) {
          this.MetadataToggleRow('保留摄影参数', 'ISO、光圈、快门和焦距', this.preservePhotographyInfo,
            (value: boolean) => { this.preservePhotographyInfo = value; this.saveMetadataDefaults(); })
        }
        ListItem({ style: ListItemStyle.CARD }) {
          Column({ space: 8 }) {
            Text('替换字段（留空则按上方保留设置）').fontSize(13)
              .fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Start)
            TextInput({ placeholder: '拍摄时间，如 2026:09:03 18:30:00', text: this.replacementCaptureTime })
              .onChange((value: string) => { this.replacementCaptureTime = value; this.saveMetadataDefaults(); })
            TextInput({ placeholder: '相机厂商', text: this.replacementCameraMake })
              .onChange((value: string) => { this.replacementCameraMake = value; this.saveMetadataDefaults(); })
            TextInput({ placeholder: '相机型号', text: this.replacementCameraModel })
              .onChange((value: string) => { this.replacementCameraModel = value; this.saveMetadataDefaults(); })
            TextInput({ placeholder: '作者', text: this.replacementAuthor })
              .onChange((value: string) => { this.replacementAuthor = value; this.saveMetadataDefaults(); })
            TextInput({ placeholder: '版权', text: this.replacementCopyright })
              .onChange((value: string) => { this.replacementCopyright = value; this.saveMetadataDefaults(); })
            TextInput({ placeholder: '图片描述', text: this.replacementDescription })
              .onChange((value: string) => { this.replacementDescription = value; this.saveMetadataDefaults(); })
          }.width('100%').padding(12)
        }
      }
    }
  }

  /**
   * Shared landing hero for both tabs: one primary pick action plus
   * type-specific hints. The photo tab preselects its mode via ModeEntry;
   * the files tab routes by detected type.
   */
  /**
   * Shared landing hero for both tabs. The photo tab adds two trust lines;
   * the files tab surrounds the hero with a ring of type chips instead.
   */
  @Builder
  FlowTile(icon: Resource, size: number) {
    // Landing artwork remains compact on phones, while unfolded inner
    // displays and tablets gain a little more visual weight.
    Column() {
      SymbolGlyph(icon)
        .fontSize(size * this.tabletUiScale() * 0.44)
        .fontColor([this.isDropTargetActive ? $r('app.color.on_accent') : $r('app.color.accent')])
    }
    .width(size * this.tabletUiScale()).height(size * this.tabletUiScale())
    .justifyContent(FlexAlign.Center)
    .borderRadius(size * this.tabletUiScale() * 0.28)
    .backgroundColor(this.isDropTargetActive ? $r('app.color.accent') : $r('app.color.surface'))
    .border({ width: 1.5, color: $r('app.color.surface_outline') })
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
    .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 3 })
  }

  @Builder
  FlowLink() {
    Text('···')
      .fontSize(18).fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_tertiary'))
      .margin({ top: 0 })
  }

  @Builder
  TabLanding(icon: Resource, pickLabel: string, headline: string, onPick: () => void) {
    Column({ space: 22 }) {
      Row({ space: 12 }) {
        this.FlowTile(icon, 64)
        this.FlowLink()
        this.FlowTile($r('sys.symbol.eye_viewfinder_slash'), 84)
        this.FlowLink()
        this.FlowTile($r('sys.symbol.checkmark_shield'), 64)
      }
      .justifyContent(FlexAlign.Center)
      Column({ space: 6 }) {
        Text(headline)
          .fontSize(17 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
      }
      Button(pickLabel, { type: ButtonType.Capsule, stateEffect: true })
        .height(44 * this.tabletUiScale())
        .fontSize(16 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_accent'))
        .backgroundColor($r('app.color.accent'))
        .accessibilityText(pickLabel)
        .onClick(() => onPick())
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .constraintSize({ maxWidth: 1040 })
    .alignSelf(ItemAlign.Center)
    .padding({ left: 24, right: 24, top: this.isLandscapeWindow() ? 8 : 18,
      bottom: 0 })
  }

  @Builder
  PhotoHome() {
    Column({ space: 14 }) {
      this.TabLanding($r('sys.symbol.picture'), '选择照片',
        '检查照片里的隐私信息，一步生成安全副本',
        () => this.chooseImage())
      Text('了解净享如何保护隐私 ›')
        .fontSize(13).fontColor($r('app.color.link'))
        .padding(6)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .accessibilityText('打开功能教程')
        .onClick(() => {
          this.openTutorial();
        })
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: this.homeContentSafeInset() })
    .onDragEnter((event: DragEvent) => {
      event.dragBehavior = DragBehavior.COPY;
      this.isDropTargetActive = true;
    })
    .onDragLeave(() => this.isDropTargetActive = false)
    .onDrop((event: DragEvent) => this.handleImageDrop(event))
  }

  @Builder
  TrustRow(text: string) {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.checkmark_shield')).fontSize(13)
        .fontColor([$r('app.color.accent')])
      Text(text).fontSize(12).fontColor($r('app.color.text_tertiary'))
    }.justifyContent(FlexAlign.Center)
  }

  /**
   * Files tab: six file types sit evenly on a circle around one central pick
   * button. The ring is sized from the viewport so entries never clip on
   * small phones; every node opens its own picker.
   */
  @Builder
  FilesHome() {
    Stack({ alignContent: Alignment.Center }) {
      Stack() {
        this.FileTypeNode($r('sys.symbol.doc_text'), 'PDF', 0, () => this.chooseDocument(FileKind.PDF))
        this.FileTypeNode($r('sys.symbol.doc_plaintext'), 'Word', 72, () => this.chooseDocument(FileKind.WORD))
        this.FileTypeNode($r('sys.symbol.doc_plaintext_2'), 'Excel', 144, () => this.chooseDocument(FileKind.EXCEL))
        this.FileTypeNode($r('sys.symbol.doc_text_2'), 'PPT', 216, () => this.chooseDocument(FileKind.POWERPOINT))
        this.FileTypeNode($r('sys.symbol.movie'), '音视频', 288, () => this.chooseMedia())
      }
      .width(this.orbitDiameter()).height(this.orbitDiameter())
      .hitTestBehavior(HitTestMode.Transparent)

      Column({ space: 10 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.folder_badge_plus'))
            .fontSize(34 * this.tabletUiScale())
            .fontColor([$r('app.color.on_accent')])
        }
        .width(92 * this.tabletUiScale()).height(92 * this.tabletUiScale())
        .backgroundColor($r('app.color.accent'))
        .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 5 })
        .accessibilityText('选择文档')
        .onClick(() => this.chooseDocument())
        Text('选择文档').fontSize(15 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
    }
    .width('100%').height('100%')
    // The tab content extends behind the floating capsule bar, which drags
    // the vertical center below the visual midpoint. Re-center by padding
    // out the bar zone; less in landscape where vertical space is scarce.
    .padding({ bottom: this.homeContentSafeInset() })
    .onDragEnter((event: DragEvent) => {
      event.dragBehavior = DragBehavior.COPY;
      this.isDropTargetActive = true;
    })
    .onDragLeave(() => this.isDropTargetActive = false)
    .onDrop((event: DragEvent) => this.handleImageDrop(event))
  }

  /** Responsive ring: node spacing scales with the window, clamped for tablets. */
  private orbitRadius(): number {
    // Width alone makes a landscape ring overflow vertically. Use the short
    // side so freeform, split-screen and foldable canvases remain bounded.
    const shortSide: number = Math.min(this.viewportWidth, this.viewportHeight);
    const baseRadius: number = Math.max(104, Math.min(150, shortSide * 0.17));
    return baseRadius * this.tabletUiScale();
  }

  private homeContentSafeInset(): number {
    // HdsTabs floats over its content. Reserve a real no-content zone above
    // the capsule instead of tuning against one device screenshot.
    if (!this.isLandscapeWindow()) {
      return Math.max(132, Math.min(176, this.viewportHeight * 0.10));
    }
    return Math.max(144, Math.min(184, this.viewportHeight * 0.14));
  }

  private orbitDiameter(): number {
    // Node height (button 58 + label ≈ 26) must fit inside the ring layer.
    return this.orbitRadius() * 2 + 108 * this.tabletUiScale();
  }

  /**
   * One circular type entry on the ring. angleDeg is clockwise from the top.
   */
  @Builder
  FileTypeNode(icon: Resource, title: string, angleDeg: number, onOpen: () => void) {
    Column({ space: 6 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(icon)
          .fontSize(24 * this.tabletUiScale())
          .fontColor([$r('app.color.accent')])
      }
      .width(58 * this.tabletUiScale()).height(58 * this.tabletUiScale())
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1.5, color: $r('app.color.surface_outline') })
      .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 3 })
      .accessibilityText(`选择${title}文件`)
      .onClick(() => onOpen())
      Text(title)
        .fontSize(12 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
    }
    .position({
      x: this.orbitRadius() + 54 * this.tabletUiScale() +
        Math.sin(angleDeg * Math.PI / 180) * this.orbitRadius(),
      y: this.orbitRadius() + 54 * this.tabletUiScale() -
        Math.cos(angleDeg * Math.PI / 180) * this.orbitRadius()
    })
    .markAnchor({ x: '50%', y: '50%' })
  }

  @Builder
  SettingsSheet() {
    // Everything lives inside this sheet at one层级: menu and category pages
    // swap in place, so Back from a category returns here instead of leaving
    // to the home page, and content always starts top-left below the header.
    Column() {
      Row({ space: 10 }) {
        if (this.settingsPage !== 'menu') {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(36).height(36)
          .backgroundColor($r('app.color.material_surface'))
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
          .border({ width: 1, color: $r('app.color.surface_outline') })
          .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 3 })
          .accessibilityText('返回设置菜单')
          .onClick(() => this.animateSettingsTo('menu'))
        }
        Column({ space: 2 }) {
          Text(this.settingsTitle()).fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          if (this.settingsSubtitle().length > 0) {
            Text(this.settingsSubtitle()).fontSize(12).fontColor($r('app.color.text_tertiary'))
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(36).height(36)
        .backgroundColor($r('app.color.material_surface'))
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
        .border({ width: 1, color: $r('app.color.surface_outline') })
        .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 3 })
        .accessibilityText('关闭设置')
        .onClick(() => this.showSettingsSheet = false)
      }
      .width('100%').padding({ left: 4, right: 4, top: 4, bottom: 10 })

      if (this.settingsPage === 'menu') {
        Column({ space: 10 }) {
          this.SettingsCategoryRow('功能教程', '图文讲解净享如何保护你的隐私',
            () => {
              this.showSettingsSheet = false;
              this.openTutorial();
            })
          this.SettingsCategoryRow('图片元数据', '设置默认行为',
            () => this.animateSettingsTo('photo'))
          this.SettingsCategoryRow('隐私打码', '设置默认行为',
            () => this.animateSettingsTo('visual'))
          this.SettingsCategoryRow('水印', '预设水印',
            () => this.animateSettingsTo('watermark'))
          this.SettingsCategoryRow('文件处理', '设置默认行为',
            () => this.animateSettingsTo('files'))
        }
        .width('100%')
      } else {
        Scroll() {
          Column() {
            if (this.settingsPage === 'photo') {
              Column() {
                this.SettingsPhotoPageContent()
              }
              .width('100%')
              .transition(this.settingsPageTransition())
            } else if (this.settingsPage === 'visual') {
              Column() {
                this.SettingsVisualPageContent()
              }
              .width('100%')
              .transition(this.settingsPageTransition())
            } else if (this.settingsPage === 'watermark') {
              Column() {
                this.SettingsWatermarkPageContent()
              }
              .width('100%')
              .transition(this.settingsPageTransition())
            } else if (this.settingsPage === 'files') {
              Column() {
                this.SettingsFilesPageContent()
              }
              .width('100%')
              .transition(this.settingsPageTransition())
            }
          }
          .width('100%').padding({ bottom: 24 })
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.None)
        .align(Alignment.Top)
      }
    }
    .width('100%').height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  private settingsTitle(): string {
    if (this.settingsPage === 'photo') return '照片元数据';
    if (this.settingsPage === 'visual') return '隐私打码';
    if (this.settingsPage === 'watermark') return '水印';
    if (this.settingsPage === 'files') return '文件处理';
    return '默认设置';
  }

  private settingsSubtitle(): string {
    return '';
  }

    /**
   * RESULT option cards slide in from the right on appear and slide fully off
   * screen on disappear (生成副本). Asymmetric self-timed transitions: the
   * exit plays exactly once on unmount and nothing shared with the incoming
   * progress card can inherit the motion.
   */
  private resultOptionCardTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 96 }))
        .animation({ duration: 320, curve: Curve.EaseOut }),
      TransitionEffect.OPACITY.combine(
        TransitionEffect.translate({ x: Math.max(420, this.viewportWidth) }))
        .animation({ duration: 300, curve: Curve.EaseIn }));
  }

  private settingsPageTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 40 }))
        .animation({ duration: 240, curve: Curve.Friction }),
      TransitionEffect.OPACITY
        .animation({ duration: 160, curve: Curve.EaseOut }))
  }

  @Builder
  SettingsCategoryRow(title: string, subtitle: string, onOpen: () => void) {
    HdsListItemCard({
      textItem: {
        primaryText: { text: title },
        secondaryText: { text: subtitle }
      },
      suffixItem: new SuffixArrow({})
    })
      .accessibilityText(`打开${title}设置`)
      .onClick(() => onOpen())
  }

  @Builder
  SettingsPhotoPageContent() {
    Column({ space: 8 }) {
      this.DefaultMetadataHeader()
      ForEach(METADATA_DEFAULT_OPTIONS, (option: MetadataDefaultOption) => {
        HdsListItemCard({
          textItem: {
            primaryText: { text: option.title },
            secondaryText: { text: this.defaultKeepsSubtype(option.subtype) ? '保留' : '删除' }
          },
          suffixItem: new SuffixSwitch({
            isCheck: !this.defaultKeepsSubtype(option.subtype),
            onChange: (deleteValue: boolean) =>
              this.setDefaultSubtypePreserved(option.subtype, !deleteValue)
          })
        })
      }, (option: MetadataDefaultOption) => option.subtype)
    }.width('100%')
  }

  @Builder
  SettingsVisualPageContent() {
    Column({ space: 8 }) {
      this.VisualDefaultsHeader()
      this.MetadataToggleRow('检测到人脸时默认遮盖', '',
        this.redactFacesByDefault, (value: boolean) => {
          this.redactFacesByDefault = value;
          this.saveMetadataDefaults();
        })
      this.MetadataToggleRow('检测到二维码时默认遮盖', '',
        this.redactQrByDefault, (value: boolean) => {
          this.redactQrByDefault = value;
          this.saveMetadataDefaults();
        })
    }.width('100%')
  }

  @Builder
  SettingsWatermarkPageContent() {
    Column({ space: 8 }) {
      this.WatermarkDefaultsHeader()
      ForEach([0, 1, 2], (slotIndex: number) => {
        Row({ space: 12 }) {
          Text(`默认 ${slotIndex + 1}`).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).width(64)
          TextInput({ placeholder: '输入水印文案', text: this.watermarkSlots[slotIndex] })
            .maxLength(40).height(46).layoutWeight(1)
            .onChange((value: string) => this.updateWatermarkSlot(slotIndex, value))
        }.width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .borderRadius(16).backgroundColor($r('app.color.surface'))
      }, (slotIndex: number) => `watermark-slot-${slotIndex}`)
    }.width('100%')
  }

  @Builder
  SettingsFilesPageContent() {
    Column({ space: 8 }) {
      Text('设置默认行为')
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
        .width('100%').padding({ left: 12, top: 10, bottom: 6 })
      this.MetadataToggleRow('删除身份信息', '作者，最后修改者等',
        this.docIdentityDefault, (value: boolean) => {
          this.docIdentityDefault = value;
          this.saveMetadataDefaults();
        })
      this.MetadataToggleRow('删除组织信息', '公司名称、内部链接基址、自定义属性',
        this.docOrgDefault, (value: boolean) => {
          this.docOrgDefault = value;
          this.saveMetadataDefaults();
        })
      this.MetadataToggleRow('删除内容与时间', '标题、主题、备注、关键词、创建与修改时间',
        this.docContentTimeDefault, (value: boolean) => {
          this.docContentTimeDefault = value;
          this.saveMetadataDefaults();
        })
    }.width('100%')
  }

  @Builder
  DefaultMetadataHeader() {
    Text('设置默认行为')
      .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      .width('100%').padding({ left: 12, top: 10, bottom: 6 })
  }

  @Builder
  WatermarkDefaultsHeader() {
    Text('默认水印')
      .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      .width('100%').padding({ left: 12, top: 14, bottom: 6 })
  }

  @Builder
  VisualDefaultsHeader() {
    Text('设置默认行为')
      .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      .width('100%').padding({ left: 12, top: 14, bottom: 6 })
  }

  @Builder
  MetadataReplacementSheet() {
    Column({ space: 18 }) {
      Column({ space: 5 }) {
        Text(this.metadataFindingById(this.replacementFindingId)?.subtype === 'GPS' ? '替换拍摄地点' :
          `替换${this.metadataFindingById(this.replacementFindingId)?.title.replace('包含', '') ?? '元数据'}`)
          .fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text(this.metadataFindingById(this.replacementFindingId)?.subtype === 'GPS' ?
          '输入“纬度 | 经度”，已默认填入照片原值' : '已默认填入照片中的原值')
          .fontSize(12).fontColor($r('app.color.text_tertiary'))
      }.width('100%').alignItems(HorizontalAlign.Start)
      TextInput({ placeholder: '替换值', text: this.replacementDraft })
        .height(48).fontSize(15)
        .onChange((value: string) => this.replacementDraft = value)
      Row({ space: 10 }) {
        Button('取消', { type: ButtonType.Capsule })
          .layoutWeight(1).height(44).fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => this.replacementSheetVisible = false)
        Button('使用此值', { type: ButtonType.Capsule })
          .layoutWeight(1).height(44).fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent'))
          .onClick(() => this.commitMetadataReplacement())
      }.width('100%')
    }.width('100%').padding({ left: 22, right: 22, top: 12, bottom: 24 })
  }

  @Builder
  WatermarkColorPickerSheet() {
    Column({ space: 18 }) {
      Row({ space: 14 }) {
        Column({ space: 4 }) {
          Text('水印颜色').fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('选择常用色，或精确调整红、绿、蓝').fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Row()
          .width(52).height(52).borderRadius(16)
          .backgroundColor(this.colorPickerDraft)
          .border({ width: 2, color: $r('app.color.surface_outline') })
          .animation({ duration: 160, curve: Curve.EaseOut })
      }.width('100%')

      Row({ space: 10 }) {
        ForEach(['#FFFFFF', '#000000', '#007D6E', '#0A59F7', '#E84026', '#FF8A00', '#8B5CF6'],
          (preset: string) => {
            Stack() {
              Row()
                .width(36).height(36).borderRadius(18)
                .backgroundColor(preset)
                .border({ width: preset === '#FFFFFF' ? 1.5 : 0.5,
                  color: $r('app.color.surface_outline') })
              if (this.colorPickerDraft === preset) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17)
                  .fontColor([preset === '#FFFFFF' ? Color.Black : Color.White])
                  .transition(TransitionEffect.OPACITY.combine(
                    TransitionEffect.scale({ x: 0.6, y: 0.6 }))
                    .animation({ duration: 180, curve: Curve.Friction }))
              }
            }
            .width(42).height(42)
            .scale({ x: this.colorPickerDraft === preset ? 1.08 : 1,
              y: this.colorPickerDraft === preset ? 1.08 : 1 })
            .animation({ duration: 180, curve: Curve.Friction })
            .accessibilityText(`选择颜色 ${preset}`)
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 180, curve: Curve.Friction }, () => {
                this.setColorPickerHex(preset);
              });
            })
          }, (preset: string) => preset)
      }.width('100%').justifyContent(FlexAlign.SpaceBetween)

      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Text('R').width(20).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
          Slider({ value: this.colorPickerRed, min: 0, max: 255, step: 1 })
            .layoutWeight(1).selectedColor('#E84026')
            .onChange((value: number) => this.updateColorChannel(0, value))
          Text(`${this.colorPickerRed}`).width(34).fontSize(12)
            .fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.End)
        }.width('100%')
        Row({ space: 10 }) {
          Text('G').width(20).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
          Slider({ value: this.colorPickerGreen, min: 0, max: 255, step: 1 })
            .layoutWeight(1).selectedColor('#20A162')
            .onChange((value: number) => this.updateColorChannel(1, value))
          Text(`${this.colorPickerGreen}`).width(34).fontSize(12)
            .fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.End)
        }.width('100%')
        Row({ space: 10 }) {
          Text('B').width(20).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
          Slider({ value: this.colorPickerBlue, min: 0, max: 255, step: 1 })
            .layoutWeight(1).selectedColor('#0A59F7')
            .onChange((value: number) => this.updateColorChannel(2, value))
          Text(`${this.colorPickerBlue}`).width(34).fontSize(12)
            .fontColor($r('app.color.text_tertiary')).textAlign(TextAlign.End)
        }.width('100%')
      }
      .width('100%').padding(16).borderRadius(18)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1.5, color: $r('app.color.surface_outline') })

      Row({ space: 12 }) {
        TextInput({ placeholder: '#RRGGBB', text: this.colorPickerDraft })
          .maxLength(7).layoutWeight(1).height(46)
          .inputFilter('^#?[0-9A-Fa-f]{0,6}$')
          .onChange((value: string) => this.setColorPickerHex(value))
        Button('取消', { type: ButtonType.Capsule }).height(44)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => this.colorPickerVisible = false)
        Button('使用', { type: ButtonType.Capsule }).height(44)
          .enabled(/^#[0-9A-F]{6}$/.test(this.colorPickerDraft))
          .fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent'))
          .onClick(() => this.confirmWatermarkColor())
      }.width('100%')
    }
    .width('100%').padding({ left: 20, right: 20, top: 8, bottom: 18 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DocumentFileWorkspace() {
    Column({ space: 12 * this.tabletUiScale() }) {
      Row() {
        Column({ space: 2 }) {
          Text('本次文件').fontSize(17 * this.tabletUiScale()).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(`${this.selectedUris.length} 个文件`).fontSize(11 * this.tabletUiScale())
            .fontColor($r('app.color.text_tertiary'))
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Button('打开文件', { type: ButtonType.Capsule })
          .height(36 * this.tabletUiScale()).fontSize(12 * this.tabletUiScale())
          .fontColor($r('app.color.accent'))
          .backgroundColor($r('app.color.accent_soft'))
          .border({ width: 1, color: $r('app.color.accent') })
          .onClick(() => this.openFullFilePreview())
      }.width('100%')
      Scroll() {
        Column({ space: 8 * this.tabletUiScale() }) {
          ForEach(this.documentFileIndexes(), (sourceIndex: number) => {
            Row({ space: 10 * this.tabletUiScale() }) {
              Column() {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(20 * this.tabletUiScale())
                  .fontColor([sourceIndex === this.previewIndex ?
                    $r('app.color.on_accent') : $r('app.color.accent')])
              }.width(40 * this.tabletUiScale()).height(40 * this.tabletUiScale())
                .justifyContent(FlexAlign.Center).borderRadius(12 * this.tabletUiScale())
                .backgroundColor(sourceIndex === this.previewIndex ?
                  $r('app.color.accent') : $r('app.color.accent_soft'))
              Column({ space: 3 }) {
                Text(`文件 ${sourceIndex + 1}`).fontSize(14 * this.tabletUiScale())
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(this.fileKindLabelAt(sourceIndex)).fontSize(11 * this.tabletUiScale())
                  .fontColor($r('app.color.text_tertiary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text(`${this.findingCountForSource(sourceIndex)} 项`)
                .fontSize(12 * this.tabletUiScale()).fontColor(sourceIndex === this.previewIndex ?
                  $r('app.color.accent') : $r('app.color.text_secondary'))
            }
            .width('100%').padding(12 * this.tabletUiScale()).borderRadius(16 * this.tabletUiScale())
            .backgroundColor(sourceIndex === this.previewIndex ?
              $r('app.color.accent_soft') : $r('app.color.surface'))
            .border({ width: sourceIndex === this.previewIndex ? 1.5 : 1,
              color: sourceIndex === this.previewIndex ?
                $r('app.color.accent') : $r('app.color.surface_outline') })
            .onClick(() => this.selectPreview(sourceIndex))
          }, (sourceIndex: number) => `workspace-file-${sourceIndex}`)
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      Row({ space: 8 }) {
        Text(this.fileKindLabelAt(this.previewIndex)).fontSize(12 * this.tabletUiScale())
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(`当前 ${this.previewIndex + 1}/${this.selectedUris.length}`)
          .fontSize(12 * this.tabletUiScale()).fontColor($r('app.color.text_tertiary'))
      }.width('100%').padding({ left: 4, right: 4 })
    }
    .width('100%').height('100%').padding(16 * this.tabletUiScale())
    .borderRadius(20 * this.tabletUiScale()).backgroundColor($r('app.color.surface'))
    .border({ width: 2, color: $r('app.color.surface_outline') })
  }

  @Builder
  InspectionSummaryCard() {
    Row({ space: 12 * this.tabletUiScale() }) {
      Column({ space: 4 }) {
        Text(this.status === PageStatus.READY ? '处理完成' : '检查完成')
          .fontSize(13 * this.tabletUiScale()).fontColor($r('app.color.text_secondary'))
        Text(this.status === PageStatus.READY ? '处理完成' : `${this.inspectorFindingCount()} 项`)
          .fontSize(28 * this.tabletUiScale()).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
      }.alignItems(HorizontalAlign.Start)
        .constraintSize({ minWidth: 78 * this.tabletUiScale() })
      Text(this.status === PageStatus.READY ?
        `已删除 ${this.removedEntryCount} 条隐私条目` : this.inspectorSummary())
        .fontSize(14 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
    .borderRadius(16 * this.tabletUiScale()).backgroundColor($r('app.color.surface'))
    .border({ width: 1.5, color: $r('app.color.surface_outline') })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 96 }))
      .animation({ duration: 320, curve: Curve.EaseOut }))
  }

  @Builder
  ScanContent() {
    Stack({ alignContent: Alignment.BottomEnd }) {
    Flex({ direction: this.useTwoPaneLayout() ? FlexDirection.Row : FlexDirection.Column,
      wrap: FlexWrap.NoWrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Start }) {
      Column({ space: 12 }) {
      // Documents/AV get a compact type card instead of a huge icon-only
      // placeholder; all preview overlays are image-only.
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.trackedFileKind === FileKind.IMAGE) {
          Image(this.currentPreviewUri())
            .width('100%').height(this.previewHeight())
            .objectFit(this.useCoverPreview() ? ImageFit.Cover : ImageFit.Contain)
            .onAreaChange((_oldValue: Area, newValue: Area) => {
              this.previewSurfaceWidthState =
                Math.round(Number.parseFloat(newValue.width.toString()));
              this.previewSurfaceHeightState =
                Math.round(Number.parseFloat(newValue.height.toString()));
            })
          // Watermark previews must render only over the photo's own displayed
          // rect: the sanitizer writes watermarks into image pixels, and
          // letting the overlay bleed onto the letterbox background both looks
          // wrong and could intercept overlay taps.
          Stack() {
            this.WatermarkPreviewOverlay()
            this.ImageWatermarkPreviewOverlay()
          }
          .width(this.previewContentWidth())
          .height(this.previewContentHeight())
          .position({ x: this.previewOffsetX(), y: this.previewOffsetY() })
          .clip(true)
          .hitTestBehavior(HitTestMode.None)
          if (this.status === PageStatus.RESULT && this.featureMode === FeatureMode.PRIVACY) {
            ForEach(this.visibleOverlayFindings(), (finding: PrivacyFinding) => {
              this.FindingOverlay(finding)
            }, (finding: PrivacyFinding) => `overlay-${finding.id}`)
          }
        } else if (this.hasVideoPreview()) {
          Image(this.mediaPreviewPixelMap)
            .width('100%').height(this.mediaPreviewHeight()).objectFit(ImageFit.Contain)
        } else if (this.trackedFileKind === FileKind.PDF && this.pdfPreviewPixelMap !== undefined) {
          // PDF watermark preview: page 1 rendered by PDF Kit with the same
          // tiled-text overlay style as the photo watermark. Read-only.
          Stack({ alignContent: Alignment.TopStart }) {
            Image(this.pdfPreviewPixelMap)
              .width('100%').height('100%').objectFit(ImageFit.Contain)
            this.PdfWatermarkPreviewOverlay()
          }
          .width('100%')
          .height(this.previewHeight())
          .clip(true)
        } else if (this.useDocumentWorkspace()) {
          this.DocumentFileWorkspace()
        } else {
          Row({ space: 14 }) {
            Column() {
              SymbolGlyph(this.isVideoSession() ? $r('sys.symbol.movie') :
                (this.isAvSession() ? $r('sys.symbol.music_note_list') :
                $r('sys.symbol.doc_text'))).fontSize(26)
                .fontColor([$r('app.color.accent')])
            }
            .width(56).height(56).justifyContent(FlexAlign.Center)
            .borderRadius(14).backgroundColor($r('app.color.accent_soft'))
            Column({ space: 3 }) {
              Text(`${this.kindLabel()} · 第 ${this.previewIndex + 1}/${this.selectedUris.length} 个`)
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text(this.isAvSession() ? '轻触使用系统预览；本页仅检查元数据' :
                '将生成清理后的文档副本')
                .fontSize(12).fontColor($r('app.color.text_tertiary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%').padding(14)
          .borderRadius(16).backgroundColor($r('app.color.surface'))
          .transition(this.settingsPageTransition())
        }
      }
      .width('100%')
      .height(this.trackedFileKind === FileKind.IMAGE ? this.previewHeight() :
        (this.hasVideoPreview() ? this.mediaPreviewHeight() :
          ((this.useTwoPaneLayout() && !this.isAvSession()) ? this.previewHeight() : 86)))
      .margin({ top: 8, bottom: 6 })
      .borderRadius(this.trackedFileKind === FileKind.IMAGE || this.hasVideoPreview() ?
        16 * this.tabletUiScale() : 0)
      .backgroundColor(this.trackedFileKind === FileKind.IMAGE || this.hasVideoPreview() ?
        $r('app.color.surface') : Color.Transparent)
      .border({ width: this.trackedFileKind === FileKind.IMAGE || this.hasVideoPreview() ? 1.5 : 0,
        color: $r('app.color.surface_outline') })
      .clip(this.trackedFileKind === FileKind.IMAGE || this.hasVideoPreview())
      .onClick(() => {
        if (this.isAvSession()) this.openFullFilePreview();
      })
      // Portrait only. Two-pane layouts keep the left pane to preview (+ the
      // compare toggle when ready): the inspector pane already carries the
      // same information (metadata card in RESULT, 处理摘要 in READY), and a
      // second summary squeezed the compare/redaction content off screen.
      if (this.featureMode === FeatureMode.PRIVACY && !this.useTwoPaneLayout() &&
        this.status !== PageStatus.SCANNING &&
        this.status !== PageStatus.SANITIZING && this.status !== PageStatus.ERROR) {
        this.InspectionSummaryCard()
      }
      if (this.status === PageStatus.READY && this.visibleVisualFindings().length > 0) {
        TabSegmentButtonV2({
          items: new SegmentButtonV2Items([{ text: '原图' }, { text: '安全副本' }]),
          selectedIndex: this.showSafePreview ? 1 : 0,
          $selectedIndex: (index: number) => { this.showSafePreview = index === 1; },
          itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('app.color.accent')),
          itemFontColor: ColorMetrics.resourceColor($r('app.color.text_primary')),
          itemSelectedFontColor: ColorMetrics.resourceColor($r('app.color.on_accent')),
          buttonBackgroundColor: ColorMetrics.resourceColor($r('app.color.surface'))
        })
          .width('100%')
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.BOTTOM))
            .animation({ duration: 240, curve: Curve.Friction }))
      }
      if (this.selectedUris.length > 1 && !this.useDocumentWorkspace()) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(44).height(44)
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
          .enabled(this.previewIndex > 0)
          .opacity(this.previewIndex > 0 ? 1 : 0.42)
          .accessibilityText(this.isAvSession() ? '上一个文件' : '上一张')
          .onClick(() => this.previousPreview())
          Column({ space: 2 }) {
            Text(`第 ${this.previewIndex + 1} / ${this.selectedUris.length} ${this.isAvSession() ? '个' : '张'}`)
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(this.batchSummary()).fontSize(11).fontColor($r('app.color.text_tertiary')).maxLines(1)
          }.layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(22)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(44).height(44)
          .backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
          .enabled(this.previewIndex + 1 < this.selectedUris.length)
          .opacity(this.previewIndex + 1 < this.selectedUris.length ? 1 : 0.42)
          .accessibilityText(this.isAvSession() ? '下一个文件' : '下一张')
          .onClick(() => this.nextPreview())
        }.width('100%')
      }
      }
      .width(this.primaryPaneWidth())
      .padding({ left: 20, right: this.useTwoPaneLayout() ? 10 : 20 })

      Scroll() {
        Column({ space: 18 * this.tabletUiScale() }) {
        if (this.status === PageStatus.SCANNING || this.status === PageStatus.SANITIZING) {
        Column({ space: 16 }) {
          LoadingProgress().width(42).height(42).color($r('app.color.accent'))
          Text(this.message).fontSize(15).fontColor($r('app.color.text_secondary'))
        }
        .width('100%').padding(28).borderRadius(16).backgroundColor($r('app.color.surface'))
        .border({ width: 1.5, color: $r('app.color.surface_outline') })
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 240, curve: Curve.Friction }))
      } else if (this.status === PageStatus.ERROR) {
        Column({ space: 14 }) {
          Text('未完成检查').fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text(this.message).fontSize(14).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
          Button('重新选择').fontColor($r('app.color.on_accent'))
            .backgroundColor($r('app.color.accent')).onClick(() => this.repickCurrent())
        }.width('100%').padding(24).borderRadius(16).backgroundColor($r('app.color.surface'))
        .border({ width: 1.5, color: $r('app.color.surface_outline') })
        .transition(TransitionEffect.OPACITY
          .animation({ duration: 240, curve: Curve.Friction }))
      } else {
        // One wrapper for the whole RESULT option pane. optionsOut drives a
        // plain animated translate/opacity; after the exit completes
        // (onFinish) optionsRemoved unmounts it so the space backfills.
        if (!this.optionsRemoved) {
        Column({ space: 18 * this.tabletUiScale() }) {
        if (this.capabilityWarnings.length > 0 && !this.isAvSession()) {
          Column({ space: 6 }) {
            ForEach(this.capabilityWarnings, (warning: string) => {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(14)
                  .fontColor([$r('app.color.warning')])
                Text(warning).fontSize(12).fontColor($r('app.color.warning'))
                  .layoutWeight(1)
              }.width('100%').alignItems(VerticalAlign.Center)
            }, (warning: string) => warning)
          }
          .width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(16).backgroundColor($r('app.color.warning_soft'))
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 240, curve: Curve.Friction }))
        }

          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text(`元数据风险 ${this.visibleMetadataFindings().length} 项`)
                .fontSize(15 * this.tabletUiScale()).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(this.showMetadataDetails ? '收起' : '查看')
              .fontSize(13 * this.tabletUiScale()).fontColor($r('app.color.accent'))
          }.width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.surface'))
            .border({ width: 1.5, color: $r('app.color.surface_outline') })
            .transition(this.resultOptionCardTransition())
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 280, curve: Curve.Friction }, () => {
                this.showMetadataDetails = !this.showMetadataDetails;
              });
            })
          if (this.showMetadataDetails) {
            Column() {
              ForEach(this.visibleMetadataFindings(), (finding: PrivacyFinding) => {
                this.MetadataFindingRow(finding)
              }, (finding: PrivacyFinding) => finding.id +
                (finding.selectedForRemoval ? '-del' : '-keep') +
                (this.isMetadataReplacementSelected(finding) ? '-rep' : ''))
            }.width('100%').padding({ left: 12, right: 12 })
              .borderRadius(16).backgroundColor($r('app.color.surface'))
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
              .transition(this.resultOptionCardTransition())
          }
          if (this.trackedFileKind === FileKind.PDF) {
            this.PdfWatermarkCard()
          }
          if (this.featureMode === FeatureMode.PRIVACY && this.visibleVisualFindings().length > 0 &&
            this.statusNotReady()) {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('推荐保护').fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button('全部打码').height(38).fontSize(13).borderRadius(19)
                .fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft'))
                .onClick(() => this.applyRecommendedProtection())
            }.width('100%').padding(12).borderRadius(16).backgroundColor($r('app.color.surface'))
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
              .transition(this.resultOptionCardTransition())
            Row() {
              Text('需要检查的画面区域').fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_secondary'))
              Blank()
              Text(`${this.visibleVisualFindings().length} 处`).fontSize(13).fontColor($r('app.color.text_secondary'))
            }.width('100%').padding({ left: 4, right: 4 })
            Text('点按图片上的建议框或下方项目选择是否遮盖')
              .fontSize(12).fontColor($r('app.color.text_tertiary'))
              .width('100%').padding({ left: 4, right: 4 })
            if (this.visibleVisualFindings().some((finding: PrivacyFinding) => finding.region !== undefined)) {
              Row() {
                Column({ space: 3 }) {
                  Text('打码方式').fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text('智能推荐会按风险选择强度').fontSize(11).fontColor($r('app.color.text_tertiary'))
                }.alignItems(HorizontalAlign.Start)
                Blank()
                Select([
                  { value: '智能推荐' },
                  { value: '强模糊' },
                  { value: '马赛克' },
                  { value: '纯色遮盖' }
                ])
                  .selected(this.redactionStyleIndex())
                  .value(this.redactionStyleLabel())
                  .font({ size: 13 })
                  .onSelect((index: number) => this.setRedactionStyle(index))
              }
              .width('100%').padding(12).borderRadius(16).backgroundColor($r('app.color.surface'))
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
              .transition(this.resultOptionCardTransition())
            }
            Column() {
              ForEach(this.visibleVisualFindings(), (finding: PrivacyFinding) => {
                this.FindingRow(finding)
              }, (finding: PrivacyFinding) => finding.id +
                (finding.selectedForRemoval ? '-redact' : '-keep'))
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
            .borderRadius(16)
            .backgroundColor($r('app.color.surface'))
            .border({ width: 1.5, color: $r('app.color.surface_outline') })
            .transition(this.resultOptionCardTransition())
          } else if (this.featureMode === FeatureMode.PRIVACY && this.visibleMetadataFindings().length === 0 &&
            this.statusNotReady()) {
            Column({ space: 8 }) {
              Text('✓').fontSize(26).fontColor($r('app.color.accent'))
              Text(this.isAvSession() ?
                '未发现可读取的隐私元数据' :
                '未发现常见隐私风险').fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text(this.isAvSession() ?
                '已完成本地容器检查' :
                '仍可生成全新的干净副本后分享').fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }.width('100%').padding(18).borderRadius(16).backgroundColor($r('app.color.surface'))
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
              .transition(this.resultOptionCardTransition())
          }

        // Reachability spacer: guarantees the last card can scroll above the
        // floating capsule tab bar and the FAB. Horizontal inset lives on the
        // content, not the Scroll, so the scrollbar hugs the device edge.
        if (this.status === PageStatus.RESULT && this.isImageSession()) {
          Column({ space: 10 }) {
            Row() {
              Column({ space: 3 }) {
                Text('水印').fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(this.watermarkApplied ? '水印与隐私清理会一并写入副本' : '开启后为副本叠加水印')
                  .fontSize(11).fontColor($r('app.color.text_tertiary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.watermarkApplied })
                .onChange((value: boolean) => {
                  this.getUIContext().animateTo({ duration: 280, curve: Curve.Friction }, () => {
                    this.watermarkApplied = value;
                  });
                  if (value && this.purposeWatermark.trim().length === 0 &&
                    this.imageWatermarkUri.length === 0) {
                    this.purposeWatermark = this.watermarkSlots[0];
                  }
                })
            }.width('100%')
            if (this.watermarkApplied) {
              Row() {
                Text('文案').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Select([
                  { value: '默认 1' }, { value: '默认 2' }, { value: '默认 3' }, { value: '自定义' }
                ])
                  .selected(this.watermarkCustomMode ? 3 : this.selectedWatermarkSlot)
                  .value(this.watermarkCustomMode ? '自定义' : `默认 ${this.selectedWatermarkSlot + 1}`)
                  .onSelect((index: number) => this.setPurposeWatermark(index))
              }.width('100%')
              if (this.watermarkCustomMode) {
                TextInput({ placeholder: '输入水印文案', text: this.purposeWatermark })
                  .maxLength(40)
                  .onChange((value: string) => this.purposeWatermark = value)
              }
              Row() {
                Text('清晰度').fontSize(13).fontColor($r('app.color.text_secondary'))
                Slider({ value: this.watermarkOpacity * 100, min: 12, max: 55, step: 1 })
                  .layoutWeight(1).selectedColor($r('app.color.accent'))
                  .onChange((value: number) => this.watermarkOpacity = value / 100)
                Text(`${Math.round(this.watermarkOpacity * 100)}%`)
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              }.width('100%')
              Row() {
                Text('角度').fontSize(13).fontColor($r('app.color.text_secondary'))
                Slider({ value: this.watermarkAngle, min: -45, max: 45, step: 3 })
                  .layoutWeight(1).selectedColor($r('app.color.accent'))
                  .onChange((value: number) => this.watermarkAngle = value)
                Text(`${Math.round(this.watermarkAngle)}°`)
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              }.width('100%')
              Row() {
                Text('字号').fontSize(13).fontColor($r('app.color.text_secondary'))
                Slider({ value: this.watermarkScale * 100, min: 70, max: 160, step: 5 })
                  .layoutWeight(1).selectedColor($r('app.color.accent'))
                  .onChange((value: number) => this.watermarkScale = value / 100)
                Text(`${Math.round(this.watermarkScale * 100)}%`)
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              }.width('100%')
              Row() {
                Text('间距').fontSize(13).fontColor($r('app.color.text_secondary'))
                Slider({ value: this.watermarkSpacing * 100, min: 65, max: 180, step: 5 })
                  .layoutWeight(1).selectedColor($r('app.color.accent'))
                  .onChange((value: number) => this.watermarkSpacing = value / 100)
                Text(`${Math.round(this.watermarkSpacing * 100)}%`)
                  .fontSize(12).fontColor($r('app.color.text_tertiary'))
              }.width('100%')
              Row({ space: 10 }) {
                Text('文字颜色').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Stack() {
                  Row().width(28).height(28).borderRadius(14).backgroundColor('#FFFFFF')
                    .border({ width: 1.5, color: $r('app.color.surface_outline') })
                  if (this.watermarkColor === '#FFFFFF') {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([Color.Black])
                  }
                }.width(34).height(34).accessibilityText('白色水印')
                  .onClick(() => this.setWatermarkColorMode(0))
                Stack() {
                  Row().width(28).height(28).borderRadius(14).backgroundColor('#000000')
                    .border({ width: 1, color: $r('app.color.surface_outline') })
                  if (this.watermarkColor === '#000000') {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([Color.White])
                  }
                }.width(34).height(34).accessibilityText('黑色水印')
                  .onClick(() => this.setWatermarkColorMode(1))
                Button({ type: ButtonType.Capsule }) {
                  Row({ space: 7 }) {
                    Row().width(20).height(20).borderRadius(7)
                      .backgroundColor(this.watermarkColor)
                      .border({ width: 1, color: $r('app.color.surface_outline') })
                    Text('更多颜色').fontSize(12).fontColor($r('app.color.accent'))
                  }
                }
                .height(36).padding({ left: 11, right: 11 })
                .backgroundColor($r('app.color.accent_soft'))
                .onClick(() => this.openWatermarkColorPicker())
              }.width('100%')
              Divider().color($r('app.color.progress_track')).margin({ top: 4, bottom: 4 })
              Row({ space: 12 }) {
                if (this.imageWatermarkUri.length > 0) {
                  Image(this.imageWatermarkUri).width(48).height(48).objectFit(ImageFit.Contain)
                    .borderRadius(12).backgroundColor($r('app.color.page_background'))
                }
                Column({ space: 3 }) {
                  Text('图片水印').fontSize(15).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text(this.imageWatermarkUri.length > 0 ? '已导入，可实时预览' : '支持透明 PNG、Logo 或印章')
                    .fontSize(11).fontColor($r('app.color.text_tertiary'))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Button(this.imageWatermarkUri.length > 0 ? '更换' : '选择', { type: ButtonType.Capsule })
                  .height(38).fontSize(13).fontColor($r('app.color.accent'))
                  .backgroundColor($r('app.color.accent_soft'))
                  .onClick(() => this.chooseImageWatermark())
                if (this.imageWatermarkUri.length > 0) {
                  Button('移除', { type: ButtonType.Capsule }).height(38).fontSize(13)
                    .fontColor($r('app.color.warning')).backgroundColor($r('app.color.surface'))
                    .onClick(() => this.removeImageWatermark())
                }
              }.width('100%')
              if (this.imageWatermarkUri.length > 0) {
                Row() {
                  Text('平铺图片').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.imageWatermarkTiled })
                    .onChange((value: boolean) => this.imageWatermarkTiled = value)
                }.width('100%')
                if (!this.imageWatermarkTiled) {
                  Row({ space: 10 }) {
                    Text('位置').fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                    Select([
                      { value: '左上' }, { value: '顶部居中' }, { value: '右上' },
                      { value: '左侧居中' }, { value: '正中央' }, { value: '右侧居中' },
                      { value: '左下' }, { value: '底部居中' }, { value: '右下' }
                    ])
                      .selected(this.imageWatermarkPosition)
                      .value(['左上', '顶部居中', '右上', '左侧居中', '正中央', '右侧居中',
                        '左下', '底部居中', '右下'][this.imageWatermarkPosition])
                      .onSelect((index: number) => this.imageWatermarkPosition = index)
                  }.width('100%')
                }
                Row() {
                  Text('图片透明度').fontSize(13).fontColor($r('app.color.text_secondary'))
                  Slider({ value: this.imageWatermarkOpacity * 100, min: 8, max: 100, step: 1 })
                    .layoutWeight(1).selectedColor($r('app.color.accent'))
                    .onChange((value: number) => this.imageWatermarkOpacity = value / 100)
                  Text(`${Math.round(this.imageWatermarkOpacity * 100)}%`)
                    .fontSize(12).fontColor($r('app.color.text_tertiary'))
                }.width('100%')
                Row() {
                  Text('图片大小').fontSize(13).fontColor($r('app.color.text_secondary'))
                  Slider({ value: this.imageWatermarkScale * 100, min: 8, max: 55, step: 1 })
                    .layoutWeight(1).selectedColor($r('app.color.accent'))
                    .onChange((value: number) => this.imageWatermarkScale = value / 100)
                  Text(`${Math.round(this.imageWatermarkScale * 100)}%`)
                    .fontSize(12).fontColor($r('app.color.text_tertiary'))
                }.width('100%')
                Row() {
                  Text('图片角度').fontSize(13).fontColor($r('app.color.text_secondary'))
                  Slider({ value: this.imageWatermarkAngle, min: -180, max: 180, step: 5 })
                    .layoutWeight(1).selectedColor($r('app.color.accent'))
                    .onChange((value: number) => this.imageWatermarkAngle = value)
                  Text(`${Math.round(this.imageWatermarkAngle)}°`)
                    .fontSize(12).fontColor($r('app.color.text_tertiary'))
                }.width('100%')
                if (!this.imageWatermarkTiled) {
                  Row() {
                    Text('边距').fontSize(13).fontColor($r('app.color.text_secondary'))
                    Slider({ value: this.imageWatermarkMargin * 100, min: 0, max: 12, step: 1 })
                      .layoutWeight(1).selectedColor($r('app.color.accent'))
                      .onChange((value: number) => this.imageWatermarkMargin = value / 100)
                    Text(`${Math.round(this.imageWatermarkMargin * 100)}%`)
                      .fontSize(12).fontColor($r('app.color.text_tertiary'))
                  }.width('100%')
                }
              }
            }
          }.width('100%').padding(18).borderRadius(16).backgroundColor($r('app.color.surface'))
          .border({ width: 1.5, color: $r('app.color.surface_outline') })
          .transition(this.resultOptionCardTransition())
        }

        }
        .width('100%')
        .translate({ x: this.optionsOut ? '120%' : '0%' })
        .opacity(this.optionsOut ? 0 : 1)
        .hitTestBehavior(this.optionsOut ? HitTestMode.None : HitTestMode.Default)
        }
        if (this.statusReady()) {
          Column({ space: 8 }) {
            Text('处理摘要').fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Start)
            if (this.featureMode === FeatureMode.PRIVACY) {
              Row() {
                Text(this.isDocumentSession() ? '文档元数据' : '图片元数据')
                  .fontSize(15).fontColor($r('app.color.text_primary'))
                Blank()
                Text(this.removedEntryCount > 0 ?
                  `已删除 ${this.removedEntryCount} 项` : '已按当前策略处理')
                  .fontSize(13).fontColor($r('app.color.accent'))
              }.width('100%')
              if (this.trackedFileKind === FileKind.IMAGE) {
                Row() {
                  Text('视觉隐私区域').fontSize(15).fontColor($r('app.color.text_primary'))
                  Blank()
                  Text(this.appliedVisualCount > 0 ? `已遮盖 ${this.appliedVisualCount} 处` : '未选择遮盖')
                    .fontSize(13).fontColor($r('app.color.accent'))
                }.width('100%')
              }
            }
            Row() {
              Text('安全副本').fontSize(15).fontColor($r('app.color.text_primary'))
              Blank()
              Text(this.safeCopyDetails()).fontSize(13).fontColor($r('app.color.text_secondary'))
            }.width('100%')
            if (this.purposeWatermark.length > 0) {
              Row() {
                Text('文字水印').fontSize(15).fontColor($r('app.color.text_primary'))
                Blank()
                Text('已写入副本').fontSize(13).fontColor($r('app.color.accent'))
              }.width('100%')
            }
            if (this.imageWatermarkUri.length > 0) {
              Row() {
                Text('图片水印').fontSize(15).fontColor($r('app.color.text_primary'))
                Blank()
                Text(this.imageWatermarkTiled ? '已平铺写入' : '已写入副本')
                  .fontSize(13).fontColor($r('app.color.accent'))
              }.width('100%')
            }
          }.width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.surface'))
            .border({ width: 1.5, color: $r('app.color.surface_outline') })
            .transition(TransitionEffect.OPACITY
              .animation({ duration: 240, curve: Curve.Friction }))
        }
        Blank().height(this.useTwoPaneLayout() ? 24 : 130)
      }
      }
      .padding({ left: 20, right: 20 })
      }
            .width(this.inspectorPaneWidth())
      .margin({ top: this.useTwoPaneLayout() ? 0 : 8 })
      .layoutWeight(this.useTwoPaneLayout() ? 0 : 1)
      .height(this.useTwoPaneLayout() ? '100%' : '100%')
      .padding({ left: this.useTwoPaneLayout() ? 10 : 0 })
      .scrollBar(BarState.Auto)
      // Spring bounce on a plain content list reads as flicker while
      // scrolling repeatedly; clamp to the edge instead.
      .edgeEffect(EdgeEffect.None)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      }
      .align(Alignment.Top)
      if (!this.isAvSession() || this.hasSanitizableFiles()) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.status === PageStatus.READY ? $r('sys.symbol.paperplane_fill') :
            $r('sys.symbol.plus'))
            .fontSize(26)
            .fontColor([$r('app.color.on_accent')])
        }
        .width(56).height(56)
        .backgroundColor($r('app.color.accent'))
        .shadow({ radius: 12, color: $r('app.color.shadow'), offsetY: 4 })
        .margin({ right: 4, bottom: this.useTwoPaneLayout() ? 40 : 24 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 280, curve: Curve.Friction }))
        .accessibilityText(this.status === PageStatus.READY ? '分享副本' : '生成安全副本')
        .onClick(() => {
          if (this.status === PageStatus.READY) {
            this.shareAgain();
          } else {
            this.createSafeCopy();
          }
        })
      }
    }
    .width('100%').height('100%')
    .constraintSize({ maxWidth: this.breakpoint === 'lg' ? 1440 : 1240 })
    .alignSelf(ItemAlign.Center)
    .padding({ top: this.useTwoPaneLayout() ? 8 : 0, bottom: 0 })
    .bindSheet(this.colorPickerVisible, this.WatermarkColorPickerSheet, {
      preferType: SheetType.BOTTOM,
      showClose: false,
      dragBar: true,
      height: Math.max(420, Math.min(560, this.viewportHeight - 32)),
      width: Math.max(280, Math.min(560, this.viewportWidth - 24)),
      radius: LengthMetrics.vp(32),
      maskColor: $r('app.color.sheet_mask'),
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      onDisappear: () => this.colorPickerVisible = false
    })
  }

  @Builder
  PageMap(name: string, param: Object) {
    if (name === 'scan') {
      HdsNavDestination() {
        this.ScanContent()
      }
      .titleBar({
        content: {
          title: {
            mainTitle: this.featureMode === FeatureMode.PRIVACY ? '隐私处理' : '水印'
          }
        },
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: true,
        style: {
          originalStyle: {
            backgroundStyle: { backgroundColor: Color.Transparent },
            contentStyle: {
              titleStyle: {
                // With a transparent bar background the Hds default title color
                // can render white-on-white in light mode; bind it to the
                // theme resource so it follows color mode.
                mainTitleColor: $r('app.color.text_primary')
              },
              backIconStyle: {
                backgroundColor: Color.Transparent,
                iconColor: $r('app.color.text_primary')
              }
            }
          },
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        }
      })
      .hideBackButton(false)
      .onBackPressed(() => {
        this.reset();
        return false;
      })
    }
  }

  build() {
    Stack() {
    HdsNavigation(this.pathStack) {
      HdsTabs({ barPosition: BarPosition.End, controller: this.tabController }) {
        TabContent() {
          this.PhotoHome()
        }
        .tabBar(new BottomTabBarStyle(this.tabSymbol('sys.symbol.picture', 'sys.symbol.picture_fill'),
          '照片'))
        TabContent() {
          this.FilesHome()
        }
        .tabBar(new BottomTabBarStyle(this.tabSymbol('sys.symbol.doc_plaintext',
          'sys.symbol.doc_plaintext_fill'), '文件'))
      }
      .barMode(BarMode.Fixed)
      .barOverlap(true)
      .scrollable(false)
      // Floating capsule bar (API 6.1.0(23)): rounded pill with side/bottom
      // margins, immersive system material, and a gradient mask so content
      // scrolling beneath stays readable.
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: 26,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        gradientMask: {
          maskColor: Color.Transparent,
          maskHeight: 0
        }
      })
      .blurStrategy(BlurStrategy.ADAPTIVE)
      .onTabBarClick((index: number) => this.switchHomeTab(index))
      .onChange((index: number) => this.switchHomeTab(index))
      .width('100%').height('100%')
      .bindSheet(this.showSettingsSheet, this.SettingsSheet, {
        preferType: SheetType.CENTER,
        showClose: false,
        dragBar: false,
        height: Math.max(360, Math.round(this.viewportHeight *
          (this.isLandscapeWindow() ? 0.86 : 0.78))),
        width: Math.max(200, Math.min(520, this.viewportWidth - 24)),
        radius: LengthMetrics.vp(32),
        maskColor: $r('app.color.sheet_mask'),
        blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
        // System back inside the sheet goes UP one settings level (to the
        // menu) instead of dismissing the sheet — matching the in-sheet
        // back arrow; only the menu level lets the sheet close.
        onWillDismiss: (action: DismissSheetAction) => {
          if (action.reason === DismissReason.PRESS_BACK &&
            this.settingsPage !== 'menu') {
            this.animateSettingsTo('menu');
            return;
          }
          action.dismiss();
        },
        onDisappear: () => this.showSettingsSheet = false
      })
    }
    .titleBar({
      content: {
        title: {
          mainTitle: this.homeTitle(),
          subTitle: this.homeTab === HomeTab.FILES ? '清除文件中的隐私元数据' : undefined
        },
        menu: {
          value: [{
            content: {
              icon: $r('sys.symbol.gearshape'),
              label: '默认设置',
              action: () => this.openSettings()
            }
          }],
          maxCount: 1
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
    .hideTitleBar(false)
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
    // The replacement sheet lives on this stable page-level host: the result
    // page rebuilds its subtree whenever findings change, and a rebuild of the
    // previous in-page host tore the sheet down immediately (it flashed and
    // became unusable). Keeping it here — on the Navigation node, separate
    // from the color-picker sheet — makes it stable for photo and document
    // flows alike.
    .bindSheet(this.replacementSheetVisible, this.MetadataReplacementSheet, {
      preferType: SheetType.BOTTOM,
      showClose: false,
      dragBar: true,
      height: 300,
      width: Math.max(200, Math.min(520, this.viewportWidth - 24)),
      radius: LengthMetrics.vp(32),
      maskColor: $r('app.color.sheet_mask'),
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      onDisappear: () => this.replacementSheetVisible = false
    })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      // Rounded to whole vp: sub-pixel jitter on every frame would otherwise
      // re-run layout math (previewHeight/previewScale) across the tree.
      const width: number = Math.round(Number.parseFloat(newValue.width.toString()));
      if (Number.isFinite(width) && width > 0) {
        this.viewportWidth = width;
      }
      const height: number = Math.round(Number.parseFloat(newValue.height.toString()));
      if (Number.isFinite(height) && height > 0) {
        this.viewportHeight = height;
      }
      // Rotation / fold / window resize must update the breakpoint even if
      // the mediaquery change event is missed.
      const next: DeviceBreakpoint = width >= 1440 ? 'lg' : width >= 840 ? 'md' :
        width >= 600 ? 'sm' : 'xs';
      if (next !== this.breakpoint) {
        this.breakpoint = next;
      }
    })
    if (this.showTutorial) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%')
          .backgroundColor($r('app.color.sheet_mask'))
          .opacity(this.tutorialCardVisible ? 1 : 0)
          .animation({ duration: 260, curve: Curve.EaseOut })
        Column() {
          TutorialOverlay({
            sessionId: this.tutorialSessionId,
            onVisibleChange: (): void => this.closeTutorial()
          })
        }
        .width(Math.max(280, Math.min(620, this.viewportWidth - 32)))
        .height(Math.min(720, Math.max(360, this.viewportHeight - 72)))
        .borderRadius(32)
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .border({ width: 1, color: $r('app.color.divider') })
        .shadow({ radius: 28, color: $r('app.color.shadow'), offsetY: 10 })
        .clip(true)
        .opacity(this.tutorialCardVisible ? 1 : 0)
        .translate({ y: this.tutorialCardVisible ? 0 : 72 })
        .scale({ x: this.tutorialCardVisible ? 1 : 0.97, y: this.tutorialCardVisible ? 1 : 0.97 })
        .animation({ duration: 420, curve: Curve.Friction })
      }
      .width('100%').height('100%').zIndex(100)
    }
  }

  }
}

