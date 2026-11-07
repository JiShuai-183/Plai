import base64
import bz2
import gzip
import hashlib
import json
from pathlib import Path
import random
import tempfile
import unittest
from unittest import mock

import bsdiff4
import create_apk_delta as delta


class DeltaTests(unittest.TestCase):
    def test_signed_magnitude(self):
        for value in (0, 1, -1, 257, -257, (1 << 63) - 1, -((1 << 63) - 1)):
            self.assertEqual(delta.decode_int(delta.encode_int(value)), value)
        self.assertEqual(delta.encode_int(-1), b"\x01\0\0\0\0\0\0\x80")
        with self.assertRaises(ValueError):
            delta.encode_int(1 << 63)

    def test_real_bsdiff_cross_roundtrip(self):
        rng = random.Random(42)
        old = rng.randbytes(200000)
        new = old[90000:] + b"new bytes" * 6000 + old[:70000]
        patch = delta.transcode(bsdiff4.diff(old, new))
        self.assertEqual(delta.apply_for_verification(old, patch), new)

    def test_empty_and_identity(self):
        for old, new in ((b"", b""), (b"old", b""), (b"", b"new"), (b"same", b"same")):
            patch = delta.transcode(bsdiff4.diff(old, new))
            self.assertEqual(delta.apply_for_verification(old, patch), new)

    def test_transcode_preserves_exact_bsdiff_blocks(self):
        source = bsdiff4.diff(b"abc" * 100, b"def" + b"abc" * 99)
        patch = delta.transcode(source)
        bc, bd, size = delta.unpack(source, b"BSDIFF40")
        pc, pd, target = delta.unpack(patch, delta.MAGIC)
        self.assertEqual(size, target)
        for a, b in zip((source[32:32 + bc], source[32 + bc:32 + bc + bd], source[32 + bc + bd:]),
                        (patch[32:32 + pc], patch[32 + pc:32 + pc + pd], patch[32 + pc + pd:])):
            self.assertEqual(bz2.decompress(a), gzip.decompress(b))
            self.assertEqual(b[:4], b"\x1f\x8b\x08\x00")

    def test_cli_contract_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new, output = (Path(tmp) / name for name in ("old", "new", "update.patch"))
            old.write_bytes(b"abc" * 500)
            new.write_bytes(b"abc" * 400 + b"new!")
            meta = delta.create_delta(old, new, output, verify=True)
            self.assertEqual(meta, json.loads(Path(str(output) + ".json").read_text()))
            self.assertEqual(meta["patchSha256"], hashlib.sha256(output.read_bytes()).hexdigest())
            self.assertEqual(meta["targetSha256"], hashlib.sha256(new.read_bytes()).hexdigest())
            with self.assertRaises(ValueError):
                delta.create_delta(old, new, output, True)
            with self.assertRaises(ValueError):
                delta.create_delta(old, new, old, True)
            self.assertEqual(old.read_bytes(), b"abc" * 500)

    def test_verify_failure_leaves_no_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new, output = (Path(tmp) / name for name in ("old", "new", "patch"))
            old.write_bytes(b"old")
            new.write_bytes(b"new")
            with mock.patch.object(delta, "apply_for_verification", return_value=b"wrong"):
                with self.assertRaises(ValueError):
                    delta.create_delta(old, new, output, True)
            self.assertFalse(output.exists())
            self.assertFalse(Path(str(output) + ".json").exists())

    def test_malformed_and_truncated_patch(self):
        patch = delta.transcode(bsdiff4.diff(b"base", b"target"))
        for value in (b"", b"x" * 32, patch[:25], patch[:-3]):
            with self.assertRaises((ValueError, EOFError, OSError)):
                delta.apply_for_verification(b"base", value)


if __name__ == "__main__":
    unittest.main()
