import { image } from '@kit.ImageKit';

export enum RiskLevel {
  LOW = 'LOW',
  MEDIUM = 'MEDIUM',
  HIGH = 'HIGH'
}

export enum FindingCategory {
  METADATA = 'METADATA',
  FACE = 'FACE',
  TEXT = 'TEXT',
  QR = 'QR',
  MANUAL = 'MANUAL',
  OBJECT = 'OBJECT'
}

export enum RedactionStyle {
  AUTO = 'AUTO',
  BLUR = 'BLUR',
  PIXELATE = 'PIXELATE',
  SOLID = 'SOLID'
}

export class SensitiveRegion {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;

  constructor(left: number, top: number, width: number, height: number) {
    this.left = left;
    this.top = top;
    this.width = width;
    this.height = height;
  }
}

export class RedactionAction {
  region: SensitiveRegion;
  style: RedactionStyle;
  category: FindingCategory;
  subtype: string;

  constructor(region: SensitiveRegion, style: RedactionStyle,
    category: FindingCategory = FindingCategory.TEXT, subtype: string = '') {
    this.region = region;
    this.style = style;
    this.category = category;
    this.subtype = subtype;
  }
}

export class PrivacyFinding {
  id: string = '';
  category: FindingCategory = FindingCategory.METADATA;
  subtype: string = '';
  risk: RiskLevel = RiskLevel.LOW;
  title: string = '';
  description: string = '';
  recommendation: string = '';
  selectedForRemoval: boolean = false;
  rawValue: string = '';
  replacementValue: string = '';
  region: SensitiveRegion | undefined = undefined;
  sourceIndex: number = 0;

  constructor(id: string, subtype: string, risk: RiskLevel, title: string,
    description: string, recommendation: string, selectedForRemoval: boolean, rawValue: string) {
    this.id = id;
    this.subtype = subtype;
    this.risk = risk;
    this.title = title;
    this.description = description;
    this.recommendation = recommendation;
    this.selectedForRemoval = selectedForRemoval;
    this.rawValue = rawValue;
  }
}

export class PrivacyScanResult {
  uri: string = '';
  findings: PrivacyFinding[] = [];
  scannedAt: number = 0;
  capabilityWarnings: string[] = [];
  pixelWidth: number = 0;
  pixelHeight: number = 0;
  fileKind: string = 'IMAGE';
  readOnlyTool: boolean = false;
  scanFailed: boolean = false;
  mimeType: string = '';
  // Video previews are decoded by the media service, never by the image
  // privacy/redaction pipeline. The page only renders this system PixelMap.
  previewPixelMap: image.PixelMap | undefined = undefined;

  constructor(uri: string, findings: PrivacyFinding[]) {
    this.uri = uri;
    this.findings = findings;
    this.scannedAt = Date.now();
  }
}

export class SanitizedFile {
  path: string = '';
  uri: string = '';
  verification: PrivacyScanResult = new PrivacyScanResult('', []);
  utd: string = 'general.jpeg';
  mimeType: string = 'image/jpeg';
  pixelWidth: number = 0;
  pixelHeight: number = 0;
  byteSize: number = 0;
  fileKind: string = 'IMAGE';
  sourceIndex: number = -1;

  constructor(path: string, uri: string, verification: PrivacyScanResult,
    utd: string = 'general.jpeg', mimeType: string = 'image/jpeg') {
    this.path = path;
    this.uri = uri;
    this.verification = verification;
    this.utd = utd;
    this.mimeType = mimeType;
  }
}
