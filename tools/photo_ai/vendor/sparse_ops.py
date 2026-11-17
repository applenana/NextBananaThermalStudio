"""Exact inference equivalents of PFT's optional sparse CUDA kernels.

Compute dense batched products followed by gather/scatter. No learned weights,
attention indices or equations are changed. This works on CPU and stock CUDA.
"""
import torch


def SMM_QmK_forward_cuda(q, k, index):
    return torch.bmm(q, k).gather(-1, index.long())


def SMM_AmV_forward_cuda(attention, value, index):
    dense = attention.new_zeros(attention.shape[0], attention.shape[1], value.shape[1])
    dense.scatter_add_(-1, index.long(), attention)
    return torch.bmm(dense, value)
