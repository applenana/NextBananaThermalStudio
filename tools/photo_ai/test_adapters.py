"""Checks for local inference adaptations, not the upstream training code."""
import unittest
from unittest.mock import Mock, patch
from pathlib import Path
import sys

# Embedded Python's ._pth can otherwise resolve stale packaged adapters.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import torch
from vendor import sparse_ops


class AdapterTests(unittest.TestCase):
    def test_cuda_probe_rejects_unavailable_runtime(self):
        from worker import probe_cuda
        with patch('torch.cuda.is_available', return_value=False), patch('torch.ones') as allocate:
            self.assertFalse(probe_cuda()['cudaAvailable'])
            allocate.assert_not_called()

    def test_cuda_probe_rejects_kernel_failure(self):
        from worker import probe_cuda
        with patch('torch.cuda.is_available', return_value=True), \
             patch('torch.ones', side_effect=RuntimeError('unsupported CUDA architecture')):
            result = probe_cuda()
            self.assertFalse(result['cudaAvailable'])
            self.assertIn('unsupported CUDA architecture', result['reason'])

    def test_cuda_probe_checks_result_and_synchronizes(self):
        from worker import probe_cuda
        sample = torch.ones(16, 16)
        with patch('torch.cuda.is_available', return_value=True), \
             patch('torch.ones', return_value=sample) as allocate, \
             patch('torch.cuda.synchronize') as sync, \
             patch('torch.cuda.get_device_name', return_value='Test GPU'):
            self.assertEqual(probe_cuda(), {'cudaAvailable': True, 'deviceName': 'Test GPU'})
            allocate.assert_called_once_with((16, 16), device='cuda')
            sync.assert_called_once()

    def test_inference_mask_reuses_one_shape_and_preserves_output(self):
        from vendor.pft import PFT
        model = PFT(upscale=3, embed_dim=8, depths=[2], num_heads=2,
                    num_topk=[16, 16], window_size=4, convffn_kernel_size=3,
                    mlp_ratio=1, upsampler='pixelshuffledirect').eval()
        model.calculate_mask = Mock(wraps=model.calculate_mask)
        with torch.inference_mode():
            source = torch.rand(1, 3, 8, 8)
            reference = model(source)
            cached = model(source)
            self.assertTrue(torch.equal(reference, cached))
            self.assertEqual(model.calculate_mask.call_count, 1)
            changed = source * 0.5
            cached_changed = model(changed)
            del model._inference_mask_key
            self.assertTrue(torch.equal(cached_changed, model(changed)))
            model(torch.rand(1, 3, 8, 12))
            self.assertEqual(model.calculate_mask.call_count, 3)

    def test_cuda_failure_retries_on_cpu_but_other_errors_propagate(self):
        import numpy as np
        from engine import Engine
        source = np.zeros((3, 3), dtype=np.float32)
        engine = Engine.__new__(Engine)
        engine.allow_fallback = True
        engine.device = torch.device('cuda')
        engine.fallback_reason = None
        engine.model = object()
        engine.model_id = 'pft_l1'
        engine._infer = Mock(side_effect=[torch.cuda.OutOfMemoryError('CUDA out of memory'), ('ok', {})])
        events = []
        self.assertEqual(engine.infer('pft_l1', source, events.append), ('ok', {}))
        self.assertEqual(engine.device.type, 'cpu')
        self.assertIsNone(engine.model)
        self.assertEqual(events[0]['stage'], 'fallback')
        self.assertEqual(engine._infer.call_count, 2)
        engine.device = torch.device('cuda')
        engine._infer = Mock(side_effect=RuntimeError('shape mismatch'))
        with self.assertRaisesRegex(RuntimeError, 'shape mismatch'):
            engine.infer('pft_l1', source)
        self.assertEqual(engine._infer.call_count, 1)

    def test_blocks_report_completed_work_and_remove_hooks(self):
        import numpy as np
        from engine import Engine
        class TinyModel(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.layers = torch.nn.ModuleList([torch.nn.Identity(), torch.nn.Identity()])
            def forward(self, x):
                for layer in self.layers:
                    x = layer(x)
                return torch.nn.functional.interpolate(x, scale_factor=3)
        model = TinyModel()
        engine = Engine.__new__(Engine)
        engine.device = torch.device('cpu')
        engine.fallback_reason = None
        engine.load = Mock(return_value=model)
        events = []
        output, meta = engine.infer('pft_l1', np.zeros((3, 3), dtype=np.float32), events.append)
        self.assertEqual(output.shape, (9, 9))
        self.assertEqual([e['completed'] for e in events if e['stage'] == 'blocks'], [0, 1, 2])
        self.assertTrue(all(not layer._forward_hooks for layer in model.layers))

    def test_sparse_forward_matches_explicit_selected_products(self):
        torch.manual_seed(12)
        q, k, v = torch.randn(2, 7, 3), torch.randn(2, 3, 7), torch.randn(2, 7, 3)
        index = torch.stack([torch.stack([torch.randperm(7)[:4] for _ in range(7)]) for _ in range(2)])
        attention = torch.randn(2, 7, 4)
        qk = sparse_ops.SMM_QmK_forward_cuda(q, k, index)
        av = sparse_ops.SMM_AmV_forward_cuda(attention, v, index)
        for b in range(2):
            for n in range(7):
                self.assertTrue(torch.allclose(qk[b, n], q[b, n] @ k[b, :, index[b, n]], atol=1e-6))
                self.assertTrue(torch.allclose(av[b, n], attention[b, n] @ v[b, index[b, n]], atol=1e-6))

    def test_dimensions_and_unknown_models_rejected_before_loading(self):
        import numpy as np
        from engine import Engine
        engine = Engine.__new__(Engine)
        for model, source in [('unknown', np.zeros((3, 3))), ('pbvs', np.zeros((129, 3))),
                              ('pft_l1', np.full((2, 2), np.nan))]:
            with self.assertRaises(ValueError):
                engine.infer(model, source)


if __name__ == '__main__':
    unittest.main()
