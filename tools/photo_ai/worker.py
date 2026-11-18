"""Sequential JSON-lines local subprocess; float32 payloads use base64.

stdout is protocol-only. EOF closes the worker when the app exits.
"""
import argparse
import base64
import contextlib
import json
import sys
import traceback
import time
import numpy as np
from engine import Engine


def probe_cuda():
    """Verify this bundled runtime can execute kernels, not just find a GPU."""
    import torch
    try:
        if not torch.cuda.is_available():
            return {'cudaAvailable': False, 'reason': 'CUDA is unavailable in this runtime'}
        with torch.inference_mode():
            sample = torch.ones((16, 16), device='cuda')
            result = sample @ sample
            torch.cuda.synchronize()
            if result[0, 0].item() != 16:
                raise RuntimeError('CUDA computation failed validation')
        return {'cudaAvailable': True, 'deviceName': torch.cuda.get_device_name()}
    except Exception as exc:
        return {'cudaAvailable': False, 'reason': str(exc)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--weights')
    parser.add_argument('--probe-cuda', action='store_true')
    parser.add_argument('--device', default='auto', choices=['auto', 'cpu', 'cuda'])
    args = parser.parse_args()
    if args.probe_cuda:
        print(json.dumps(probe_cuda()), flush=True)
        return
    if not args.weights:
        parser.error('--weights is required for inference')
    engine = Engine(args.weights, args.device)
    protocol = sys.stdout
    def progress(event):
        print(json.dumps({'event': 'progress', **event}, separators=(',', ':')),
              file=protocol, flush=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            request_start = time.perf_counter()
            w, h = request['width'], request['height']
            if type(w) is not int or type(h) is not int or min(w, h) < 1 or max(w, h) > 512:
                raise ValueError('Invalid dimensions')
            source = np.frombuffer(base64.b64decode(request['data'], validate=True), dtype='<f4').reshape(h, w)
            with contextlib.redirect_stdout(sys.stderr):
                output, stats = engine.infer(request['model'], source, progress)
            stats['requestMs'] = round((time.perf_counter() - request_start) * 1000)
            response = {'ok': True, 'width': output.shape[1], 'height': output.shape[0],
                        'data': base64.b64encode(output.tobytes()).decode('ascii'), **stats}
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            response = {'ok': False, 'error': str(exc)}
        print(json.dumps(response, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    main()
