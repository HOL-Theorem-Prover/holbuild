#!/usr/bin/env python3
"""remote_cache_entry.py CACHE KEY CAS_DIR OUT: writes to OUT the remote
cache's action entry for the local cache CACHE's entry for KEY, and copies
the blobs it names into the remote cache's CAS_DIR."""

import hashlib
import pathlib
import shutil
import sys

cache, key, cas, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
cache = pathlib.Path(cache)
manifest = (cache / "actions" / key / "manifest").read_bytes()
metadata = ["holbuild-remote-cache-action-v2",
            "manifest-sha256 " + hashlib.sha256(manifest).hexdigest(),
            "manifest-size " + str(len(manifest))]
for line in manifest.decode().splitlines():
    fields = line.split()
    if fields[:1] == ["blob"]:
        blob = fields[2]
        src = cache / "blobs" / blob
        shutil.copyfile(src, cas / blob)
        metadata.append("blob " + blob + " " + str(src.stat().st_size))
out.write_bytes(("\n".join(metadata) + "\nmanifest-text-v1\n").encode() + manifest)
