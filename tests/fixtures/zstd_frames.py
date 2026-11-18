import pathlib
import struct
import subprocess
import tempfile


def zstd_encode(data):
    """Encodes data as bazel-remote's zstd storage serves it: a skippable
    seek-table frame (here empty), then one frame per MiB of content, each
    giving its content size."""
    chunk = 1 << 20
    with tempfile.TemporaryDirectory() as directory:
        paths = []
        for start in range(0, max(len(data), 1), chunk):
            path = pathlib.Path(directory) / f"{len(paths):06}"
            path.write_bytes(data[start : start + chunk])
            paths.append(str(path))
        # With -c, zstd writes each input file as its own frame.
        frames = subprocess.check_output(["zstd", "-q", "-c", *paths])
    return struct.pack("<II", 0x184D2A50, 0) + frames
