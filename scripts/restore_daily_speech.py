"""Restore byte-identical, local-only MAGICDATA test recordings from the original dev_set.tar.gz."""
import argparse
import hashlib
import json
import tarfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive", type=Path, help="OpenSLR 68 dev_set.tar.gz")
args = parser.parse_args()
fixtures = Path(__file__).resolve().parents[1] / "AudioValidation" / "Fixtures"
items = json.loads((fixtures / "manifest.json").read_text())
required = {c["sourcePath"]: c for c in items if c["corpus"] == "MAGICDATA"}
with args.archive.open("rb") as compressed:
    if hashlib.file_digest(compressed, "md5").hexdigest() != "114a9333a9b5039b47bdbc0dd812adde":
        raise ValueError("源开发集与 OpenSLR 官方校验和不符")
with tarfile.open(args.archive, "r|gz") as archive:
    for member in archive:
        if member.name not in required:
            continue
        clip = required.pop(member.name)
        raw = archive.extractfile(member).read()
        if hashlib.sha256(raw).hexdigest() != clip["sha256"]:
            raise ValueError("录音校验失败 " + member.name)
        destination = fixtures / clip["file"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
if required:
    raise ValueError("缺少录音 " + str(sorted(required)))
