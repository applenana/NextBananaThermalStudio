/// 图库主 tab 容器: 内部副 tab 切换「设备图库 / 软件图库」.
///
/// - 设备图库 = 既有 PhotoDownloadTab (从硬件设备下载 jpg 图片)
/// - 软件图库 = 本机 .btpkg (软件端拍摄/录制的原始数据包)
///
/// 平台差异:
///   - Android: 走 PageView, 支持左右滑动切换. 每次切换 (无论手势还是点击
///     SegmentedButton) 都会触发已打开的图片/数据包详情自动关闭, 让用户
///     落回到列表页, 避免"切过去看到的还是上次的详情".
///   - 桌面: 保持 IndexedStack, 不启用滑动 (鼠标拖拽与详情内交互冲突).
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../main.dart' show appClosePhotoDetail, appCloseSoftwareDetail;
import 'photo_download_tab.dart';
import 'software_gallery_tab.dart';

class GalleryShell extends StatefulWidget {
  const GalleryShell({super.key});
  @override
  State<GalleryShell> createState() => _GalleryShellState();
}

class _GalleryShellState extends State<GalleryShell> {
  int _sub = 0;
  late final PageController _pageCtrl = PageController(initialPage: 0);

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 切换 sub-tab 公共入口: 关闭两个 tab 可能打开的详情页, 同步页面控制器
  /// 与 SegmentedButton 选中态. 软件图库刷新仍在副 tab 切到"软件图库"时触发.
  void _switchSub(int next, {bool animate = true}) {
    if (next != _sub) {
      // 先关闭两个 tab 各自的详情 (无害: 内部判断是否真的打开).
      appClosePhotoDetail?.call();
      appCloseSoftwareDetail?.call();
      setState(() => _sub = next);
      if (next == 1) {
        softwareGalleryRefreshTrigger.value++;
      }
    }
    if (_pageCtrl.hasClients && _pageCtrl.page?.round() != next) {
      if (animate) {
        _pageCtrl.animateToPage(
          next,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _pageCtrl.jumpToPage(next);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAndroid = Platform.isAndroid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('设备图库'),
                icon: Icon(Icons.usb_rounded, size: 16),
              ),
              ButtonSegment(
                value: 1,
                label: Text('软件图库'),
                icon: Icon(Icons.folder_special_rounded, size: 16),
              ),
            ],
            selected: {_sub},
            showSelectedIcon: false,
            onSelectionChanged: (s) => _switchSub(s.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
              // 去掉默认 outline (用户反馈"黑框"过重),
              // 走纯填充态 + 圆角, 与 Material 3 secondary tab 风格一致.
              side: const WidgetStatePropertyAll(BorderSide.none),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return scheme.primaryContainer;
                }
                return scheme.surfaceContainerHigh;
              }),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: isAndroid
              ? PageView(
                  controller: _pageCtrl,
                  physics: const ClampingScrollPhysics(),
                  onPageChanged: (i) {
                    if (i == _sub) return;
                    appClosePhotoDetail?.call();
                    appCloseSoftwareDetail?.call();
                    setState(() => _sub = i);
                    if (i == 1) {
                      softwareGalleryRefreshTrigger.value++;
                    }
                  },
                  children: const [
                    _KeepAlive(child: PhotoDownloadTab()),
                    _KeepAlive(child: SoftwareGalleryTab()),
                  ],
                )
              : IndexedStack(
                  index: _sub,
                  children: const [
                    PhotoDownloadTab(),
                    SoftwareGalleryTab(),
                  ],
                ),
        ),
      ],
    );
  }
}

/// PageView 默认按需 build/dispose 非当前页, 这里包一层让两个 tab 始终保活,
/// 避免设备图库的连接 / 列表 / 选中态在滑走后丢失.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
