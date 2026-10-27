#!/usr/bin/env python3
"""Pack the bridge extension directory into an XPI (a zip with manifest.json
at its root) for Firefox's policy force-install (policies.json,
ExtensionSettings). The extension id is fixed in the manifest
(browser_specific_settings.gecko.id); the XPI is unsigned, which Firefox ESR
accepts with xpinstall.signatures.required off (prefs.js).

usage: xpipack.py <ext_dir> <out.xpi>
"""
import os
import sys
import zipfile


def main(src, out):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as xpi:
        for root, _dirs, files in os.walk(src):
            for name in sorted(files):
                path = os.path.join(root, name)
                xpi.write(path, os.path.relpath(path, src))
    print(out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
