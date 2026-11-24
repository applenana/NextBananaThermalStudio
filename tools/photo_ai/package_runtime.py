"""Create a ZIP64 runtime split into <= 1 GiB release assets, plus a manifest.

The manifest SHA-256 is embedded in the matching application by release CI.
Only the Python standard library is required; never load the whole ZIP in RAM.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import zipfile

MANIFEST = 'photo-ai-windows-x64.json'
PART_PREFIX = 'photo-ai-windows-x64.zip.'


class SplitWriter:
    """Non-seekable ZIP target: no second multi-GB temporary archive on CI."""
    def __init__(self, directory, limit):
        self.directory, self.limit = directory, limit
        self.parts, self.position, self.stream = [], 0, None

    def tell(self):
        return self.position

    def flush(self):
        if self.stream:
            self.stream.flush()

    def write(self, data):
        length = len(data)
        remaining = memoryview(data)
        while remaining:
            if self.stream is None:
                self.name = PART_PREFIX + f'{len(self.parts)+1:03d}'
                self.stream = (self.directory/self.name).open('wb')
                self.size, self.digest = 0, hashlib.sha256()
            block = remaining[:self.limit-self.size]
            self.stream.write(block)
            self.digest.update(block)
            self.size += len(block)
            self.position += len(block)
            remaining = remaining[len(block):]
            if self.size == self.limit:
                self.close_part()
        return length

    def close_part(self):
        if self.stream:
            self.stream.close()
            self.parts.append(dict(name=self.name, size=self.size,
                                   sha256=self.digest.hexdigest()))
            self.stream = None


def package(source, output, tag, part_size=1024**3):
    source, output = Path(source), Path(output)
    if not re.fullmatch(r'v\d+\.\d+\.\d+(\.\d+)?', tag):
        raise ValueError('Expected a numeric release tag')
    if not 0 < part_size <= 1024**3:
        raise ValueError('Parts must be <= 1 GiB')
    required = ['python/python.exe', 'worker.py', 'engine.py', 'check_runtime.py',
                'weights/manifest.json', 'weights/pft_tv.pth', 'weights/pft_l1.pth']
    for name in required:
        if not (source/name).is_file():
            raise ValueError('Missing runtime file: ' + name)
    output.mkdir(parents=True, exist_ok=True)
    if (output/MANIFEST).exists() or any(output.glob(PART_PREFIX + '*')):
        raise ValueError('Output already contains runtime assets; use a fresh directory')
    paths = sorted(p for p in source.rglob('*') if p.is_file()
                   and '__pycache__' not in p.parts and p.suffix != '.pyc')
    expanded = sum(p.stat().st_size for p in paths)
    archive = SplitWriter(output, part_size)
    try:
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED,
                             compresslevel=6, allowZip64=True) as z:
            for path in paths:
                if path.is_symlink():
                    raise ValueError('Symlinks are not supported')
                z.write(path, path.relative_to(source).as_posix())
    finally:
        archive.close_part()
    data = dict(schema=1, runtime='thermal-pft-v1', tag=tag,
                platform='windows-x64', backend='cuda128',
                expandedBytes=expanded, fileCount=len(paths), parts=archive.parts)
    raw = (json.dumps(data, indent=2) + '\n').encode()
    (output/MANIFEST).write_bytes(raw)
    return hashlib.sha256(raw).hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    print(package(args.source, args.output, args.tag))
