/// 串口连接条 - 现代扁平化风格.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart' show appConnectionBarExpanded;
import '../serial/serial_service.dart';

class ConnectionBar extends StatefulWidget {
  const ConnectionBar({super.key});

  @override
  State<ConnectionBar> createState() => _ConnectionBarState();
}

class _ConnectionBarState extends State<ConnectionBar> {
  List<SerialPortInfo> _ports = [];
  String? _selected;
  int _baud = 115200;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 启动后自动搜索一次, 让用户开箱即用. 延迟 600ms 给窗口完成首帧 +
    // 让 native serialport 完成初始化, 避免与 splash 拆除阶段抢资源.
    // 仅桌面自动搜索; Android 走 USB Host 需用户主动点「自动」触发权限弹窗.
    if (!Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (!mounted) return;
          final app = context.read<AppState>();
          if (app.status == ConnectionStatus.disconnected) {
            app.autoSearchAndConnect(baud: _baud).then((ok) {
              if (ok && mounted) {
                setState(() => _selected = app.currentPort);
              }
            });
          }
        });
      });
    }
  }

  /// 刷新端口列表. Android 上用 USB Host 枚举 (异步); 桌面同步枚举足够快.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final list = Platform.isAndroid
          ? await SerialService.listPortsAsync()
          : SerialService.listPorts();
      if (!mounted) return;
      setState(() {
        _ports = list;
        if (_selected == null || !_ports.any((p) => p.name == _selected)) {
          _selected = _ports.isNotEmpty ? _ports.first.name : null;
        }
      });
    } finally {
      _refreshing = false;
    }
  }

  /// 设备信息行折叠状态 (Android 默认折叠以节省垂直空间).
  bool _deviceInfoExpanded = false;

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return _buildAndroid(context);
    return _buildDesktop(context);
  }

  // ====== Android: 可折叠外壳 + 紧凑两行实体 ======
  Widget _buildAndroid(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appConnectionBarExpanded,
      builder: (context, expanded, _) {
        return AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? _buildAndroidExpanded(context)
              : _buildAndroidCollapsedBar(context),
        );
      },
    );
  }

  /// 折叠态: 单行小条, 点击展开.
  Widget _buildAndroidCollapsedBar(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final connected = app.status == ConnectionStatus.connected;
    final label = switch (app.status) {
      ConnectionStatus.connected => '已连接 · ${app.currentPort ?? ""}',
      ConnectionStatus.connecting => '连接中…',
      ConnectionStatus.scanning => '搜索中…',
      _ => '未连接 · 点击展开',
    };
    return InkWell(
      key: const ValueKey('conn-collapsed'),
      onTap: () => appConnectionBarExpanded.value = true,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              connected
                  ? Icons.usb_rounded
                  : Icons.usb_off_rounded,
              size: 16,
              color: connected
                  ? Colors.green
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              '串口连接',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ),
            Text(
              '点击展开',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 展开态: 现有紧凑视图 + 右上角收起按钮.
  Widget _buildAndroidExpanded(BuildContext context) {
    return Stack(
      key: const ValueKey('conn-expanded'),
      children: [
        _buildAndroidContent(context),
        Positioned(
          right: 4,
          top: 4,
          child: IconButton(
            tooltip: '收起',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: () => appConnectionBarExpanded.value = false,
            icon: const Icon(Icons.expand_less_rounded),
          ),
        ),
      ],
    );
  }

  // ====== Android: 原紧凑两行 (端口+状态 / 刷新+自动+连接) + 可折叠设备信息 ======
  Widget _buildAndroidContent(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final connected = app.status == ConnectionStatus.connected;
    final hasDeviceInfo = app.deviceSerial != null ||
        app.deviceInfo != null ||
        app.activateTime != null ||
        app.warrantyTime != null;
    final isBusy = app.status == ConnectionStatus.scanning ||
        app.status == ConnectionStatus.connecting;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 行 1: USB 图标 + 端口下拉 (撑满) + 状态徽章
            Row(
              children: [
                Icon(Icons.usb_rounded,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        isDense: true,
                        value: _selected,
                        hint: const Text('点「自动」搜索设备',
                            style: TextStyle(fontSize: 12)),
                        items: _ports
                            .map((p) => DropdownMenuItem(
                                  value: p.name,
                                  child: Text(
                                    p.description.isEmpty
                                        ? p.name
                                        : '${p.name} · ${p.description}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ))
                            .toList(),
                        onChanged: connected
                            ? null
                            : (v) => setState(() => _selected = v),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: app.status),
              ],
            ),
            const SizedBox(height: 8),
            // 行 2: 刷新 + 自动 + 连接/断开 (主按钮)
            Row(
              children: [
                _IconChip(
                  icon: Icons.refresh_rounded,
                  onTap: connected || isBusy ? null : _refresh,
                  tooltip: '刷新',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: (connected || isBusy)
                        ? null
                        : () async {
                            final ok =
                                await app.autoSearchAndConnect(baud: _baud);
                            if (ok && mounted) {
                              setState(() => _selected = app.currentPort);
                            }
                          },
                    icon: app.status == ConnectionStatus.scanning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: Text(app.status == ConnectionStatus.scanning
                        ? '搜索中…'
                        : '自动'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isBusy
                        ? null
                        : () async {
                            if (connected) {
                              await app.disconnect();
                            } else if (_selected != null) {
                              await app.connect(_selected!, baud: _baud);
                            }
                          },
                    icon: Icon(
                      connected ? Icons.link_off_rounded : Icons.bolt_rounded,
                      size: 16,
                    ),
                    label: Text(connected ? '断开' : '连接'),
                    style: FilledButton.styleFrom(
                      backgroundColor: connected
                          ? scheme.errorContainer
                          : scheme.primary,
                      foregroundColor: connected
                          ? scheme.onErrorContainer
                          : scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
            // 设备信息行 (默认折叠, 已连接且有信息时显示展开按钮)
            if (hasDeviceInfo) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => setState(
                    () => _deviceInfoExpanded = !_deviceInfoExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        _deviceInfoExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _deviceInfoExpanded ? '收起设备信息' : '设备信息',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      if (!_deviceInfoExpanded && app.deviceSerial != null)
                        Text(
                          'SN ${app.deviceSerial!}',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
              if (_deviceInfoExpanded) ...[
                const SizedBox(height: 6),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (app.deviceSerial != null)
                      _InfoPill(
                        icon: Icons.numbers_rounded,
                        label: '序列号',
                        value: app.deviceSerial!,
                        mono: true,
                      ),
                    if (app.deviceInfo != null)
                      _InfoPill(
                        icon: app.isActivated
                            ? Icons.check_circle_rounded
                            : Icons.lock_outline_rounded,
                        label: '激活',
                        value: app.isActivated ? '已激活' : '未激活',
                        color: app.isActivated ? Colors.green : Colors.orange,
                      ),
                    if (app.activateTime != null &&
                        app.activateTime!.isNotEmpty)
                      _InfoPill(
                        icon: Icons.event_available_rounded,
                        label: '激活时间',
                        value: app.activateTime!,
                      ),
                    if (app.warrantyTime != null &&
                        app.warrantyTime!.isNotEmpty)
                      _InfoPill(
                        icon: Icons.verified_user_rounded,
                        label: '保修截止',
                        value: app.warrantyTime!,
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final connected = app.status == ConnectionStatus.connected;

    return SizedBox(
      width: double.infinity,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ===== 第 1 行: 端口 / 刷新 / 自动 / 波特率 / 连接 / 状态 =====
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.usb_rounded,
                          size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Container(
                        constraints: const BoxConstraints(
                            maxWidth: 320, minWidth: 140),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            isDense: true,
                            value: _selected,
                            hint: const Text('选择端口'),
                            items: _ports
                                .map((p) => DropdownMenuItem(
                                      value: p.name,
                                      child: Text(
                                        p.description.isEmpty
                                            ? p.name
                                            : '${p.name} · ${p.description}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ))
                                .toList(),
                            onChanged: connected
                                ? null
                                : (v) => setState(() => _selected = v),
                          ),
                        ),
                      ),
                    ],
                  ),
                  _IconChip(
                    icon: Icons.refresh_rounded,
                    onTap: connected ? null : _refresh,
                    tooltip: '刷新端口列表',
                  ),
                  FilledButton.tonalIcon(
                    onPressed: (connected ||
                            app.status == ConnectionStatus.scanning ||
                            app.status == ConnectionStatus.connecting)
                        ? null
                        : () async {
                            final ok =
                                await app.autoSearchAndConnect(baud: _baud);
                            if (ok && mounted) {
                              setState(() => _selected = app.currentPort);
                            }
                          },
                    icon: app.status == ConnectionStatus.scanning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: Text(app.status == ConnectionStatus.scanning
                        ? '搜索中…'
                        : '自动'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('波特率',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          )),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _baud,
                            isDense: true,
                            items: const [
                              9600,
                              19200,
                              38400,
                              57600,
                              115200,
                              230400,
                              460800,
                              921600,
                              1000000,
                            ]
                                .map((b) => DropdownMenuItem(
                                    value: b, child: Text('$b')))
                                .toList(),
                            onChanged: connected
                                ? null
                                : (v) => setState(() => _baud = v!),
                          ),
                        ),
                      ),
                    ],
                  ),
                  FilledButton.icon(
                    onPressed: () async {
                      if (connected) {
                        await app.disconnect();
                      } else if (_selected != null) {
                        await app.connect(_selected!, baud: _baud);
                      }
                    },
                    icon: Icon(
                      connected
                          ? Icons.link_off_rounded
                          : Icons.bolt_rounded,
                      size: 18,
                    ),
                    label: Text(connected ? '断开' : '连接'),
                    style: FilledButton.styleFrom(
                      backgroundColor: connected
                          ? scheme.errorContainer
                          : scheme.primary,
                      foregroundColor: connected
                          ? scheme.onErrorContainer
                          : scheme.onPrimary,
                    ),
                  ),
                  _StatusBadge(status: app.status),
                ],
              ),

              // ===== 第 2 行: 序列号 / 激活状态 / 激活时间 / 保修时间 =====
              if (app.deviceSerial != null ||
                  app.deviceInfo != null ||
                  app.activateTime != null ||
                  app.warrantyTime != null) ...[
                const SizedBox(height: 10),
                Divider(
                    height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
                const SizedBox(height: 10),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (app.deviceSerial != null)
                      _InfoPill(
                        icon: Icons.numbers_rounded,
                        label: '序列号',
                        value: app.deviceSerial!,
                        mono: true,
                      ),
                    if (app.deviceInfo != null)
                      _InfoPill(
                        icon: app.isActivated
                            ? Icons.check_circle_rounded
                            : Icons.lock_outline_rounded,
                        label: '激活状态',
                        value: app.isActivated ? '已激活' : '未激活',
                        color: app.isActivated ? Colors.green : Colors.orange,
                      ),
                    if (app.activateTime != null &&
                        app.activateTime!.isNotEmpty)
                      _InfoPill(
                        icon: Icons.event_available_rounded,
                        label: '激活时间',
                        value: app.activateTime!,
                      ),
                    if (app.warrantyTime != null &&
                        app.warrantyTime!.isNotEmpty)
                      _InfoPill(
                        icon: Icons.verified_user_rounded,
                        label: '保修截止',
                        value: app.warrantyTime!,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  const _IconChip({required this.icon, this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    Widget btn = Material(
      color: enabled
          ? scheme.surfaceContainerHigh
          : scheme.surfaceContainerHigh.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? scheme.onSurfaceVariant
                : scheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
    if (tooltip != null) btn = Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}

class _StatusBadge extends StatelessWidget {
  final ConnectionStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    IconData icon;
    switch (status) {
      case ConnectionStatus.disconnected:
        label = '未连接';
        color = Colors.grey;
        icon = Icons.power_off_rounded;
        break;
      case ConnectionStatus.scanning:
        label = '扫描中';
        color = Colors.blue;
        icon = Icons.search_rounded;
        break;
      case ConnectionStatus.connecting:
        label = '连接中';
        color = Colors.blue;
        icon = Icons.cable_rounded;
        break;
      case ConnectionStatus.connected:
        label = '已连接';
        color = Colors.green;
        icon = Icons.power_rounded;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              )),
        ],
      ),
    );
  }
}

/// 设备信息小药丸: [图标][标签:][值]. 用于第二行序列号/激活时间等展示.
class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool mono;
  final Color? color;
  const _InfoPill({
    required this.icon,
    required this.label,
    required this.value,
    this.mono = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = (color ?? scheme.onSurface).withValues(alpha: 0.10);
    final fg = color ?? scheme.onSurface;
    final muted = color?.withValues(alpha: 0.85) ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text('$label:',
              style: TextStyle(
                fontSize: 11,
                color: muted,
                fontWeight: FontWeight.w500,
              )),
          const SizedBox(width: 4),
          Text(value,
              style: TextStyle(
                fontSize: 12,
                color: fg,
                fontWeight: FontWeight.w600,
                fontFamily: mono ? 'monospace' : null,
              )),
        ],
      ),
    );
  }
}
