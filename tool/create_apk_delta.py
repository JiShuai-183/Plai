"""Create plai-bsdiff-gzip-v1 from trusted release APKs.

Install tool/requirements-delta.txt in an isolated build environment first.
The generator uses bsdiff4's mature BSDIFF40 implementation, retaining its exact
control/diff/extra bytes and replacing the three bzip2 streams with gzip. Build
hosts need memory for bsdiff's suffix-array algorithm; mobile application is
streamed by lib/services/app_update/apk_delta.dart.
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import hashlib
import json
import os
from pathlib import Path
import tempfile

ALGORITHM = "plai-bsdiff-gzip-v1"
MAGIC = b"PLDIFF01"
MAX_TARGET_SIZE = 512 * 1024 * 1024


def decode_int(data: bytes) -> int:
    if len(data) != 8:
        raise ValueError("truncated signed-magnitude integer")
    value = int.from_bytes(data, "little")
    magnitude = value & ((1 << 63) - 1)
    return -magnitude if value >> 63 else magnitude


def encode_int(value: int) -> bytes:
    if abs(value) >= 1 << 63:
        raise ValueError("integer exceeds BSDIFF range")
    return (abs(value) | ((1 << 63) if value < 0 else 0)).to_bytes(8, "little")


def unpack(data: bytes, magic: bytes) -> tuple[int, int, int]:
    if len(data) < 32 or data[:8] != magic:
        raise ValueError("invalid patch header")
    control, diff, size = (decode_int(data[i:i + 8]) for i in (8, 16, 24))
    if min(control, diff, size) < 0 or control + diff > len(data) - 32:
        raise ValueError("invalid patch block sizes")
    return control, diff, size


def transcode(patch: bytes) -> bytes:
    """Preserve BSDIFF instructions; use reproducible minimal gzip headers."""
    control, diff, size = unpack(patch, b"BSDIFF40")
    raw = (
        patch[32:32 + control],
        patch[32 + control:32 + control + diff],
        patch[32 + control + diff:],
    )
    blocks = [gzip.compress(bz2.decompress(block), compresslevel=9, mtime=0)
              for block in raw]
    return (MAGIC + encode_int(len(blocks[0])) + encode_int(len(blocks[1]))
            + encode_int(size) + b"".join(blocks))


def apply_for_verification(old: bytes, patch: bytes) -> bytes:
    """Independent reference bspatch for generator verification/tests only."""
    control_size, diff_size, target_size = unpack(patch, MAGIC)
    if target_size > MAX_TARGET_SIZE:
        raise ValueError("target exceeds limit")
    control = gzip.decompress(patch[32:32 + control_size])
    diff = gzip.decompress(patch[32 + control_size:32 + control_size + diff_size])
    extra = gzip.decompress(patch[32 + control_size + diff_size:])
    if len(control) % 24:
        raise ValueError("truncated control tuple")
    result = bytearray()
    old_pos = diff_pos = extra_pos = 0
    for i in range(0, len(control), 24):
        add, copy, seek = (decode_int(control[j:j + 8])
                           for j in (i, i + 8, i + 16))
        if min(add, copy) < 0 or add + copy > target_size - len(result):
            raise ValueError("invalid control tuple lengths")
        if add > len(diff) - diff_pos or copy > len(extra) - extra_pos:
            raise ValueError("truncated data stream")
        for j in range(add):
            source = old[old_pos + j] if 0 <= old_pos + j < len(old) else 0
            result.append((diff[diff_pos + j] + source) & 255)
        diff_pos += add
        result.extend(extra[extra_pos:extra_pos + copy])
        extra_pos += copy
        old_pos += add + seek
    if len(result) != target_size or diff_pos != len(diff) or extra_pos != len(extra):
        raise ValueError("unused/truncated patch data")
    return bytes(result)


def create_delta(old_path: Path, new_path: Path, output: Path, verify: bool = False) -> dict:
    import bsdiff4

    old_path, new_path, output = (Path(p).resolve() for p in (old_path, new_path, output))
    metadata_path = Path(str(output) + ".json")
    if output in (old_path, new_path) or output.exists() or metadata_path.exists():
        raise ValueError("output/metadata must be new files distinct from both inputs")
    if not 0 <= new_path.stat().st_size <= MAX_TARGET_SIZE:
        raise ValueError("target APK exceeds 512 MiB")
    old, new = old_path.read_bytes(), new_path.read_bytes()
    patch = transcode(bsdiff4.diff(old, new))
    if verify and apply_for_verification(old, patch) != new:
        raise ValueError("delta reconstruction does not equal the complete target APK")
    sha = lambda value: hashlib.sha256(value).hexdigest()
    metadata = {
        "algorithm": ALGORITHM,
        "baseSize": len(old), "baseSha256": sha(old),
        "targetSize": len(new), "targetSha256": sha(new),
        "patchSize": len(patch), "patchSha256": sha(patch),
    }
    temporary = []
    created = []
    try:
        for destination, data in (
            (output, patch),
            (metadata_path, (json.dumps(metadata, indent=2) + "\n").encode("utf-8")),
        ):
            with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as file:
                temporary.append(Path(file.name))
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            # Refuse overwriting inputs or an existing release asset.
            with destination.open("xb") as file:
                created.append(destination)
                with temporary[-1].open("rb") as source:
                    while chunk := source.read(1024 * 1024):
                        file.write(chunk)
        return metadata
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old", required=True, type=Path)
    parser.add_argument("--new", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        metadata = create_delta(args.old, args.new, args.output, args.verify)
    except (OSError, ValueError, ImportError) as error:
        parser.exit(1, f"Delta generation failed: {error}\n")
    print(json.dumps(metadata))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
