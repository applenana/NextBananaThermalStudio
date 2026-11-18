"""Warm serial inference benchmark; excludes process/model startup and UI.

Use --implementation with an exported revision to compare under the same runtime.
"""
import argparse
import importlib
import json
from pathlib import Path
import sys
import time

import numpy as np
import torch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--implementation', type=Path, default=Path(__file__).parent)
    parser.add_argument('--weights', type=Path, required=True)
    parser.add_argument('--sample', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--frames', type=int, default=20)
    args = parser.parse_args()
    sys.path.insert(0, str(args.implementation.resolve()))
    engine = importlib.import_module('engine').Engine(args.weights, 'cuda')
    values = np.loadtxt(args.sample, delimiter=',', skiprows=1, usecols=2).astype(np.float32).reshape(90, 120)
    source = (values - values.min()) / (values.max() - values.min())
    for _ in range(3):
        engine.infer('pft_tv', source)
    duration = []
    outputs = []
    for frame in range(args.frames):
        # Exercise changing content, not just replaying one result.
        current = np.roll(source, frame % 4, axis=1).copy()
        events = []
        start = time.perf_counter()
        output, metadata = engine.infer('pft_tv', current, events.append)
        duration.append((time.perf_counter() - start) * 1000)
        counts = [event['completed'] for event in events if event['stage'] == 'blocks']
        assert counts == list(range(6)), counts
        outputs.append(output)
    args.output.mkdir(parents=True, exist_ok=True)
    np.save(args.output / 'outputs.npy', np.stack(outputs))
    result = {
        'gpu': torch.cuda.get_device_name(), 'torch': torch.__version__,
        'frames': args.frames, 'frameMs': duration,
        'medianMs': float(np.median(duration)), 'p95Ms': float(np.percentile(duration, 95)),
        'throughputFps': 1000 / float(np.mean(duration)),
        'lastWorkerStats': metadata,
    }
    (args.output / 'benchmark.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
