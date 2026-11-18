"""Check current source or an optional release directory for retired branding."""
from pathlib import Path
import argparse
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    retired = bytes([67, 66, 51, 54, 48]).lower()
    wide = retired.decode().encode('utf-16-le')
    if args.release:
        root = args.release.resolve()
        files = (p for p in root.rglob('*') if p.is_file())
    else:
        paths = subprocess.check_output(
            ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
            cwd=root).decode('utf-8').split('\0')
        files = (root / p for p in set(paths) if p and (root / p).is_file())
    failed = []
    def contains_retired(stream):
        previous = b''
        while block := stream.read(1024 * 1024):
            block = previous + block.lower()
            if retired in block or wide in block:
                return True
            previous = block[-32:]
        return False

    for path in files:
        relative = str(path.relative_to(root))
        if retired in relative.lower().encode():
            failed.append(relative)
            continue
        # Stream the binaries too, including ASCII and UTF-16 debug strings.
        with path.open('rb') as stream:
            if contains_retired(stream):
                failed.append(relative)
        if path.suffix.lower() in ('.apk', '.aab', '.zip'):
            with zipfile.ZipFile(path) as archive:
                for entry in archive.infolist():
                    if entry.is_dir():
                        continue
                    with archive.open(entry) as stream:
                        if retired in entry.filename.lower().encode() or contains_retired(stream):
                            failed.append(f'{relative}:{entry.filename}')
    if failed:
        print('Retired branding found in:')
        print('\n'.join(sorted(failed)))
        return 1
    print('Public branding check passed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
