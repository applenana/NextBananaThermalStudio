#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// ---------------------------------------------------------------------------
// Splash popup: a small, transparent-background, draggable window shown
// while the Flutter engine is booting. Implemented as a standalone WS_POPUP
// using layered window color-key transparency so the rounded card shape
// appears to float on the desktop.
// ---------------------------------------------------------------------------
namespace {

constexpr const wchar_t kSplashClassName[] = L"BananaThermalStudio_Splash";
constexpr int kSplashLogicalWidth = 380;
constexpr int kSplashLogicalHeight = 170;
// Magenta is used as the transparent color key. Any pixel equal to this
// exact color is rendered fully transparent by the compositor.
constexpr COLORREF kSplashKey = RGB(255, 0, 255);

LRESULT CALLBACK SplashWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                               LPARAM lparam) {
  switch (msg) {
    case WM_NCHITTEST:
      // Whole window is draggable.
      return HTCAPTION;
    case WM_ERASEBKGND:
      return 1;
    case WM_TIMER:
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT rc;
      GetClientRect(hwnd, &rc);

      // Fill background with the transparent key color first.
      HBRUSH bg = CreateSolidBrush(kSplashKey);
      FillRect(hdc, &rc, bg);
      DeleteObject(bg);

      // Rounded dark card.
      HBRUSH card = CreateSolidBrush(RGB(0x18, 0x1C, 0x22));
      HPEN border = CreatePen(PS_SOLID, 1, RGB(0x2A, 0x30, 0x38));
      HGDIOBJ old_brush = SelectObject(hdc, card);
      HGDIOBJ old_pen = SelectObject(hdc, border);
      RoundRect(hdc, rc.left + 1, rc.top + 1, rc.right - 1, rc.bottom - 1,
                24, 24);
      SelectObject(hdc, old_brush);
      SelectObject(hdc, old_pen);
      DeleteObject(card);
      DeleteObject(border);

      // Logo placeholder: rounded orange square in the upper-left.
      const int pad = 22;
      const int logo_size = 40;
      int logo_x = rc.left + pad;
      int logo_y = rc.top + pad;
      HBRUSH logo_brush = CreateSolidBrush(RGB(0xFF, 0x8A, 0x65));
      HPEN logo_pen = CreatePen(PS_SOLID, 1, RGB(0xFF, 0x8A, 0x65));
      old_brush = SelectObject(hdc, logo_brush);
      old_pen = SelectObject(hdc, logo_pen);
      RoundRect(hdc, logo_x, logo_y, logo_x + logo_size, logo_y + logo_size,
                14, 14);
      SelectObject(hdc, old_brush);
      SelectObject(hdc, old_pen);
      DeleteObject(logo_brush);
      DeleteObject(logo_pen);

      // Texts.
      SetBkMode(hdc, TRANSPARENT);
      HFONT title_font = CreateFontW(
          -20, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
          CLEARTYPE_QUALITY, VARIABLE_PITCH | FF_SWISS, L"Segoe UI");
      HFONT sub_font = CreateFontW(
          -12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
          CLEARTYPE_QUALITY, VARIABLE_PITCH | FF_SWISS, L"Segoe UI");

      HGDIOBJ old_font = SelectObject(hdc, title_font);
      SetTextColor(hdc, RGB(0xF2, 0xF2, 0xF2));
      RECT title_rc = {logo_x + logo_size + 14, logo_y - 2,
                       rc.right - pad, logo_y + 24};
      DrawTextW(hdc, L"BananaThermalStudio", -1, &title_rc,
                DT_LEFT | DT_TOP | DT_SINGLELINE);

      SelectObject(hdc, sub_font);
      SetTextColor(hdc, RGB(0xAA, 0xAA, 0xB0));
      RECT sub_rc = {logo_x + logo_size + 14, logo_y + 22,
                     rc.right - pad, logo_y + 42};
      DrawTextW(hdc, L"Initializing engine...", -1, &sub_rc,
                DT_LEFT | DT_TOP | DT_SINGLELINE);

      // Indeterminate progress bar at the bottom.
      const int bar_h = 6;
      int bar_x = rc.left + pad;
      int bar_y = rc.bottom - pad - bar_h;
      int bar_w = rc.right - rc.left - pad * 2;
      HBRUSH track = CreateSolidBrush(RGB(0x2A, 0x30, 0x38));
      RECT track_rc = {bar_x, bar_y, bar_x + bar_w, bar_y + bar_h};
      FillRect(hdc, &track_rc, track);
      DeleteObject(track);

      DWORD now = GetTickCount();
      double phase = (now % 1400) / 1400.0;          // 0..1
      double pos = phase < 0.5 ? phase * 2.0         // 0..1
                                : (1.0 - phase) * 2.0;  // ..0
      int seg_w = bar_w * 4 / 10;
      int seg_x = bar_x + static_cast<int>((bar_w - seg_w) * pos);
      HBRUSH indicator = CreateSolidBrush(RGB(0xFF, 0x8A, 0x65));
      RECT seg_rc = {seg_x, bar_y, seg_x + seg_w, bar_y + bar_h};
      FillRect(hdc, &seg_rc, indicator);
      DeleteObject(indicator);

      SelectObject(hdc, old_font);
      DeleteObject(title_font);
      DeleteObject(sub_font);

      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_DESTROY:
      KillTimer(hwnd, 1);
      return 0;
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

HWND CreateSplashWindow() {
  static bool registered = false;
  HINSTANCE hinst = GetModuleHandle(nullptr);
  if (!registered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = SplashWndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = kSplashClassName;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.hIcon = LoadIcon(hinst, MAKEINTRESOURCE(IDI_APP_ICON));
    RegisterClassW(&wc);
    registered = true;
  }

  POINT origin{0, 0};
  HMONITOR mon = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  UINT dpi = FlutterDesktopGetDpiForMonitor(mon);
  double scale = dpi / 96.0;
  int w = static_cast<int>(kSplashLogicalWidth * scale);
  int h = static_cast<int>(kSplashLogicalHeight * scale);

  MONITORINFO mi{sizeof(mi)};
  int x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
  int y = (GetSystemMetrics(SM_CYSCREEN) - h) / 2;
  if (GetMonitorInfoW(mon, &mi)) {
    x = mi.rcWork.left +
        (mi.rcWork.right - mi.rcWork.left - w) / 2;
    y = mi.rcWork.top +
        (mi.rcWork.bottom - mi.rcWork.top - h) / 2;
  }

  HWND hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
      kSplashClassName, L"BananaThermalStudio",
      WS_POPUP, x, y, w, h, nullptr, nullptr, hinst, nullptr);
  if (!hwnd) {
    return nullptr;
  }
  SetLayeredWindowAttributes(hwnd, kSplashKey, 0, LWA_COLORKEY);
  SetTimer(hwnd, 1, 50, nullptr);
  // Use SW_SHOW (activating) so the process holds the foreground privilege
  // while booting. Without it, DismissSplash() would later fail to bring the
  // real main window to the front (Windows foreground-stealing prevention),
  // leaving the user staring at the desktop with only a taskbar icon.
  ShowWindow(hwnd, SW_SHOW);
  SetForegroundWindow(hwnd);
  return hwnd;
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  bool created = OnCreate();
  if (created) {
    // Trigger WM_NCCALCSIZE recalculation so the custom (frameless) NC layout applies.
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                     SWP_NOZORDER | SWP_NOACTIVATE);

    // Remember the intended on-screen rect.
    GetWindowRect(window, &splash_target_rect_);

    // Spawn the transparent draggable splash popup. The main window is
    // moved off-screen (instead of hidden) so the Flutter engine treats
    // it as visible and actually produces the first frame; otherwise the
    // SetNextFrameCallback would never fire and DismissSplash() would
    // never run unless the user manually interacted with the splash.
    splash_hwnd_ = CreateSplashWindow();
    const int w = splash_target_rect_.right - splash_target_rect_.left;
    const int h = splash_target_rect_.bottom - splash_target_rect_.top;
    SetWindowPos(window, nullptr, -32000, -32000, w, h,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(window, SW_SHOWNA);
  }
  return created;
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE: {
      // Remove the system caption: make client area cover the whole NC frame.
      // When maximized we must shrink by frame thickness to keep content on-screen.
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        WINDOWPLACEMENT wp{sizeof(wp)};
        if (GetWindowPlacement(hwnd, &wp) && wp.showCmd == SW_SHOWMAXIMIZED) {
          int frame_x = GetSystemMetrics(SM_CXFRAME) +
                        GetSystemMetrics(SM_CXPADDEDBORDER);
          int frame_y = GetSystemMetrics(SM_CYFRAME) +
                        GetSystemMetrics(SM_CXPADDEDBORDER);
          params->rgrc[0].left += frame_x;
          params->rgrc[0].right -= frame_x;
          params->rgrc[0].top += frame_y;
          params->rgrc[0].bottom -= frame_y;
        }
        return 0;
      }
      break;
    }

    case WM_NCHITTEST: {
      // Custom border resize detection; caption drag is triggered from Dart side via
      // ReleaseCapture + SendMessage(WM_NCLBUTTONDOWN, HTCAPTION).
      POINT cpt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &cpt);
      RECT rc;
      GetClientRect(hwnd, &rc);
      const int b = 6;  // resize edge thickness in client px
      WINDOWPLACEMENT wp{sizeof(wp)};
      bool maximized = GetWindowPlacement(hwnd, &wp) &&
                       wp.showCmd == SW_SHOWMAXIMIZED;
      if (!maximized) {
        bool L = cpt.x < b;
        bool R = cpt.x >= rc.right - b;
        bool T = cpt.y < b;
        bool B = cpt.y >= rc.bottom - b;
        if (T && L) return HTTOPLEFT;
        if (T && R) return HTTOPRIGHT;
        if (B && L) return HTBOTTOMLEFT;
        if (B && R) return HTBOTTOMRIGHT;
        if (L) return HTLEFT;
        if (R) return HTRIGHT;
        if (T) return HTTOP;
        if (B) return HTBOTTOM;
      }
      return HTCLIENT;
    }

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Inset the Flutter child so the outermost edges fall back to the
        // top-level WM_NCHITTEST, which lets users resize from the borders.
        // Skip inset when maximized (no resize possible, and inset would
        // otherwise produce a visible 6px gutter).
        WINDOWPLACEMENT wp{sizeof(wp)};
        const bool maximized = GetWindowPlacement(hwnd, &wp) &&
                               wp.showCmd == SW_SHOWMAXIMIZED;
        const int inset = maximized ? 0 : 6;
        MoveWindow(child_content_,
                   rect.left + inset, rect.top + inset,
                   rect.right - rect.left - inset * 2,
                   rect.bottom - rect.top - inset * 2, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_ERASEBKGND: {
      // Suppress flicker; after first show the Flutter child fully covers
      // the client area so there is nothing to erase.
      return 1;
    }
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  // Same inset as WM_SIZE path so resize edges are reachable at startup.
  WINDOWPLACEMENT wp{sizeof(wp)};
  const bool maximized = GetWindowPlacement(window_handle_, &wp) &&
                         wp.showCmd == SW_SHOWMAXIMIZED;
  const int inset = maximized ? 0 : 6;
  MoveWindow(content, frame.left + inset, frame.top + inset,
             frame.right - frame.left - inset * 2,
             frame.bottom - frame.top - inset * 2, true);

  // NOTE: do NOT hide the child window here. The Flutter engine ties the
  // production of the first frame (and thus SetNextFrameCallback) to the
  // child view being visible. Hiding it caused DismissSplash to never fire
  // until the user manually interacted with the splash window.
  // The top-level window stays hidden until DismissSplash; since the child
  // is parented to it, no pixels reach the screen anyway while splash is up.
  SetFocus(child_content_);
}

