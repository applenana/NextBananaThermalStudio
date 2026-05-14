#include "flutter_window.h"

#include <optional>
#include <dwmapi.h>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "Dwmapi.lib")

// Custom message used to dismiss the boot splash on the UI thread.
// Posted from SetNextFrameCallback (which may run on the raster thread)
// so DestroyWindow / SetWindowPos always run on the window-owning thread.
static constexpr UINT kSplashDismissMsg = WM_APP + 0x21;
static constexpr UINT_PTR kSplashFallbackTimerId = 0xBA0;

// Newer DWM attributes (Win11 22000+). Define here to avoid SDK version gates.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

static void ApplyModernTitleBar(HWND hwnd) {
  if (!hwnd) return;
  BOOL dark = TRUE;
  DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
  // Surface color matches app dark theme (0xFF111418).
  COLORREF cap = RGB(0x11, 0x14, 0x18);
  COLORREF txt = RGB(0xEC, 0xEC, 0xEC);
  COLORREF brd = RGB(0x11, 0x14, 0x18);
  DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &cap, sizeof(cap));
  DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &txt, sizeof(txt));
  DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &brd, sizeof(brd));
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  ApplyModernTitleBar(GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Splash dismissal must run on the UI thread (DestroyWindow + SetWindowPos
  // both require being called from the thread that owns the window).
  // SetNextFrameCallback may invoke on the raster thread in some Flutter
  // versions, so we just PostMessage to the main thread and let
  // MessageHandler call DismissSplash().
  HWND self = GetHandle();
  flutter_controller_->engine()->SetNextFrameCallback([self]() {
    if (self) PostMessage(self, kSplashDismissMsg, 0, 0);
  });

  // Fallback: if for any reason SetNextFrameCallback never fires, dismiss
  // the splash after a safety interval so the user is never stuck.
  SetTimer(self, kSplashFallbackTimerId, 2500, nullptr);

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Intercept WM_GETOBJECT (a11y / screen reader probe) and return 0
  // to prevent Flutter engine from activating its accessibility_bridge.
  // Known bug: the bridge crashes on complex widget trees
  // (0xc0000005 @ flutter_windows.dll+0x391b6). Desktop tool has weak
  // a11y needs, disable globally for stability.
  if (message == WM_GETOBJECT) {
    return 0;
  }

  // Splash control on the UI thread.
  if (message == kSplashDismissMsg) {
    KillTimer(hwnd, kSplashFallbackTimerId);
    DismissSplash();
    return 0;
  }
  if (message == WM_TIMER && wparam == kSplashFallbackTimerId) {
    KillTimer(hwnd, kSplashFallbackTimerId);
    DismissSplash();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
