"""Fit and verify a two-convolution, single-channel LiteRT feasibility baseline."""
import argparse
import hashlib
from pathlib import Path

import flatbuffers
import numpy as np
from ai_edge_litert import schema_py_generated as s
from ai_edge_litert.interpreter import Interpreter


def frame(path):
    rows = np.genfromtxt(path, delimiter=",", names=True)
    x, y, z = (rows[k] for k in ("x", "y", "temperature_c"))
    if not (np.isfinite(z).all() and np.array_equal(x, x.astype(int))
            and np.array_equal(y, y.astype(int)) and min(x) >= 0 and min(y) >= 0):
        raise ValueError(f"Invalid coordinates or temperatures: {path}")
    out = np.full((int(max(y))+1, int(max(x))+1), np.nan, dtype=np.float32)
    out[y.astype(int), x.astype(int)] = z
    if out.shape != (90, 120) or out.size != len(rows) or not np.isfinite(out).all():
        raise ValueError(f"Expected a complete 120x90 input: {path}")
    return (out - out.min()) / max(np.ptp(out), 1e-6)


def features(x, filters):
    patches = np.lib.stride_tricks.sliding_window_view(np.pad(x, 1), (3, 3))
    return np.maximum(patches.reshape(*x.shape, 9) @ filters.T, 0)


def shuffle(x):
    h, w, _ = x.shape
    return x.reshape(h, w, 3, 3).transpose(0, 2, 1, 3).reshape(3*h, 3*w)


def reduce3(x):
    return x.reshape(30, 3, 40, 3).mean((1, 3))


def make_model(filters, weights):
    # NHWC activations; LiteRT convolution kernels are OHWI.
    m, g = s.ModelT(), s.SubGraphT()
    m.version, m.subgraphs, m.operatorCodes, m.buffers = 3, [g], [], [s.BufferT()]
    g.name, g.tensors, g.operators = "tiny3x", [], []

    def tensor(name, shape, values=None):
        t = s.TensorT()
        t.name, t.shape, t.type = name, shape, s.TensorType.FLOAT32
        if values is not None:
            t.buffer = len(m.buffers)
            buf = s.BufferT()
            buf.data = np.frombuffer(values.astype("<f4").tobytes(), np.uint8)
            m.buffers.append(buf)
        g.tensors.append(t)
        return len(g.tensors)-1

    def op(kind, inputs, output, options, options_type):
        code, layer = s.OperatorCodeT(), s.OperatorT()
        code.builtinCode = code.deprecatedBuiltinCode = kind
        layer.opcodeIndex = len(m.operatorCodes)
        layer.inputs, layer.outputs = inputs, [output]
        layer.builtinOptions, layer.builtinOptionsType = options, options_type
        m.operatorCodes.append(code)
        g.operators.append(layer)

    x = tensor("field", [1, 90, 120, 1])
    g.inputs = [x]
    for i, kernel in enumerate([filters.reshape(-1, 3, 3, 1), weights.T[:, None, None, :]]):
        n = kernel.shape[0]
        k = tensor(f"kernel{i}", list(kernel.shape), kernel)
        b = tensor(f"bias{i}", [n], np.zeros(n))
        dst = tensor(f"conv{i}", [1, 90, 120, n])
        opts = s.Conv2DOptionsT()
        opts.padding, opts.strideW, opts.strideH = s.Padding.SAME, 1, 1
        opts.fusedActivationFunction = s.ActivationFunctionType.RELU if i == 0 else s.ActivationFunctionType.NONE
        op(s.BuiltinOperator.CONV_2D, [x, k, b], dst, opts, s.BuiltinOptions.Conv2DOptions)
        x = dst
    dst = tensor("enhanced", [1, 270, 360, 1])
    opt = s.DepthToSpaceOptionsT()
    opt.blockSize = 3
    op(s.BuiltinOperator.DEPTH_TO_SPACE, [x], dst, opt, s.BuiltinOptions.DepthToSpaceOptions)
    g.outputs = [dst]
    builder = flatbuffers.Builder(4096)
    builder.Finish(m.Pack(builder), file_identifier=b"TFL3")
    return bytes(builder.Output())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("samples", type=Path, help="Directory with >=3 unique *.temperature.csv")
    p.add_argument("out", type=Path)
    args = p.parse_args()
    data = {}
    for f in sorted(args.samples.glob("*.temperature.csv")):
        image = frame(f)
        data.setdefault(hashlib.sha256(image.tobytes()).digest(), (f.name, image))
    if len(data) < 3:
        p.error("Need at least 3 distinct frames")
    *train, valid1, valid2 = data.values()
    # Identity, eight signed differences from the centre, and their negatives.
    identity = np.eye(9, dtype=np.float32)
    differences = np.delete(identity - identity[4], 4, axis=0)
    filters = np.vstack((identity[4], differences, -differences))
    xs, ys = [], []
    for _, image in train:
        xs.append(features(reduce3(image), filters).reshape(-1, len(filters)))
        ys.append(image.reshape(30, 3, 40, 3).transpose(0, 2, 1, 3).reshape(-1, 9))
    x, y = np.concatenate(xs).astype(float), np.concatenate(ys)
    weights = np.linalg.solve(x.T @ x + .001*np.eye(x.shape[1]), x.T @ y).astype("f")
    def predict(field):
        return shuffle(features(field, filters) @ weights)
    model = make_model(filters, weights)
    runtime = Interpreter(model_content=model, num_threads=1)
    runtime.allocate_tensors()
    for name, image in (valid1, valid2):
        low = reduce3(image)
        bicubic = cubic3(low)
        for label, value in [("bicubic", bicubic), ("tiny3x", predict(low))]:
            mse = np.mean((value.clip(0, 1) - image)**2)
            print(name, label, "PSNR dB", round(float(-10*np.log10(max(mse, 1e-12))), 2))
        runtime.set_tensor(runtime.get_input_details()[0]["index"], image[None, :, :, None])
        runtime.invoke()
        result = runtime.get_tensor(runtime.get_output_details()[0]["index"])[0, :, :, 0]
        ref = predict(image)
        np.testing.assert_allclose(result, ref, atol=2e-6, rtol=1e-5)
        print("120x90 -> 360x270, max abs error:", np.max(np.abs(result-ref)))
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "tiny3x.tflite").write_bytes(model)
    image.astype("<f4").tofile(args.out / "input.f32")
    ref.astype("<f4").tofile(args.out / "reference.f32")


def cubic3(x):
    # Separable Keys cubic interpolation, half-pixel centres and clamped edges.
    for _ in range(2):
        x = x.T
        pos = (np.arange(x.shape[1]*3) + .5)/3 - .5
        idx = np.floor(pos).astype(int)[None, :] + np.arange(-1, 3)[:, None]
        d = np.abs(pos - idx)
        w = np.where(d <= 1, 1.5*d**3 - 2.5*d**2 + 1, -.5*d**3 + 2.5*d**2 - 4*d + 2)
        x = (x[:, idx.clip(0, x.shape[1]-1)] * w).sum(1)
    return x


if __name__ == "__main__":
    main()
