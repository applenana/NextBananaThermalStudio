/// 图库主 tab 容器: 内部副 tab 切换「设备图库 / 软件图库」.
///
/// - 设备图库 = 既有 PhotoDownloadTab (从硬件设备下载 jpg 图片)
/// - 软件图库 = 本机 .btpkg (软件端拍摄/录制的原始数据包)
library;

import 'package:flutter/material.dart';

import 'photo_download_tab.dart';
import 'software_gallery_tab.dart';

class GalleryShell extends StatefulWidget {
  const GalleryShell({super.key});
  @override
  State<GalleryShell> createState() => _GalleryShellState();
}

class _GalleryShellState extends State<GalleryShell> {
  int _sub = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
            onSelectionChanged: (s) => setState(() => _sub = s.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
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
