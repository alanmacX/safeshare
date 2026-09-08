export interface RemuxResult {
  trackCount: number;
  videoTrackCount: number;
  sampleCount: number;
}

/**
 * Copies encoded tracks into a new MP4 container. File descriptors stay
 * owned by ArkTS and must remain open until the promise settles.
 */
export const remuxToMp4: (inputFd: number, inputLength: number,
  outputFd: number) => Promise<RemuxResult>;
