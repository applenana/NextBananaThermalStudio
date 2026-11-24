"""Fit the shared motion matcher with numpy. No external images or runtime dependencies.

Each example is a thermal-like patch translated by a known even displacement,
with exposure drift, noise and occasional independently moving/occluded pixels.
Learn a linear softmax scorer over 25 symmetric midpoint motion hypotheses.
"""
import numpy as np


def examples(seed, n):
    rng = np.random.default_rng(seed)
    shifts = np.array([(x, y) for y in range(-2, 3) for x in range(-2, 3)])
    grid = np.arange(-2, 3)
    px, py = np.meshgrid(grid, grid)
    x, y = px.flatten() + 8, py.flatten() + 8
    sx, sy = shifts.T[:, :, None]
    feats, labels = [], []
    for _ in range(n):
        a = rng.random((17, 17))
        for _ in range(rng.integers(1, 6)):
            a = (a + np.roll(a, 1, 0) + np.roll(a, 1, 1)) / 3
        a = (a-a.min()) / (a.max()-a.min())
        k = 12 if rng.random() < .25 else rng.integers(25)
        dx, dy = shifts[k]
        b = np.roll(a, (2*dy, 2*dx), axis=(0, 1))
        b += rng.normal(0, .03, b.shape) + rng.normal(0, .035)
        if rng.random() < .4:
            i, j = rng.integers(3, 12, 2)
            b[i:i+4, j:j+4] = rng.random()
        d = a[y-sy, x-sx] - b[y+sy, x+sx].clip(0, 1)
        feats.append(np.stack([np.abs(d).mean(1), np.minimum(np.abs(d), .08).mean(1),
                               np.abs(d.mean(1)), (shifts**2).sum(1)/8], axis=1))
        labels.append(k)
    return np.array(feats), np.array(labels)


if __name__ == "__main__":
    x, y = examples(23, 2048)
    scale = x.std(axis=(0, 1))
    x /= scale
    w = np.zeros(4)
    for epoch in range(500):
        z = x @ w
        p = np.exp(z-z.max(axis=1, keepdims=True))
        p /= p.sum(1, keepdims=True)
        p[np.arange(len(y)), y] -= 1
        w -= .16 * ((x*p[:, :, None]).sum(1).mean(0) + .0005*w)
    w /= scale
    valid, labels = examples(981, 512)
    print("weights:", w.tolist())
    print("held-out correct:", ((valid @ w).argmax(1) == labels).sum(), "/", len(labels))
