"""Inference-only replacements for training framework utilities."""
import torch
from torch import nn

trunc_normal_ = nn.init.trunc_normal_


def to_2tuple(value):
    return value if isinstance(value, (tuple, list)) else (value, value)


class Registry:
    def register(self):
        return lambda cls: cls


ARCH_REGISTRY = Registry()


class DropPath(nn.Module):
    def __init__(self, drop_prob=0.0):
        super().__init__()
        self.drop_prob = drop_prob

    def forward(self, x):
        if self.training and self.drop_prob:
            raise RuntimeError('This adapter supports inference only')
        return x
