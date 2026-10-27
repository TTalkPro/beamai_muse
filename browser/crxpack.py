#!/usr/bin/env python3
"""Pack an MV3 extension directory into a CRX3 signed with a fixed RSA key.
From the browser spike (a prototype, since removed); the
Dockerfile runs it once at build time with a fresh key.

usage: crxpack.py <ext_dir> <key.pem> <out_dir> <version> <codebase_base_url>

Writes <out_dir>/muse.crx, <out_dir>/update.xml, <out_dir>/id and an unpacked
copy <out_dir>/unpacked/ whose manifest carries "key" (same extension ID when
loaded with --load-extension). Prints the extension ID.
No Chrome needed (Chrome's --pack-extension would need a display).
"""
import base64, hashlib, io, json, os, shutil, struct, sys, zipfile
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field(num, data):
    return varint((num << 3) | 2) + varint(len(data)) + data


def main():
    ext_dir, key_path, out_dir, version, base = sys.argv[1:6]
    if os.path.exists(key_path):
        key = serialization.load_pem_private_key(open(key_path, "rb").read(), None)
    else:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        open(key_path, "wb").write(key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()))
        os.chmod(key_path, 0o600)
    pub = key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    digest = hashlib.sha256(pub).digest()
    crx_id = digest[:16]
    ext_id = "".join(chr(ord("a") + int(c, 16)) for c in crx_id.hex())

    unpacked = os.path.join(out_dir, "unpacked")
    shutil.rmtree(unpacked, ignore_errors=True)
    shutil.copytree(ext_dir, unpacked)
    mpath = os.path.join(unpacked, "manifest.json")
    manifest = json.load(open(mpath))
    manifest["version"] = version
    open(mpath, "w").write(json.dumps(manifest, indent=2))

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(unpacked):
            for f in sorted(files):
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, unpacked))
    zip_bytes = buf.getvalue()

    signed_data = field(1, crx_id)
    msg = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed_data)) + signed_data + zip_bytes
    sig = key.sign(msg, padding.PKCS1v15(), hashes.SHA256())
    header = field(2, field(1, pub) + field(2, sig)) + field(10000, signed_data)
    crx = b"Cr24" + struct.pack("<II", 3, len(header)) + header + zip_bytes
    open(os.path.join(out_dir, "muse.crx"), "wb").write(crx)
    open(os.path.join(out_dir, "update.xml"), "w").write(
        "<?xml version='1.0' encoding='UTF-8'?>\n"
        "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>\n"
        f"  <app appid='{ext_id}'>\n"
        f"    <updatecheck codebase='{base}/muse.crx' version='{version}' />\n"
        "  </app>\n</gupdate>\n")
    open(os.path.join(out_dir, "id"), "w").write(ext_id)

    # Unpacked copy for --load-extension: same ID via "key".
    manifest["key"] = base64.b64encode(pub).decode()
    open(mpath, "w").write(json.dumps(manifest, indent=2))
    print(ext_id)


if __name__ == "__main__":
    main()
