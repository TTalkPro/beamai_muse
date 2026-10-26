"""Unit tests of files.py's changed_since walk, run on a temporary directory
(not in OpenMuse; `python3 -I computer/tests/test_files.py`, also run by
muse_integ's eunit suite muse_files_py_tests). The /workspace protocol
itself is covered by muse_computer_SUITE with Docker."""
import importlib.util
import os
import sys
import tempfile
import time
import unittest

# never leave a __pycache__ next to files.py (the image's build context)
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("files", os.path.join(HERE, "..", "files.py"))
files = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(files)


def write(root, relative, data=b"x", mtime=None):
    path = os.path.join(root, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as target:
        target.write(data)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


class ChangedSince(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.fd = os.open(self.root, files.DIRECTORY_FLAGS)
        self.since = int(time.time() * 1000) - 1000

    def tearDown(self):
        os.close(self.fd)
        self.tmp.cleanup()

    def scan(self, limit=50, max_bytes=1024, depth=8):
        return files.changed_since(self.fd, "/workspace", self.since, limit, max_bytes, depth)

    def paths(self, result):
        return [entry["path"] for entry in result["files"]]

    def test_changed_files_only(self):
        write(self.root, "old.txt", mtime=time.time() - 3600)
        write(self.root, "new.txt", b"hello")
        write(self.root, "out/chart.png")
        result = self.scan()
        self.assertEqual(["/workspace/new.txt", "/workspace/out/chart.png"], self.paths(result))
        self.assertEqual(5, result["files"][0]["size"])
        self.assertGreaterEqual(result["files"][0]["mtime"], self.since)
        self.assertFalse(result["truncated"])

    def test_noise_is_skipped(self):
        for noise in [".hidden", ".venv/lib/a.py", ".cache/x", "node_modules/p/index.js",
                      "__pycache__/m.cpython.pyc", "venv/bin/python", "pkg/site-packages/m.py",
                      "m.pyc", ".openmuse-123"]:
            write(self.root, noise)
        write(self.root, "keep.py")
        self.assertEqual(["/workspace/keep.py"], self.paths(self.scan()))

    def test_symlinks_are_not_followed(self):
        outside = tempfile.TemporaryDirectory()
        write(outside.name, "secret.txt")
        os.symlink(outside.name, os.path.join(self.root, "link"))
        os.symlink(os.path.join(outside.name, "secret.txt"), os.path.join(self.root, "file-link"))
        write(self.root, "real.txt")
        self.assertEqual(["/workspace/real.txt"], self.paths(self.scan()))
        outside.cleanup()

    def test_caps(self):
        for index in range(5):
            write(self.root, "f%d.txt" % index)
        result = self.scan(limit=3)
        self.assertEqual(3, len(result["files"]))
        self.assertTrue(result["truncated"])
        write(self.root, "big.bin", b"x" * 2048)
        result = self.scan(max_bytes=1024)
        self.assertNotIn("/workspace/big.bin", self.paths(result))
        self.assertEqual([{"path": "/workspace/big.bin", "size": 2048, "reason": "too_large"}], result["skipped"])
        write(self.root, "a/b/c/deep.txt")
        self.assertNotIn("/workspace/a/b/c/deep.txt", self.paths(self.scan(depth=3)))
        self.assertIn("/workspace/a/b/c/deep.txt", self.paths(self.scan(depth=4)))


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    sys.exit(0 if result.wasSuccessful() else 1)