void Win32Window::DismissSplash() {
  if (!splash_active_) return;
  splash_active_ = false;
  if (child_content_) {
    ShowWindow(child_content_, SW_SHOW);
  }
  if (window_handle_) {
    const RECT& r = splash_target_rect_;
    const int w = r.right - r.left;
    const int h = r.bottom - r.top;
    if (w > 0 && h > 0) {
      // Move the main window back to its intended on-screen position and
      // show it. SWP_SHOWWINDOW only flips WS_VISIBLE; activation is done
      // explicitly below.
      SetWindowPos(window_handle_, HWND_TOP, r.left, r.top, w, h,
                   SWP_SHOWWINDOW | SWP_NOACTIVATE);
    } else {
      ShowWindow(window_handle_, SW_SHOWNORMAL);
    }

    // Force foreground transfer. Windows blocks SetForegroundWindow when
    // the caller is not in the foreground. We temporarily attach our thread
    // input to the current foreground window's thread, which bypasses the
    // restriction, then detach.
    HWND fg = GetForegroundWindow();
    DWORD fg_thread =
        fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
    DWORD my_thread = GetCurrentThreadId();
    bool attached = false;
    if (fg_thread && fg_thread != my_thread) {
      attached = AttachThreadInput(fg_thread, my_thread, TRUE) != FALSE;
    }
    BringWindowToTop(window_handle_);
    SetForegroundWindow(window_handle_);
    SetActiveWindow(window_handle_);
    SetFocus(window_handle_);
    if (attached) {
      AttachThreadInput(fg_thread, my_thread, FALSE);
    }
  }

  // Destroy splash last so the foreground transfer above can complete with
  // the splash still owning input; otherwise z-order returns to the taskbar
  // / desktop and the main window loses the activation race.
  if (splash_hwnd_) {
    DestroyWindow(splash_hwnd_);
    splash_hwnd_ = nullptr;
  }
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
