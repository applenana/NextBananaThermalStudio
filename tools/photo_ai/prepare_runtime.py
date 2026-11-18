"""Prepare the optional, portable Windows CUDA/CPU photo-AI bundle.

Run with Python 3.13 on Windows. No globally installed packages are changed.
The output is gitignored and can be copied beside banana_thermal.exe as photo_ai.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PYTHON_URL = 'https://www.python.org/ftp/python/3.13.3/python-3.13.3-embed-amd64.zip'
PYTHON_HASH = '59ff76e16e6597de47474fb22be69e7191a89116910d728ab735079b078e52db'
URLS = {
    'pft_l1': 'https://huggingface.co/SemilleroCV/thermal-pft-light-srx3/resolve/5002f089dcbd43c6835620136e0c0318707276cf/202_Thermal_PFT_light_SRx3_finetune.pth',
    'pft_tv': 'https://huggingface.co/SemilleroCV/thermal-pft-light-srx3-cross-channel-tv/resolve/98dfd184de8d364d19982190d70c2c692333aaf5/202_Thermal_PFT_light_SRx3_finetune_cross_channel_tv.pth',
}


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def fetch(target, url, expected):
    if target.exists() and digest(target) == expected:
        return
    temp = target.with_suffix('.partial')
    urllib.request.urlretrieve(url, temp)
    if digest(temp) != expected:
        raise ValueError('Checksum mismatch: ' + str(target))
    temp.replace(target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT/'build/photo-ai-runtime')
    parser.add_argument('--weights-cache', type=Path, default=ROOT/'build/thermal-models/weights')
    parser.add_argument('--backend', choices=['cuda', 'cpu'], default='cuda')
    parser.add_argument('--runtime-site', type=Path,
                        help='Reuse a prepared, compatible site-packages directory (offline packaging)')
    args = parser.parse_args()
    if sys.platform != 'win32' or sys.version_info[:2] != (3, 13):
        raise RuntimeError('Use Windows Python 3.13 to prepare this bundle')
    target = args.output.resolve()
    cache = ROOT/'build/thermal-models'
    cache.mkdir(parents=True, exist_ok=True)
    (target/'python').mkdir(parents=True, exist_ok=True)
    archive = cache/'python-3.13.3-embed-amd64.zip'
    fetch(archive, PYTHON_URL, PYTHON_HASH)
    with zipfile.ZipFile(archive) as z:
        z.extractall(target/'python')
    (target/'python/python313._pth').write_text('python313.zip\n.\nLib/site-packages\n..\nimport site\n')
    site = target/'python/Lib/site-packages'
    if args.runtime_site:
        if args.runtime_site.resolve() != site.resolve():
            shutil.copytree(args.runtime_site, site, dirs_exist_ok=True)
    elif not (site/'torch').exists():
        torch_args = ['torch==2.11.0+cu128', '--index-url', 'https://download.pytorch.org/whl/cu128'] if args.backend == 'cuda' else ['torch==2.15.0']
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--target', str(site), *torch_args], check=True)
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--target', str(site),
                        'numpy==2.5.5', 'einops==0.8.2'], check=True)
    subprocess.run([str(target/'python/python.exe'), '-c',
                    'import torch; assert bool(torch.version.cuda) == '+repr(args.backend == 'cuda')+
                    ', "Existing runtime backend mismatch; use a fresh --output directory"'], check=True)
    manifest = json.loads((HERE/'weights-manifest.json').read_text())
    args.weights_cache.mkdir(parents=True, exist_ok=True)
    (target/'weights').mkdir(exist_ok=True)
    for retired in ('weights/pbvs.pth', 'weights/swinfu_robust03.pth',
                    'vendor/drct.py', 'vendor/swinfu.py',
                    'DRCT-LICENSE.txt', 'SwinFuSR-LICENSE.txt'):
        (target/retired).unlink(missing_ok=True)
    for model, item in manifest.items():
        source = args.weights_cache/item['file']
        fetch(source, URLS[model], item['sha256'])
        shutil.copy2(source, target/'weights'/item['file'])
    shutil.copy2(HERE/'weights-manifest.json', target/'weights/manifest.json')
    for name in ['engine.py', 'worker.py', 'MODELS.md']:
        shutil.copy2(HERE/name, target/name)
    shutil.copytree(HERE/'vendor', target/'vendor', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copy2(HERE/'PFT-LICENSE.txt', target/'PFT-LICENSE.txt')
    subprocess.run([str(target/'python/python.exe'), '-c',
                    'import torch,numpy,einops; print(torch.__version__, "portable runtime ready")'], check=True)
    print('Prepared:', target)


if __name__ == '__main__':
    main()
