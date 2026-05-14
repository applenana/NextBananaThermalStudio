/// 通过 dart:ffi 直接调 Win32 SetWindowPos 改窗口尺寸,
/// 不引入 window_manager 等会与串口插件冲突的 native plugin.
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

// HWND FindWindowW(LPCWSTR lpClassName, LPCWSTR lpWindowName)
typedef _FindWindowWNative = IntPtr Function(
    Pointer<Utf16> className, Pointer<Utf16> windowName);
typedef _FindWindowWDart = int Function(
    Pointer<Utf16> className, Pointer<Utf16> windowName);

// BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT)
typedef _SetWindowPosNative = Int32 Function(
    IntPtr hWnd, IntPtr hWndInsertAfter,
    Int32 x, Int32 y, Int32 cx, Int32 cy, Uint32 flags);
typedef _SetWindowPosDart = int Function(
    int hWnd, int hWndInsertAfter,
    int x, int y, int cx, int cy, int flags);

// BOOL GetWindowRect(HWND, LPRECT)
final class _RECT extends Struct {
  @Int32() external int left;
  @Int32() external int top;
  @Int32() external int right;
  @Int32() external int bottom;
}
typedef _GetWindowRectNative = Int32 Function(IntPtr hWnd, Pointer<_RECT> rect);
typedef _GetWindowRectDart = int Function(int hWnd, Pointer<_RECT> rect);

// BOOL ShowWindow(HWND, int)
typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 cmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int cmdShow);

// BOOL ReleaseCapture()
typedef _ReleaseCaptureNative = Int32 Function();
typedef _ReleaseCaptureDart = int Function();

// LRESULT SendMessageW(HWND, UINT, WPARAM, LPARAM)
typedef _SendMessageWNative = IntPtr Function(
    IntPtr hWnd, Uint32 msg, IntPtr wParam, IntPtr lParam);
typedef _SendMessageWDart = int Function(
    int hWnd, int msg, int wParam, int lParam);

// BOOL PostMessageW(HWND, UINT, WPARAM, LPARAM)
typedef _PostMessageWNative = Int32 Function(
    IntPtr hWnd, Uint32 msg, IntPtr wParam, IntPtr lParam);
typedef _PostMessageWDart = int Function(
    int hWnd, int msg, int wParam, int lParam);

// BOOL IsZoomed(HWND)
typedef _IsZoomedNative = Int32 Function(IntPtr hWnd);
typedef _IsZoomedDart = int Function(int hWnd);

const int _swpNoMove = 0x0002;
const int _swpNoZOrder = 0x0004;
const int _swpNoActivate = 0x0010;
const int _swShowMaximized = 3;
const int _swMinimize = 6;
const int _swRestore = 9;
const int _wmNcLButtonDown = 0x00A1;
const int _wmClose = 0x0010;
const int _htCaption = 2;

class WindowSizeFfi {
  WindowSizeFfi._() {
    final user32 = DynamicLibrary.open('user32.dll');
    _findWindowW = user32
        .lookup<NativeFunction<_FindWindowWNative>>('FindWindowW')
        .asFunction<_FindWindowWDart>();
    _setWindowPos = user32
        .lookup<NativeFunction<_SetWindowPosNative>>('SetWindowPos')
        .asFunction<_SetWindowPosDart>();
    _getWindowRect = user32
        .lookup<NativeFunction<_GetWindowRectNative>>('GetWindowRect')
        .asFunction<_GetWindowRectDart>();
    _showWindow = user32
        .lookup<NativeFunction<_ShowWindowNative>>('ShowWindow')
        .asFunction<_ShowWindowDart>();
    _releaseCapture = user32
        .lookup<NativeFunction<_ReleaseCaptureNative>>('ReleaseCapture')
        .asFunction<_ReleaseCaptureDart>();
    _sendMessageW = user32
        .lookup<NativeFunction<_SendMessageWNative>>('SendMessageW')
        .asFunction<_SendMessageWDart>();
    _postMessageW = user32
        .lookup<NativeFunction<_PostMessageWNative>>('PostMessageW')
        .asFunction<_PostMessageWDart>();
    _isZoomed = user32
        .lookup<NativeFunction<_IsZoomedNative>>('IsZoomed')
        .asFunction<_IsZoomedDart>();
  }
  static final WindowSizeFfi instance = WindowSizeFfi._();

  late final _FindWindowWDart _findWindowW;
  late final _SetWindowPosDart _setWindowPos;
  late final _GetWindowRectDart _getWindowRect;
  late final _ShowWindowDart _showWindow;
  late final _ReleaseCaptureDart _releaseCapture;
  late final _SendMessageWDart _sendMessageW;
  late final _PostMessageWDart _postMessageW;
  late final _IsZoomedDart _isZoomed;

  /// runner main.cpp 把窗口标题设为 'BananaThermalStudio'.
  static const String _windowTitle = 'BananaThermalStudio';

  int _findHwnd() {
    final title = _windowTitle.toNativeUtf16();
    try {
      return _findWindowW(nullptr, title);
    } finally {
      malloc.free(title);
    }
  }

  /// 设置窗口宽高 (客户区+边框, 单位像素). 返回是否成功.
  bool setSize(int width, int height) {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    return _setWindowPos(
            hwnd, 0, 0, 0, width, height,
            _swpNoMove | _swpNoZOrder | _swpNoActivate) !=
        0;
  }

  /// 读取当前窗口宽高 (像素), 失败返回 null.
  ({int width, int height})? getSize() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return null;
    final rect = calloc<_RECT>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) return null;
      final r = rect.ref;
      return (width: r.right - r.left, height: r.bottom - r.top);
    } finally {
      calloc.free(rect);
    }
  }

  /// 最大化.
  bool maximize() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    _showWindow(hwnd, _swShowMaximized);
    return true;
  }

  /// 还原.
  bool restore() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    _showWindow(hwnd, _swRestore);
    return true;
  }

  /// 最小化.
  bool minimize() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    _showWindow(hwnd, _swMinimize);
    return true;
  }

  /// 当前是否最大化.
  bool isMaximized() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    return _isZoomed(hwnd) != 0;
  }

  /// 在最大化和还原之间切换.
  bool toggleMaximize() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    if (_isZoomed(hwnd) != 0) {
      _showWindow(hwnd, _swRestore);
    } else {
      _showWindow(hwnd, _swShowMaximized);
    }
    return true;
  }

  /// 关闭窗口 (发送 WM_CLOSE, 走标准关闭流程).
  bool close() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    _postMessageW(hwnd, _wmClose, 0, 0);
    return true;
  }

  /// 由 Flutter 端标题栏 onPanStart 调用, 触发系统级窗口拖拽.
  /// 实现方式: ReleaseCapture + SendMessage(WM_NCLBUTTONDOWN, HTCAPTION).
  bool startSystemDrag() {
    final hwnd = _findHwnd();
    if (hwnd == 0) return false;
    _releaseCapture();
    _sendMessageW(hwnd, _wmNcLButtonDown, _htCaption, 0);
    return true;
  }
}
