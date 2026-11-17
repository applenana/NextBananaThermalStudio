"""Local thermal display SR. No temperature calibration or network access here."""
from pathlib import Path
import hashlib
import json
import os
import time

import numpy as np
import torch
from torch.nn import functional as F

SCALES = {'pft_l1': 3, 'pft_tv': 3, 'pbvs': 8, 'swinfu': 8}
FILES = {'pft_l1': 'pft_l1.pth', 'pft_tv': 'pft_tv.pth',
         'pbvs': 'pbvs.pth', 'swinfu': 'swinfu_robust03.pth'}


class Engine:
    def __init__(self, weights, device='cpu'):
        self.weights = Path(weights)
        self.device = torch.device(device)
        torch.set_num_threads(min(8, os.cpu_count() or 1))
        self.model = None
        self.model_id = None
        self.manifest = json.loads((self.weights / 'manifest.json').read_text())

    def load(self, model_id):
        if model_id == self.model_id:
            return self.model
        # Hold at most one large network in memory.
        self.model = None
        self.model_id = None
        path = self.weights / FILES[model_id]
        expected = self.manifest[model_id]['sha256']
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Model checksum mismatch: ' + model_id)
        if model_id.startswith('pft_'):
            from vendor.pft import PFT
            model = PFT(upscale=3, embed_dim=52, depths=[2, 4, 6, 6, 6],
                        num_heads=4, num_topk=[1024]*2 + [256]*4 + [128]*6 + [64]*6 + [32]*6,
                        window_size=32, convffn_kernel_size=7, mlp_ratio=1,
                        upsampler='pixelshuffledirect', use_checkpoint=False)
        elif model_id == 'pbvs':
            from vendor.drct import DRCT
            model = DRCT(upscale=8, in_chans=3, img_size=64, window_size=16,
                         depths=[6]*12, embed_dim=180, num_heads=[6]*12,
                         mlp_ratio=2, upsampler='pixelshuffle', resi_connection='1conv')
        else:
            from vendor.swinfu import SwinFusionSR
            model = SwinFusionSR(upscale=1, in_chans=1, img_size=64, window_size=8,
                                 embed_dim=60, Ex_depths=[4], Fusion_depths=[2, 2],
                                 Re_depths=[4], Ex_num_heads=[6], Fusion_num_heads=[6, 6],
                                 Re_num_heads=[6], mlp_ratio=2, upsampler='',
                                 resi_connection='1conv')
        state = torch.load(path, map_location='cpu', weights_only=True)
        if 'params_ema' in state:
            state = state['params_ema']
        model.load_state_dict(state, strict=True)
        self.model = model.eval().to(self.device)
        self.model_id = model_id
        return self.model

    @torch.inference_mode()
    def infer(self, model_id, source):
        if model_id not in SCALES:
            raise ValueError('Unknown model')
        scale = SCALES[model_id]
        if source.ndim != 2 or min(source.shape) < 1 or max(source.shape)*scale > 1024:
            raise ValueError('Invalid dimensions (maximum output axis 1024)')
        if not np.isfinite(source).all() or source.min() < 0 or source.max() > 1:
            raise ValueError('Expected finite normalized display intensity')
        clock = time.perf_counter()
        model = self.load(model_id)
        load_ms = (time.perf_counter() - clock)*1000
        h, w = source.shape
        x = torch.from_numpy(source.copy()).to(self.device)[None, None]
        clock = time.perf_counter()
        if model_id == 'swinfu':
            # Official model consumes pre-upsampled thermal intensity. Use its
            # missing-modality path (zero guide), never fabricate an RGB guide.
            x = F.interpolate(x, scale_factor=8, mode='bicubic', align_corners=False).clamp(0, 1)
            out = torch.empty_like(x)
            # Work at output resolution; halo tiles bound attention memory.
            # Grid/halo are multiples of window_size to preserve window phase.
            step, halo = 128, 32
            for y in range(0, h*8, step):
                for col in range(0, w*8, step):
                    bottom, right = min(y+step, h*8), min(col+step, w*8)
                    top, left = max(0, y-halo), max(0, col-halo)
                    patch = x[..., top:min(bottom+halo, h*8), left:min(right+halo, w*8)]
                    result = model(patch, torch.zeros_like(patch))
                    out[..., y:bottom, col:right] = result[..., y-top:bottom-top, col-left:right-left]
        else:
            # The authors train these networks with 3-channel image loaders.
            x = x.repeat(1, 3, 1, 1)
            block = 32 if model_id.startswith('pft_') else 16
            ph, pw = (-h) % block, (-w) % block
            # Symmetric endpoint padding, matching PFT's original preprocessing.
            if h < block or w < block:
                x = F.pad(x, (0, pw, 0, ph), mode='replicate')
            else:
                x = torch.cat((x, x.flip(2)), 2)[..., :h+ph, :]
                x = torch.cat((x, x.flip(3)), 3)[..., :w+pw]
            out = model(x)
            if isinstance(out, list):
                out = out[-1]  # Official DRCT test path selects the final 8x head.
            out = out[..., :h*scale, :w*scale]
            # Reject hallucinated color as palette input: use display luminance.
            out = (out * out.new_tensor([0.299, 0.587, 0.114])[None, :, None, None]).sum(1, keepdim=True)
        result = out[0, 0].clamp(0, 1).cpu().numpy().astype('<f4')
        if result.shape != (h*scale, w*scale) or not np.isfinite(result).all():
            raise ValueError('Invalid model output')
        return result, {'model': model_id, 'scale': scale, 'device': str(self.device),
                        'loadMs': round(load_ms), 'inferMs': round((time.perf_counter()-clock)*1000)}
