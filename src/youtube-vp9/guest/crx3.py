#!/usr/bin/env python3
"""A CRX3 file (Chrome's packed extension) without a browser, for Prefer VP9
on YouTube (install.sh beside this file). Run in the VM:

  crx3.py pack KEY.pem SRC_DIR OUT.crx   packs SRC_DIR, prints the extension id
  crx3.py id KEY.pem                     the id KEY gives
  crx3.py info FILE.crx                  "<id> <version>" when the file is a
                                         valid CRX3 signed by the key its id
                                         names (exit 1 otherwise)

The layout is Chrome's (components/crx_file/crx3.proto): "Cr24", version 3,
the header's length, a CrxFileHeader, then the zip. The header holds the RSA
public key (DER) with its signature and signed_header_data (a SignedData with
crx_id, the first 16 bytes of sha256 of that key). The signature (RSA PKCS#1
v1.5, SHA-256) covers "CRX3 SignedData\\x00", the length of
signed_header_data (4 bytes, little end first), signed_header_data and the
zip. The id is crx_id in hex with 0-f written as a-p.

The zip is stored (no compression) with fixed times and sorted names, and
PKCS#1 v1.5 signatures are the same for the same input, so one key and the
same files give the same bytes on every run (install.sh compares before it
replaces). openssl does the RSA parts; the rest is the standard library."""
import hashlib, io, json, os, struct, subprocess, sys, tempfile, zipfile

MAGIC = b"Cr24"
SIGN_CONTEXT = b"CRX3 SignedData\x00"
MAX_HEADER = 1 << 16   # a header with one 2048-bit key is ~600 bytes


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


def field(number, data):
    """A length-delimited protobuf field (wire type 2)."""
    return varint(number << 3 | 2) + varint(len(data)) + data


def parse(data):
    """Length-delimited fields of one protobuf message: [(number, bytes)].
    Anything else (another wire type, a length past the end) is an error."""
    out, i = [], 0
    while i < len(data):
        key, i = read_varint(data, i)
        if key & 7 != 2:
            raise ValueError("unexpected wire type")
        n, i = read_varint(data, i)
        if i + n > len(data):
            raise ValueError("field past the end")
        out.append((key >> 3, data[i:i + n]))
        i += n
    return out


def read_varint(data, i):
    n = shift = 0
    while True:
        if i >= len(data) or shift > 63:
            raise ValueError("bad varint")
        b = data[i]
        i += 1
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            return n, i
        shift += 7


def openssl(*args, data=b""):
    return subprocess.run(["openssl", *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def public_der(key):
    return openssl("pkey", "-in", key, "-pubout", "-outform", "DER")


def crx_id(der):
    return hashlib.sha256(der).digest()[:16]


def id_text(raw):
    return "".join(chr(ord("a") + int(c, 16)) for c in raw.hex())


def archive(src):
    """SRC's files (no folders in it: the extension is flat) as a stored zip."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name in sorted(os.listdir(src)):
            path = os.path.join(src, name)
            if not os.path.isfile(path):
                continue
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            with open(path, "rb") as f:
                z.writestr(info, f.read())
    return buf.getvalue()


def signed_input(signed, zipped):
    return SIGN_CONTEXT + struct.pack("<I", len(signed)) + signed + zipped


def pack(key, src):
    der = public_der(key)
    raw = crx_id(der)
    zipped = archive(src)
    signed = field(1, raw)                       # SignedData.crx_id
    sig = openssl("dgst", "-sha256", "-sign", key, data=signed_input(signed, zipped))
    header = field(2, field(1, der) + field(2, sig)) + field(10000, signed)
    return MAGIC + struct.pack("<II", 3, len(header)) + header + zipped, id_text(raw)


def info(data):
    """(id, version) of a valid CRX3; ValueError otherwise."""
    if len(data) < 12 or data[:4] != MAGIC:
        raise ValueError("not a CRX file")
    version, size = struct.unpack("<II", data[4:12])
    if version != 3 or size > MAX_HEADER or 12 + size > len(data):
        raise ValueError("not a CRX3 file")
    header, zipped = data[12:12 + size], data[12 + size:]
    proofs, signed = [], None
    for number, value in parse(header):
        if number == 2:
            p = dict(parse(value))
            if 1 in p and 2 in p:
                proofs.append((p[1], p[2]))
        elif number == 10000:
            signed = value
    if signed is None:
        raise ValueError("no signed header data")
    raw = dict(parse(signed)).get(1, b"")
    if len(raw) != 16:
        raise ValueError("no crx id")
    der, sig = next(((d, s) for d, s in proofs if crx_id(d) == raw), (None, None))
    if der is None:
        raise ValueError("no key for the crx id")
    with tempfile.TemporaryDirectory() as t:
        pub, sigf = os.path.join(t, "pub.pem"), os.path.join(t, "sig")
        with open(pub, "wb") as f:
            f.write(openssl("pkey", "-pubin", "-inform", "DER", "-outform", "PEM", data=der))
        with open(sigf, "wb") as f:
            f.write(sig)
        try:
            openssl("dgst", "-sha256", "-verify", pub, "-signature", sigf, data=signed_input(signed, zipped))
        except subprocess.CalledProcessError:
            raise ValueError("bad signature") from None
    try:
        with zipfile.ZipFile(io.BytesIO(zipped)) as z:
            manifest = json.loads(z.read("manifest.json"))
    except (zipfile.BadZipFile, KeyError, ValueError):
        raise ValueError("no manifest") from None
    return id_text(raw), str(manifest.get("version", ""))


def main(argv):
    if len(argv) == 5 and argv[1] == "pack":
        data, ident = pack(argv[2], argv[3])
        with open(argv[4], "wb") as f:
            f.write(data)
        print(ident)
    elif len(argv) == 3 and argv[1] == "id":
        print(id_text(crx_id(public_der(argv[2]))))
    elif len(argv) == 3 and argv[1] == "info":
        try:
            with open(argv[2], "rb") as f:
                print(*info(f.read()))
        except (OSError, ValueError) as e:
            print(e, file=sys.stderr)
            return 1
    else:
        print("usage: crx3.py pack KEY.pem SRC_DIR OUT.crx | id KEY.pem | info FILE.crx", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
