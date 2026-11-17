"""Sequential JSON-lines local subprocess; float32 payloads use base64.

stdout is protocol-only. EOF closes the worker when the app exits.
"""
import argparse
import base64
import contextlib
import json
import sys
import traceback
import numpy as np
from engine import Engine


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--weights', required=True)
    parser.add_argument('--device', default='auto', choices=['auto', 'cpu', 'cuda'])
    args = parser.parse_args()
    engine = Engine(args.weights, args.device)
    protocol = sys.stdout
    def progress(event):
        print(json.dumps({'event': 'progress', **event}, separators=(',', ':')),
              file=protocol, flush=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            w, h = request['width'], request['height']
            if type(w) is not int or type(h) is not int or min(w, h) < 1 or max(w, h) > 512:
                raise ValueError('Invalid dimensions')
            source = np.frombuffer(base64.b64decode(request['data'], validate=True), dtype='<f4').reshape(h, w)
            with contextlib.redirect_stdout(sys.stderr):
                output, stats = engine.infer(request['model'], source, progress)
            response = {'ok': True, 'width': output.shape[1], 'height': output.shape[0],
                        'data': base64.b64encode(output.tobytes()).decode('ascii'), **stats}
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            response = {'ok': False, 'error': str(exc)}
        print(json.dumps(response, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    main()
