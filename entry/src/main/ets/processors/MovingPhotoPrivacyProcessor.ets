import { common } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { FindingCategory, PrivacyFinding, PrivacyScanResult, RedactionAction, SanitizedFile } from '../models/PrivacyModels';
import { MetadataPolicy } from '../metadata/MetadataPolicy';
import { MetadataScanner } from '../metadata/MetadataScanner';
import { MetadataSanitizer } from '../metadata/MetadataSanitizer';
import { TempFileManager } from '../storage/TempFileManager';
import { AvPrivacyTool } from './AvPrivacyProcessor';

/** Dedicated image+video pipeline for picker-authorized MovingPhoto assets. */
export class MovingPhotoPrivacyTool {
  private context: common.UIAbilityContext;
  private tempFiles: TempFileManager;
  private imageScanner: MetadataScanner = new MetadataScanner();
  private imageSanitizer: MetadataSanitizer;
  private videoTool: AvPrivacyTool;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.tempFiles = new TempFileManager(context);
    this.imageSanitizer = new MetadataSanitizer(context);
    this.videoTool = new AvPrivacyTool(context);
  }

  async isMovingPhoto(uri: string): Promise<boolean> {
    const asset: photoAccessHelper.PhotoAsset | undefined = await this.assetForUri(uri);
    if (asset === undefined) return false;
    try {
      return Number(asset.get(photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE)) ===
        photoAccessHelper.PhotoSubtype.MOVING_PHOTO;
    } catch (_) {
      return false;
    }
  }

  async scan(uri: string): Promise<PrivacyScanResult> {
    const exported: string[] = await this.exportComponents(uri);
    try {
      const imageResult: PrivacyScanResult = await this.imageScanner.scan(fileUri.getUriFromPath(exported[0]));
      const videoResult: PrivacyScanResult = await this.videoTool.scan(fileUri.getUriFromPath(exported[1]));
      const findings: PrivacyFinding[] = [];
      this.appendFindings(findings, imageResult.findings, 'moving-image-');
      this.appendFindings(findings, videoResult.findings, 'moving-video-');
      const result: PrivacyScanResult = new PrivacyScanResult(uri, findings);
      result.mimeType = 'application/x-harmony-moving-photo';
      result.pixelWidth = imageResult.pixelWidth;
      result.pixelHeight = imageResult.pixelHeight;
      result.isMovingPhoto = true;
      result.visualEditsSupported = false;
      result.capabilityWarnings = ['动态照片已分别检查封面和视频；当前只支持 metadata，不执行水印、人脸或二维码处理'];
      return result;
    } finally {
      await this.removeAll(exported);
    }
  }

  async sanitize(uri: string, actions: RedactionAction[], policy: MetadataPolicy): Promise<SanitizedFile> {
    if (actions.length > 0 || policy.purposeWatermark.trim().length > 0 || policy.imageWatermarkUri.length > 0) {
      throw new Error('MOVING_PHOTO_VISUAL_EDIT_UNSUPPORTED');
    }
    const exported: string[] = await this.exportComponents(uri);
    let imageFile: SanitizedFile | undefined = undefined;
    let videoFile: SanitizedFile | undefined = undefined;
    try {
      imageFile = await this.imageSanitizer.sanitize(fileUri.getUriFromPath(exported[0]), [], policy);
      // loadMovingPhoto creates the local association from these two sandbox
      // resources. Copy only encoded audio/video tracks into a fresh MP4:
      // this preserves playback without carrying source container metadata
      // or depending on vendor-private metadata tracks.
      videoFile = await this.videoTool.sanitize(fileUri.getUriFromPath(exported[1]), true);
      const localMovingPhoto: photoAccessHelper.MovingPhoto =
        await photoAccessHelper.MediaAssetManager.loadMovingPhoto(this.context, imageFile.uri, videoFile.uri);
      const verification: PrivacyScanResult = new PrivacyScanResult('', []);
      this.appendFindings(verification.findings, imageFile.verification.findings, 'moving-image-');
      this.appendFindings(verification.findings, videoFile.verification.findings, 'moving-video-');
      if (verification.findings.length > 0) throw new Error('MOVING_PHOTO_METADATA_REMAINS');
      const result = new SanitizedFile(imageFile.path, localMovingPhoto.getUri(), verification,
        'openharmony.moving-photo', 'application/x-harmony-moving-photo');
      result.fileKind = 'IMAGE';
      result.isMovingPhoto = true;
      result.movingPhotoRef = localMovingPhoto;
      result.cleanupPaths = [imageFile.path, videoFile.path];
      result.byteSize = imageFile.byteSize + videoFile.byteSize;
      return result;
    } catch (error) {
      if (imageFile !== undefined) await this.tempFiles.remove(imageFile.path);
      if (videoFile !== undefined) await this.tempFiles.remove(videoFile.path);
      throw error as Error;
    } finally {
      await this.removeAll(exported);
    }
  }

  private async exportComponents(uri: string): Promise<string[]> {
    const asset: photoAccessHelper.PhotoAsset | undefined = await this.assetForUri(uri);
    if (asset === undefined || Number(asset.get(photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE)) !==
      photoAccessHelper.PhotoSubtype.MOVING_PHOTO) throw new Error('MOVING_PHOTO_ASSET_UNAVAILABLE');
    const movingPhoto: photoAccessHelper.MovingPhoto = await this.requestMovingPhoto(asset);
    const imagePath: string = this.tempFiles.createPath('moving-image');
    const videoPath: string = this.tempFiles.createPath('moving-video');
    try {
      await movingPhoto.requestContent(fileUri.getUriFromPath(imagePath), fileUri.getUriFromPath(videoPath));
      return [imagePath, videoPath];
    } catch (error) {
      await this.removeAll([imagePath, videoPath]);
      throw error as Error;
    }
  }

  private async assetForUri(uri: string): Promise<photoAccessHelper.PhotoAsset | undefined> {
    let result: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> | undefined = undefined;
    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const predicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
      // PHOTO_SUBTYPE is not a guaranteed default column. Request it
      // explicitly or picker/share URIs may be misclassified as still images.
      result = await helper.getAssets({
        fetchColumns: [photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE], predicates: predicates
      });
      if (result.getCount() <= 0) return undefined;
      return await result.getFirstObject();
    } catch (_) {
      return undefined;
    } finally {
      try { if (result !== undefined) result.close(); } catch (_) {}
    }
  }

  private requestMovingPhoto(asset: photoAccessHelper.PhotoAsset): Promise<photoAccessHelper.MovingPhoto> {
    return new Promise((resolve: (value: photoAccessHelper.MovingPhoto) => void,
      reject: (reason?: Error) => void): void => {
      // MediaAssetManager invokes the callback as a plain native function;
      // class methods therefore receive no bound `this`. Capture resolve in
      // an arrow closure so callback dispatch can never dereference an
      // undefined handler instance (the previous implementation crashed).
      const handler: photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> = {
        onDataPrepared: (data: photoAccessHelper.MovingPhoto): void => resolve(data)
      };
      photoAccessHelper.MediaAssetManager.requestMovingPhoto(this.context, asset,
        { deliveryMode: photoAccessHelper.DeliveryMode.HIGH_QUALITY_MODE }, handler)
        .catch((): void => reject(new Error('MOVING_PHOTO_REQUEST_FAILED')));
    });
  }

  private appendFindings(target: PrivacyFinding[], source: PrivacyFinding[], prefix: string): void {
    for (let index: number = 0; index < source.length; index++) {
      source[index].id = `${prefix}${source[index].id}`;
      source[index].category = FindingCategory.METADATA;
      target.push(source[index]);
    }
  }

  private async removeAll(paths: string[]): Promise<void> {
    for (let index: number = 0; index < paths.length; index++) await this.tempFiles.remove(paths[index]);
  }
}
