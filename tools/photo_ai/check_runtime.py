"""Offline install smoke test: validate both weights and one small CPU inference."""
from pathlib import Path
import json
import numpy as np
import torch
from engine import Engine

if __name__ == '__main__':
    engine = Engine(Path(__file__).parent/'weights', device='cpu')
    for model in ('pft_l1', 'pft_tv'):
        engine.load(model, lambda *args: None)
    output, _ = engine.infer('pft_tv', np.full((32, 32), 0.5, dtype=np.float32))
    assert output.shape == (96, 96) and np.isfinite(output).all()
    print(json.dumps({'ok': True, 'cudaAvailable': torch.cuda.is_available()}))
