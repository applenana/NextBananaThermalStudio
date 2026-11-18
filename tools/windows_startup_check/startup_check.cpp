// Native lifecycle smoke check only: no Flutter engine, widgets or page tests.
#include "win32_window.h"
#include <iostream>
#include <stdexcept>

namespace {
constexpr auto kSplashClass = L"BananaThermalStudio_Splash";
void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
HWND OwnSplash() {
  HWND window = nullptr;
  while ((window = FindWindowEx(nullptr, window, kSplashClass, nullptr))) {
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    if (process == GetCurrentProcessId()) return window;
  }
  return nullptr;
}
class SlowWindow : public Win32Window {
 public:
  bool succeed = true;
 protected:
  bool OnCreate() override {
    HWND splash = OwnSplash();
    Require(splash && IsWindowVisible(splash), "Splash missing before engine initialization");
    Require(GetWindowThreadProcessId(splash, nullptr) != GetCurrentThreadId(),
            "Splash shares blocked engine thread");
    Sleep(200);  // Simulate synchronous plugin setup without pumping main thread.
    DWORD_PTR result = 0;
    Require(SendMessageTimeout(splash, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 500, &result) != 0,
            "Splash does not respond during engine setup");
    RECT rect{};
    GetWindowRect(GetHandle(), &rect);
    Require(rect.right < 0, "Host appears before first frame");
    return succeed;
  }
};
}  // namespace

int main() {
  try {
    SlowWindow window;
    Require(window.Create(L"Startup lifecycle check", {10, 10}, {320, 200}), "Create failed");
    window.DismissSplash();
    Require(OwnSplash() == nullptr, "Splash survives first frame");
    RECT rect{};
    GetWindowRect(window.GetHandle(), &rect);
    Require(rect.left >= 0, "Host not restored after first frame");
    window.Destroy();
    window.succeed = false;
    Require(!window.Create(L"Startup failure check", {10, 10}, {320, 200}), "Failure ignored");
    Require(!OwnSplash() && !window.GetHandle(), "Failed startup leaks windows");
    window.succeed = true;
    Require(window.Create(L"Startup close check", {10, 10}, {320, 200}), "Recreate failed");
    window.Destroy();
    window.Destroy();
    Require(!OwnSplash(), "Close during startup leaks popup");
    std::cout << "PASS: early responsive splash, dismiss, failure, recreate, repeated cleanup\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
