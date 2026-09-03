#!/usr/bin/env python3
"""Generate the deterministic 1024x1024 RemoteAI AppIcon using stdlib only."""
from __future__ import annotations

import binascii
import pathlib
import struct
import sys
import zlib

SIZE = 1024
BG = (18, 24, 38)
RING_1 = (25, 39, 62)
RING_2 = (31, 51, 79)
RING_3 = (38, 64, 98)
LIGHT = (244, 247, 251)


def inside_circle(x: int, y: int, cx: int, cy: int, radius: int) -> bool:
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= radius * radius


def inside_round_rect(x: int, y: int, left: int, top: int, right: int, bottom: int, radius: int) -> bool:
    if left + radius <= x <= right - radius and top <= y <= bottom:
        return True
    if left <= x <= right and top + radius <= y <= bottom - radius:
        return True
    cx = left + radius if x < left + radius else right - radius
    cy = top + radius if y < top + radius else bottom - radius
    return inside_circle(x, y, cx, cy, radius)


def pixel(x: int, y: int) -> tuple[int, int, int]:
    color = BG
    if inside_circle(x, y, 512, 512, 390):
        color = RING_1
    if inside_circle(x, y, 512, 512, 315):
        color = RING_2
    if inside_circle(x, y, 512, 512, 240):
        color = RING_3
    if inside_round_rect(x, y, 245, 245, 779, 779, 120):
        color = LIGHT
    if inside_round_rect(x, y, 320, 335, 704, 630, 70):
        color = BG
    for line_y, width in ((405, 245), (475, 190), (545, 265)):
        if inside_round_rect(x, y, 375, line_y, 375 + width, line_y + 28, 14):
            color = LIGHT
    if 399 <= x <= 478 and 688 <= y <= 712:
        color = BG
    if 546 <= x <= 625 and 688 <= y <= 712:
        color = BG
    for node_x in (365, 512, 659):
        if inside_circle(x, y, node_x, 700, 34):
            color = BG
    return color


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)


def render_png() -> bytes:
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)  # PNG filter: None
        for x in range(SIZE):
            rows.extend(pixel(x, y))
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_app_icon.py <output.png>")
    output = pathlib.Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    data = render_png()
    output.write_bytes(data)
    if len(data) < 1000:
        raise SystemExit("generated AppIcon is unexpectedly small")
    print(f"generated_app_icon={output} bytes={len(data)}")


if __name__ == "__main__":
    main()
