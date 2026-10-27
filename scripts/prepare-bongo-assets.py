#!/usr/bin/env python3
"""Prepare a pinned, byte-preserving BongoCat model for local validation only."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import urllib.request


REVISION = "b82b4750b776df1408db07d5858d37db1594c3f3"
REPOSITORY = "https://github.com/ayangweb/BongoCat"
MODEL_PREFIX = "resources/models/standard/"
EXPECTED_BLOBS = {
    "LICENSE": "dfd42098decce4a4c3c5e806c7c595d4c2b6b7d2",
    "cat.model3.json": "3c43504e448777d7cbe23ac84ef1634a0be200cf",
    "demomodel.1024/texture_00.png": "49e970de9808f0dd2ca75f873d7b9a6eb563ac23",
    "demomodel.1024/texture_01.png": "7c3ac4aae0fbc2b14656c7fe7d413ef6970920da",
    "demomodel.1024/texture_02.png": "3abe922989ce5638ca13316239280a2996c0bba4",
    "demomodel.cdi3.json": "3cabe9a800fed4679c31b1b6d9e2a4c423cd6744",
    "demomodel.moc3": "8e99c415a31a7e672eafb4983cb233d97a31b146",
    "resources/background.png": "e8b716df5ffe535940bb8a7b96c68a11fe48374d",
    "resources/left-keys/AltLeft.png": "f3e272594e1cb2ed15a5dc21fdbfc0e6f31a0248",
    "resources/left-keys/AltRight.png": "977b18fbf4b1dc7d2b5675a115c061f076c34076",
    "resources/left-keys/BackQuote.png": "430a3b63cfeb64243cee1559616fa8f07df32034",
    "resources/left-keys/Backspace.png": "5ac34b660e2e65c8e9a9989f33c0314aabc2aada",
    "resources/left-keys/CapsLock.png": "d5aaceb4ad4050e968e7a57bc7494558f17ad8ce",
    "resources/left-keys/ControlLeft.png": "d8035f0d70678ce5916edf99a97a7aa37c7f3333",
    "resources/left-keys/ControlRight.png": "3f5c8b3a1ecfd251965e60a15f9dd9f0983a5e2c",
    "resources/left-keys/Delete.png": "8b4048571b90a2291d1fe1aea8a1b41d3be51a6a",
    "resources/left-keys/Enter.png": "6a803de18a7661ed2ea367597876374800036aa1",
    "resources/left-keys/Escape.png": "6c55e5bfbae50e1f87593fb5744f5a69ab029378",
    "resources/left-keys/Fn.png": "b555b7d070870941b4ae6099c472e8f68935ee22",
    "resources/left-keys/KeyA.png": "d11714a6036cd620bcd0b2dbf0ca230b7f0e87ed",
    "resources/left-keys/KeyB.png": "d168366159c61ae1bde5382df54a72cc1f09b7c5",
    "resources/left-keys/KeyC.png": "55fa3f23db62a7f15432e9333981a61bfbd8adc9",
    "resources/left-keys/KeyD.png": "fc231c323555fafabc98f185874a88c896cdab5a",
    "resources/left-keys/KeyE.png": "0c319aca0c2958922bf9e2ad438a216fd1aef1a9",
    "resources/left-keys/KeyF.png": "1cfc54c38bd1ff0ad2c580206f4a10ed4f7f33a1",
    "resources/left-keys/KeyG.png": "9522a6287e33d2b457f8798e8dcb4f348759c8fc",
    "resources/left-keys/KeyH.png": "633665c0bb99bc2567c4317b15e7c49ab2fa7577",
    "resources/left-keys/KeyI.png": "9c61876f88f9be11a9b67a4d269bc8f58a02aa7d",
    "resources/left-keys/KeyJ.png": "afdf7646ab3ce79a1975e9ad15154b1e9d128166",
    "resources/left-keys/KeyK.png": "4d123089c887afe32eccd389f05d461ccc479e93",
    "resources/left-keys/KeyL.png": "03e9fc8006afa9754c94d0d98afa3590a3f72f8e",
    "resources/left-keys/KeyM.png": "9b594eb72214eba72a896f8419c18e241aff4638",
    "resources/left-keys/KeyN.png": "0bbd4db920de23661c0f2b4a5177d3cd813bcc00",
    "resources/left-keys/KeyO.png": "484656bda3499219772289b42a34226ea04dfaf4",
    "resources/left-keys/KeyP.png": "79f34b93dce7231c230df8abb55ca56bd971c323",
    "resources/left-keys/KeyQ.png": "759f7d5238f934880fe8a0b37fecc3cc64444581",
    "resources/left-keys/KeyR.png": "fb385014fc38e3a10ac14ff3b184404afd5a3f47",
    "resources/left-keys/KeyS.png": "91c74257ba60c1c5c2d363571090e8b6bb430f11",
    "resources/left-keys/KeyT.png": "066a261445028dc697583864ee882082d0f65830",
    "resources/left-keys/KeyU.png": "29177ba6045858bf6d82d9a2c9c4bfc4178993c3",
    "resources/left-keys/KeyV.png": "93a05b3ebdc0a981054810560ae84048ec627306",
    "resources/left-keys/KeyW.png": "186eb1a1a2e72edaf2b5353c13c4e8376ffb38f2",
    "resources/left-keys/KeyX.png": "c951dd7d1c6add350ed05155fb18fee62f7a57cb",
    "resources/left-keys/KeyY.png": "b87b4f2404d21b51cfb72440c5a5503a1c0ed28e",
    "resources/left-keys/KeyZ.png": "c185f4cfaa30d9833be7c81efeffab7bbcea2a0c",
    "resources/left-keys/Meta.png": "a2ae7db3064f7c10bf8c01bb401a05003394683b",
    "resources/left-keys/Num0.png": "9b0a00b7ec8d5accccf1cd88eaaaeeb65e6a52c9",
    "resources/left-keys/Num1.png": "bd1d787d9008cd80efe463207c6b952cbe193dd0",
    "resources/left-keys/Num2.png": "9375bb11087672859737fd34bbd982e0566b04db",
    "resources/left-keys/Num3.png": "16380857b2b45d9cb7e868ea469fccab4f9f867e",
    "resources/left-keys/Num4.png": "21f6cde5c12e1d83244266c7bf2b6cf748473711",
    "resources/left-keys/Num5.png": "59e0d3c4de44a309b1b18ceea2f240cab25fa36d",
    "resources/left-keys/Num6.png": "63c97dd3fc04199d22703b2c0560abc8d007087b",
    "resources/left-keys/Num7.png": "8d77ba877858f009e345c4c5ceb1d0610e2ee176",
    "resources/left-keys/Num8.png": "d000d21a4d3ca6ca9108028c0ea413f8bd8896bd",
    "resources/left-keys/Num9.png": "d1b86fcf073c705466df83c9197401b4e4c5d77b",
    "resources/left-keys/ShiftLeft.png": "2013f25c36308f9eb9311ac5c8f5c0050c50a28a",
    "resources/left-keys/ShiftRight.png": "9e2759d4dc31065e7277c39aeed3fa1ec475e298",
    "resources/left-keys/Slash.png": "5eb4d17fc3939cfa83a0acc561374f1ac2530181",
    "resources/left-keys/Space.png": "05263fa5c10cc3e07eada64eea89e99eae4b0c4b",
    "resources/left-keys/Tab.png": "5615d7b275fadd7286867ea6f8016c0d1bccf672",
    "exp_1.exp3.json": "285e4c1c4b76e2ee53f64d02eddaccdd584be879",
    "exp_2.exp3.json": "0c389fe74134d780001121cc28d49cc11752a641",
    "live2d_expression0.exp3.json": "4162d0412316cbc5da8bed5b7c66ba2c148a3557",
    "live2d_expression1.exp3.json": "d87ba5d3859ae1514d762adb36ba56c884d36fa1",
    "live2d_expression2.exp3.json": "2008f5133e5d9bf53458497b533c74af9e1eb7f9",
    "live2d_motion1.motion3.json": "42c68d499affd5a0c9d562a3c1d8237d3d197d78",
    "live2d_motion2.motion3.json": "bae53b4640200dd5b076efaa4a42f507d063e3da",
}
MAX_RESOURCE_BYTES = 2 * 1024 * 1024


def download(url, limit=MAX_RESOURCE_BYTES):
    request = urllib.request.Request(url, headers={"User-Agent": "KeyTrail-local-asset-validation"})
    with urllib.request.urlopen(request, timeout=45) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Resource exceeds size limit: {url}")
    return data


def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".bongo-", delete=False) as output:
        temporary = Path(output.name)
        output.write(data)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "artifacts/bongo-assets")
    parser.add_argument("--tree-json", type=Path, default=Path("/tmp/keytrail-bongo-tree.json"),
                        help="Cached public GitHub recursive tree; pinned blob hashes remain authoritative.")
    args = parser.parse_args()
    tree_url = f"https://api.github.com/repos/ayangweb/BongoCat/git/trees/{REVISION}?recursive=1"
    tree = json.loads(args.tree_json.read_bytes() if args.tree_json.is_file()
                      else download(tree_url, limit=8 * 1024 * 1024))
    if tree.get("truncated"):
        raise ValueError("GitHub tree is truncated")
    entries = {entry["path"]: entry for entry in tree["tree"]}
    records = []
    for relative, expected in EXPECTED_BLOBS.items():
        source = relative if relative == "LICENSE" else MODEL_PREFIX + relative
        entry = entries.get(source)
        if not entry or entry.get("type") != "blob" or entry.get("sha") != expected:
            raise ValueError(f"Tree does not match the pinned blob for {source}")
        local = "LICENSE.upstream" if relative == "LICENSE" else "standard/" + relative
        destination = args.output / local
        url = f"https://raw.githubusercontent.com/ayangweb/BongoCat/{REVISION}/{source}"
        if destination.is_file():
            data = destination.read_bytes()
            if blob_sha(data) != expected:
                raise ValueError(f"Existing local file differs; preserve it and choose a fresh output directory: {destination}")
        else:
            data = download(url)
            if blob_sha(data) != expected or len(data) != entry.get("size"):
                raise ValueError(f"Downloaded bytes do not match the pinned Git blob: {source}")
            write_atomic(destination, data)
        records.append({"path": local, "source_path": source, "source_url": url,
                        "bytes": len(data), "git_blob_sha1": expected,
                        "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {
        "schema_version": 1,
        "repository": REPOSITORY,
        "revision": REVISION,
        "purpose": "Personal local integration validation only; not a redistribution authorization.",
        "license_notice": "LICENSE.upstream preserves the application repository license; model asset licensing is not asserted to be Apache-2.0.",
        "excluded": ["Cubism SDK and executable code", "audio", "cover image"],
        "known_missing_references": ["standard/live2d_motion1.flac (Sound references intentionally retained in original JSON; disable audio loading)"],
        "files": records,
    }
    write_atomic(args.output / "manifest.json", (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode())
    print(f"Verified {len(records) - 1} original model files and upstream LICENSE at {REVISION}.")
    print(f"SHA-256 manifest: {args.output / 'manifest.json'}")
    print("Local validation only. Audio references remain in the unchanged model JSON; do not load audio.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"BongoCat asset preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
