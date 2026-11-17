#include <algorithm>
#include <cmath>
#include <vector>
#include "espcn_weights.h"

#ifdef _WIN32
#define SR_EXPORT extern "C" __declspec(dllexport)
#else
#define SR_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
// TensorFlow SAME cross-correlation in NHWC / HWIO order. Contiguous output
// channels let the compiler vectorize the inner multiply/add loop.
template<int K, int In, int Out, bool Relu>
std::vector<float> conv(const float* src, int w, int h,
                        const float* weights, const float* bias) {
  std::vector<float> dst(static_cast<size_t>(w) * h * Out);
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      float* pixel = dst.data() + (y * w + x) * Out;
      std::copy(bias, bias + Out, pixel);
      for (int ky = 0; ky < K; ++ky) {
        const int sy = y + ky - K / 2;
        if (sy < 0 || sy >= h) continue;
        for (int kx = 0; kx < K; ++kx) {
          const int sx = x + kx - K / 2;
          if (sx < 0 || sx >= w) continue;
          const float* input = src + (sy * w + sx) * In;
          const float* kernel = weights + (ky * K + kx) * In * Out;
          for (int c = 0; c < In; ++c) {
            const float value = input[c];
            for (int o = 0; o < Out; ++o) pixel[o] += value * kernel[c * Out + o];
          }
        }
      }
      if constexpr (Relu) {
        for (int o = 0; o < Out; ++o) pixel[o] = std::max(0.0f, pixel[o]);
      }
    }
  }
  return dst;
}
}

// Input is normalized thermal display intensity [0,1], never a temperature
// buffer. Output is exactly 2w x 2h. No global mutable inference state.
SR_EXPORT int thermal_espcn_x2(const float* input, int w, int h, float* output) {
  if (!input || !output || w < 1 || h < 1 || w > 512 || h > 512) return -1;
  for (int i = 0; i < w * h; ++i) {
    if (!std::isfinite(input[i]) || input[i] < 0.0f || input[i] > 1.0f) return -2;
  }
  try {
    const auto first = conv<5, 1, 64, true>(input, w, h, espcn::f1, espcn::b1);
    const auto second = conv<3, 64, 32, true>(first.data(), w, h, espcn::f2, espcn::b2);
    const auto third = conv<3, 32, 4, false>(second.data(), w, h, espcn::f3, espcn::b3);
    for (int y = 0; y < h; ++y) {
      for (int x = 0; x < w; ++x) {
        for (int dy = 0; dy < 2; ++dy) {
          for (int dx = 0; dx < 2; ++dx) {
            const float v = std::tanh(third[(y * w + x) * 4 + dy * 2 + dx]);
            output[(2 * y + dy) * (2 * w) + 2 * x + dx] = std::clamp(v, 0.0f, 1.0f);
          }
        }
      }
    }
    return 0;
  } catch (...) {
    return -3;
  }
}
