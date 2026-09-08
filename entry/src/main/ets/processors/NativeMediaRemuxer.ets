import { fileIo } from '@kit.CoreFileKit';
import { remuxToMp4 } from 'libremuxer.so';

export class NativeRemuxResult {
  trackCount: number = 0;
  videoTrackCount: number = 0;
  sampleCount: number = 0;
}

export class NativeMediaRemuxer {
  static async remuxToMp4(input: fileIo.File, inputLength: number,
    output: fileIo.File): Promise<NativeRemuxResult> {
    return await remuxToMp4(input.fd, inputLength, output.fd);
  }
}
