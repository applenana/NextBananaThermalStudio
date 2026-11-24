"""Try the actual PFT TV graph (including padding and luminance) at a fixed size."""
import argparse
from pathlib import Path
import sys

import torch
from torch import nn

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "photo_ai"))
from engine import Engine


class FixedTV(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("luma", torch.tensor([.299, .587, .114]).view(1, 3, 1, 1))

    def forward(self, field):
        x = field.repeat(1, 3, 1, 1)
        x = torch.cat((x, x.flip(2)), 2)[:, :, :96]
        x = torch.cat((x, x.flip(3)), 3)[:, :, :, :128]
        return (self.net(x)[:, :, :270, :360] * self.luma).sum(1, keepdim=True).clamp(0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("weights", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--backend", choices=["export", "xnnpack", "vulkan"], default="export")
    ap.add_argument("--verify-pte", type=Path, metavar="INPUT_F32",
                    help="Run the generated PTE against one 120x90 normalized little-endian float32 frame")
    args = ap.parse_args()
    engine = Engine(args.weights, "cpu")
    model = FixedTV(engine.load("pft_tv", lambda *_: None)).eval()
    torch.manual_seed(17)
    x = torch.rand(1, 1, 90, 120)
    with torch.no_grad():
        ref = model(x)  # Warm the existing fixed-shape mask cache before capture.
        ep = torch.export.export(model, (x,), strict=True)
        torch.testing.assert_close(ep.module()(x), ref)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        if args.backend == "export":
            torch.export.save(ep, args.out)
        else:
            from executorch.exir import to_edge_transform_and_lower
            if args.backend == "vulkan":
                from executorch.backends.vulkan.partitioner.vulkan_partitioner import VulkanPartitioner
                part = VulkanPartitioner()
            else:
                from executorch.backends.xnnpack.partition.xnnpack_partitioner import XnnpackPartitioner
                part = XnnpackPartitioner()
            program = to_edge_transform_and_lower(ep, partitioner=[part]).to_executorch()
            with args.out.open("wb") as f:
                program.write_to_file(f)
            if args.verify_pte:
                from executorch.runtime import Runtime
                if args.verify_pte.stat().st_size != 120 * 90 * 4:
                    raise ValueError("Expected exactly 120x90 FP32 values")
                frame = torch.from_file(str(args.verify_pte), size=120*90).reshape(1, 1, 90, 120)
                loaded = Runtime.get().load_program(str(args.out))
                actual = loaded.load_method("forward").execute([frame])[0]
                torch.testing.assert_close(actual, model(frame))
        print(args.backend, tuple(ref.shape), args.out)


if __name__ == "__main__":
    main()
