"""Checks for local inference adaptations, not the upstream training code."""
import unittest
import torch
from vendor import sparse_ops


class AdapterTests(unittest.TestCase):
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
