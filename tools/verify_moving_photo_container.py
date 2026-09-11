#!/usr/bin/env python3
"""Host-side instance check for SafeShare MovingPhoto container logic.

Mirrors entry/src/main/ets/processors/MovingPhotoContainer.ets so composite
JPEG+ISO-BMFF samples can be verified without a simulator. Real-device
install/share still requires a connected handset.
"""
from __future__ import annotations

from pathlib import Path


def ascii_bytes(value: str) -> bytes:
    return value.encode("ascii")


def u32(value: int) -> bytes:
    return value.to_bytes(4, "big")


def box(kind: str, payload: bytes) -> bytes:
    return u32(len(payload) + 8) + ascii_bytes(kind) + payload


def jpeg_with_xmp(xmp: str, scan_payload: bytes) -> bytes:
    payload = b"http://ns.adobe.com/xap/1.0/\x00" + ascii_bytes(xmp)
    app1 = b"\xFF\xE1" + (len(payload) + 2).to_bytes(2, "big") + payload
    scan = b"\xFF\xDA" + (8).to_bytes(2, "big") + b"\x01\x01\x00\x00\x3F\x00" + scan_payload + b"\xFF\xD9"
    return b"\xFF\xD8" + app1 + scan


def minimal_mp4(extra: bytes = b"privacy-location+31.2+121.5/") -> bytes:
    ftyp = box("ftyp", ascii_bytes("isom") + b"\x00\x00\x00\x00" + ascii_bytes("isom"))
    free = box("free", extra)
    moov = box("moov", box("mvhd", b"\x00\x00\x00\x00" + b"\x00" * 96))
    return ftyp + free + moov


def is_iso_bmff_at(data: bytes, start: int) -> bool:
    if start < 0 or start + 12 > len(data):
        return False
    return data[start + 4:start + 8] == b"ftyp"


def jpeg_still_end(data: bytes) -> int:
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return 0
    cursor = 2
    while cursor + 1 < len(data):
        if data[cursor] != 0xFF:
            return 0
        while cursor < len(data) and data[cursor] == 0xFF:
            cursor += 1
        if cursor >= len(data):
            return 0
        marker = data[cursor]
        cursor += 1
        if marker == 0xD9:
            return cursor
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if marker == 0xDA:
            index = cursor
            while index + 1 < len(data):
                if data[index] == 0xFF and data[index + 1] == 0xD9:
                    return index + 2
                index += 1
            return 0
        if cursor + 2 > len(data):
            return 0
        segment_length = int.from_bytes(data[cursor:cursor + 2], "big")
        if segment_length < 2 or cursor + segment_length > len(data):
            return 0
        cursor += segment_length
    return 0


def inspect(data: bytes) -> dict:
    jpeg_end = jpeg_still_end(data)
    if jpeg_end <= 0:
        return {"is_composite": False, "reason": "not-jpeg-still"}
    # ISO-BMFF box sizes are big-endian and often begin with 0x00. Do not skip zeros.
    if not is_iso_bmff_at(data, jpeg_end):
        return {"is_composite": False, "reason": "trailing-not-isobmff", "image_end": jpeg_end}
    return {
        "is_composite": True,
        "image_end": jpeg_end,
        "video_start": jpeg_end,
        "video_length": len(data) - jpeg_end,
        "reason": "jpeg+isobmff",
    }


def main() -> int:
    jpeg = jpeg_with_xmp(
        'GCamera:MicroVideo="1" exif:DateTimeOriginal="2026:01:02 03:04:05" '
        "HwMotionPhoto:MotionPhoto=1",
        b"\x11\x22\x33",
    )
    video = minimal_mp4()
    composite = jpeg + video
    layout = inspect(composite)
    assert layout["is_composite"] is True, layout
    assert layout["image_end"] == len(jpeg), layout
    assert layout["video_start"] == len(jpeg), layout
    assert layout["video_length"] == len(video), layout
    assert is_iso_bmff_at(composite, layout["video_start"]) is True

    still = jpeg_with_xmp('GCamera:MicroVideo="1"', b"\x44")
    still_layout = inspect(still)
    assert still_layout["is_composite"] is False, still_layout

    garbage = jpeg + bytes(range(1, 13))
    garbage_layout = inspect(garbage)
    assert garbage_layout["is_composite"] is False, garbage_layout

    # Compose path: cleaned cover + new video must refresh MicroVideoOffset.
    cover_with_old_offset = jpeg_with_xmp(
        'GCamera:MicroVideo="1" GCamera:MicroVideoOffset="0040"',
        b"\x21",
    )
    new_video = minimal_mp4(bytes(range(1, 9)))
    # Offset rewrite is same APP1 surgery as MovingPhotoContainer.ensureMotionXmp.
    payload_prefix = b"http://ns.adobe.com/xap/1.0/\x00"
    key = b"MicroVideoOffset"
    key_at = cover_with_old_offset.find(key)
    assert key_at > 0
    value_start = cover_with_old_offset.find(b'"', key_at) + 1
    value_end = cover_with_old_offset.find(b'"', value_start)
    new_offset = str(len(new_video)).encode("ascii")
    rebuilt_payload = cover_with_old_offset
    # Locate APP1 payload bounds roughly via SOI + marker walk for this tiny sample.
    # APP1 starts at offset 2; length field at offset 4.
    app1_len = int.from_bytes(cover_with_old_offset[4:6], "big")
    app1_end = 4 + app1_len  # exclusive end of APP1 segment from offset 2
    # Rebuild APP1 with replaced offset digits.
    old_payload = cover_with_old_offset[6:app1_end]
    rel = value_start - 6
    rel_end = value_end - 6
    next_payload = old_payload[:rel] + new_offset + old_payload[rel_end:]
    next_len = len(next_payload) + 2
    app1 = b"\xFF\xE1" + next_len.to_bytes(2, "big") + next_payload
    next_cover = b"\xFF\xD8" + app1 + cover_with_old_offset[app1_end:]
    composed = next_cover + new_video
    composed_layout = inspect(composed)
    assert composed_layout["is_composite"] is True, composed_layout
    assert composed_layout["video_length"] == len(new_video), composed_layout
    assert f'GCamera:MicroVideoOffset="{len(new_video)}"'.encode("ascii") in composed

    out_dir = Path("/Users/macalan/Documents/SafeShare/tools/test-assets")
    out_dir.mkdir(parents=True, exist_ok=True)
    sample = out_dir / "huawei_motion_photo_sample.jpg"
    sample.write_bytes(composite)
    cover = out_dir / "huawei_motion_photo_cover.jpg"
    cover.write_bytes(jpeg)
    clip = out_dir / "huawei_motion_photo_video.mp4"
    clip.write_bytes(video)
    composed_sample = out_dir / "huawei_motion_photo_composed.jpg"
    composed_sample.write_bytes(composed)
    print("PASS MovingPhotoContainer host checks")
    print(f"sample={sample} bytes={sample.stat().st_size}")
    print(f"cover={cover} bytes={cover.stat().st_size}")
    print(f"video={clip} bytes={clip.stat().st_size}")
    print(f"composed={composed_sample} bytes={composed_sample.stat().st_size}")
    print(f"layout={layout}")
    print(f"composed_layout={composed_layout}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
