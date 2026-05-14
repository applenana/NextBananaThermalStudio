/// 串口连接条 - 现代扁平化风格.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _ports = SerialService.listPorts();
      if (_selected == null || !_ports.any((p) => p.name == _selected)) {
        _selected = _ports.isNotEmpty ? _ports.first.name : null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final connected = app.status == ConnectionStatus.connected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // 端口选择
            Icon(Icons.usb_rounded, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Container(
              constraints: const BoxConstraints(maxWidth: 320, minWidth: 200),
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
                  onChanged:
                      connected ? null : (v) => setState(() => _selected = v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _IconChip(
              icon: Icons.refresh_rounded,
              onTap: connected ? null : _refresh,
              tooltip: '刷新端口列表',
            ),
            const SizedBox(width: 16),

            // 波特率
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
                      .map((b) =>
                          DropdownMenuItem(value: b, child: Text('$b')))
                      .toList(),
                  onChanged:
                      connected ? null : (v) => setState(() => _baud = v!),
                ),
              ),
            ),
            const SizedBox(width: 16),

            // 连接按钮
            FilledButton.icon(
              onPressed: () async {
                if (connected) {
                  await app.disconnect();
                } else if (_selected != null) {
                  await app.connect(_selected!, baud: _baud);
                }
              },
              icon: Icon(
                connected ? Icons.link_off_rounded : Icons.bolt_rounded,
                size: 18,
              ),
              label: Text(connected ? '断开' : '连接'),
              style: FilledButton.styleFrom(
                backgroundColor:
                    connected ? scheme.errorContainer : scheme.primary,
                foregroundColor:
                    connected ? scheme.onErrorContainer : scheme.onPrimary,
              ),
            ),

            const Spacer(),

            _StatusBadge(status: app.status),
            if (app.deviceSerial != null) ...[
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.numbers_rounded,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      app.deviceSerial!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (app.deviceInfo != null) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: app.isActivated
                      ? Colors.green.withValues(alpha: 0.18)
                      : Colors.orange.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      app.isActivated
                          ? Icons.check_circle_rounded
                          : Icons.lock_outline_rounded,
                      size: 14,
                      color: app.isActivated ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      app.isActivated ? '已激活' : '未激活',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: app.isActivated ? Colors.green : Colors.orange,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
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
