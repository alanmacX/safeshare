import { taskpool } from '@kit.ArkTS';
import { RedactionPixels } from './RedactionPixels';

/**
 * Off-main-thread redaction. The per-pixel blur/pixelate loops are pure
 * Uint8Array math but cost seconds on full-resolution regions (THREAD_BLOCK_6S
 * appfreeze on device); running them in a taskpool worker keeps the UI thread
 * responsive. The worker returns a fresh buffer which the caller writes back
 * into the pixel map.
 */
@Concurrent
function applyRedactionBuffer(buffer: ArrayBuffer, stride: number, width: number,
  height: number, style: number): ArrayBuffer {
  const pixels: Uint8Array = new Uint8Array(buffer);
  if (style === 1) {
    RedactionPixels.applyPixelate(pixels, stride, 0, 0, width, height);
  } else if (style === 2) {
    RedactionPixels.applyBlur(pixels, stride, 0, 0, width, height);
  } else {
    RedactionPixels.applySolidCover(pixels, stride, 0, 0, width, height);
  }
  return pixels.buffer as ArrayBuffer;
}

export function runRedaction(buffer: ArrayBuffer, stride: number, width: number,
  height: number, style: number): Promise<ArrayBuffer> {
  const task: taskpool.Task = new taskpool.Task(applyRedactionBuffer,
    buffer, stride, width, height, style);
  // Keep the buffer cloned (not transferred): the caller no longer needs the
  // original, but cloning avoids any detached-ArrayBuffer surprises.
  task.setTransferList([]);
  return taskpool.execute(task) as Promise<ArrayBuffer>;
}
