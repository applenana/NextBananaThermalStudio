import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../audio/temperature_alarm_audio.dart';
import '../protocol/temperature_alarm.dart';
import 'banana_toast.dart';

/// Persistent, app-wide alarm banner. It cannot be dismissed locally while an
/// alarm is active; acknowledgement is sent back to the thermal device so the
/// screen, host and dedicated buzzer module remain in the same state.
class TemperatureAlarmBanner extends StatefulWidget {
  const TemperatureAlarmBanner({super.key});

  @override
  State<TemperatureAlarmBanner> createState() => _TemperatureAlarmBannerState();
}

class _TemperatureAlarmBannerState extends State<TemperatureAlarmBanner> {
  int _lastTransitionSerial = -1;
  bool _ackBusy = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (_lastTransitionSerial != app.alarmTransitionSerial) {
      final previous = _lastTransitionSerial;
      _lastTransitionSerial = app.alarmTransitionSerial;
      if (app.anyTemperatureAlarmActive &&
          (previous >= 0 || app.alarmTransitionSerial > 0)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          HapticFeedback.heavyImpact();
        });
      }
    }
    if (!app.anyTemperatureAlarmActive) return const SizedBox.shrink();

    final high = app.highAlarmActive;
    final low = app.lowAlarmActive;
    final color = high ? const Color(0xFFD32F2F) : const Color(0xFF1565C0);
    final title = high && low
        ? '过热与过冷报警'
        : high
        ? '过热报警'
        : '过冷报警';
    final detail = <String>[
      if (high)
        '最高 ${app.highAlarmTemperature?.toStringAsFixed(1) ?? app.tMax.toStringAsFixed(1)} °C',
      if (low)
        '最低 ${app.lowAlarmTemperature?.toStringAsFixed(1) ?? app.tMin.toStringAsFixed(1)} °C',
    ].join('  ·  ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.white,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  detail,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _ackBusy
                ? null
                : () async {
                    setState(() => _ackBusy = true);
                    try {
                      await app.acknowledgeTemperatureAlarm();
                      if (context.mounted) {
                        BananaToast.show(
                          context,
                          '报警已确认；温度回到迟滞恢复区前不会再次触发',
                          icon: Icons.notifications_paused_rounded,
                        );
                      }
                    } catch (error) {
                      if (context.mounted) {
                        BananaToast.show(
                          context,
                          error.toString(),
                          icon: Icons.error_outline_rounded,
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _ackBusy = false);
                    }
                  },
            icon: _ackBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.done_all_rounded, size: 18),
            label: const Text('确认报警'),
          ),
        ],
      ),
    );
  }
}

class TemperatureAlarmSettingsControl extends StatefulWidget {
  const TemperatureAlarmSettingsControl({super.key});

  @override
  State<TemperatureAlarmSettingsControl> createState() =>
      _TemperatureAlarmSettingsControlState();
}

class _TemperatureAlarmSettingsControlState
    extends State<TemperatureAlarmSettingsControl> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(AppState app) action) async {
    if (_busy) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await action(app);
    } catch (error) {
      if (mounted) {
        BananaToast.show(
          context,
          error.toString(),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(AppState app) async {
    final current = await app.fetchTemperatureAlarmConfig();
    if (!mounted) return;
    final updated = await showDialog<TemperatureAlarmConfig>(
      context: context,
      builder: (_) => _TemperatureAlarmConfigDialog(initial: current),
    );
    if (updated == null) return;
    await app.applyTemperatureAlarmConfig(updated);
    if (mounted) {
      BananaToast.show(
        context,
        '报警参数已写入并持久化到热成像设备',
        icon: Icons.verified_rounded,
      );
    }
  }

  Future<void> _reset(AppState app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.restore_rounded),
        title: const Text('恢复设备报警默认值？'),
        content: const Text('总开关、过热和过冷报警都会关闭；阈值与时序恢复为安全初始值。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await app.resetTemperatureAlarmConfig();
    if (mounted) BananaToast.show(context, '设备报警配置已恢复默认');
  }

  Future<void> _connectModule(AppState app) async {
    final ports = await app.listAlarmModulePorts();
    if (!mounted) return;
    if (ports.isEmpty) throw StateError('未发现可用的 USB 蜂鸣器串口');
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择 USB 蜂鸣器模块'),
        children: [
          for (final port in ports)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, port.name),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      port.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (port.description.isNotEmpty)
                      Text(
                        port.description,
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (selected == null) return;
    await app.connectAlarmModule(selected);
    if (mounted) {
      BananaToast.show(
        context,
        '蜂鸣器模块已连接；当前报警状态已同步',
        icon: Icons.speaker_rounded,
      );
    }
  }

  Widget _audioSettings(AppState app) {
    final sound = app.temperatureAlarmSound;
    final volumePercent = (app.temperatureAlarmVolume * 100).round();
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.volume_up_rounded, size: 21),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '上位机报警音效',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text('$volumePercent%'),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final soundSelector = DropdownButton<TemperatureAlarmSound>(
                  value: sound,
                  isExpanded: true,
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          _run((app) => app.setTemperatureAlarmSound(value));
                        },
                  items: [
                    for (final option in TemperatureAlarmSound.values)
                      DropdownMenuItem(
                        value: option,
                        child: Text(option.label),
                      ),
                  ],
                );
                final volumeSlider = Row(
                  children: [
                    const Icon(Icons.volume_down_rounded, size: 18),
                    Expanded(
                      child: Slider(
                        value: app.temperatureAlarmVolume,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label: '$volumePercent%',
                        onChanged: _busy
                            ? null
                            : (value) {
                                unawaited(
                                  app.setTemperatureAlarmVolume(
                                    value,
                                    persist: false,
                                  ),
                                );
                              },
                        onChangeEnd: _busy
                            ? null
                            : (value) {
                                unawaited(app.setTemperatureAlarmVolume(value));
                              },
                      ),
                    ),
                    const Icon(Icons.volume_up_rounded, size: 18),
                  ],
                );
                if (constraints.maxWidth < 520) {
                  return Column(children: [soundSelector, volumeSlider]);
                }
                return Row(
                  children: [
                    SizedBox(width: 220, child: soundSelector),
                    const SizedBox(width: 12),
                    Expanded(child: volumeSlider),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed:
                      _busy ||
                          app.anyTemperatureAlarmActive ||
                          sound == TemperatureAlarmSound.silent
                      ? null
                      : () => _run((app) => app.previewTemperatureAlarmSound()),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('试听'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    app.anyTemperatureAlarmActive
                        ? '报警活动期间循环播放，确认或解除后停止'
                        : app.temperatureAlarmAudioReady
                        ? '设置保存在本机；Android 使用系统报警音量通道'
                        : '正在初始化音频输出…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (app.temperatureAlarmAudioError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  error,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final config = app.temperatureAlarmConfig;
    final connected = app.status == ConnectionStatus.connected;
    final statusText = config == null
        ? connected
              ? '尚未同步设备参数'
              : '连接设备后可同步和修改'
        : !config.masterEnabled
        ? '总开关关闭'
        : [
            if (config.highEnabled)
              '过热 ${config.highThreshold.toStringAsFixed(1)} °C',
            if (config.lowEnabled)
              '过冷 ${config.lowThreshold.toStringAsFixed(1)} °C',
            if (!config.highEnabled && !config.lowEnabled) '未启用过热/过冷分项',
          ].join('  ·  ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              app.anyTemperatureAlarmActive
                  ? Icons.warning_amber_rounded
                  : config?.masterEnabled == true
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_off_outlined,
              color: app.anyTemperatureAlarmActive
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(statusText)),
            if (_busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _audioSettings(app),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              app.alarmModuleConnected
                  ? Icons.speaker_rounded
                  : Icons.speaker_outlined,
              size: 20,
              color: app.alarmModuleConnected
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                app.alarmModuleConnected
                    ? 'USB 蜂鸣器：${app.alarmModulePort} @ ${app.alarmModuleBaud}'
                    : app.alarmModuleLastError == null
                    ? 'USB 蜂鸣器：未连接（可选）'
                    : 'USB 蜂鸣器：未连接 · ${app.alarmModuleLastError}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: !connected || _busy ? null : () => _run(_edit),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('配置报警'),
            ),
            OutlinedButton.icon(
              onPressed: !connected || _busy
                  ? null
                  : () => _run((app) async {
                      await app.fetchTemperatureAlarmConfig();
                      if (context.mounted) {
                        BananaToast.show(context, '设备报警参数已同步');
                      }
                    }),
              icon: const Icon(Icons.sync_rounded, size: 18),
              label: const Text('同步参数'),
            ),
            OutlinedButton.icon(
              onPressed: !connected || _busy ? null : () => _run(_reset),
              icon: const Icon(Icons.restore_rounded, size: 18),
              label: const Text('恢复默认'),
            ),
            if (app.anyTemperatureAlarmActive)
              FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _run((app) async {
                        await app.acknowledgeTemperatureAlarm();
                      }),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: const Text('确认当前报警'),
              ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : app.alarmModuleConnected
                  ? () => _run((app) async {
                      await app.disconnectAlarmModule();
                      if (context.mounted) {
                        BananaToast.show(context, 'USB 蜂鸣器模块已断开');
                      }
                    })
                  : () => _run(_connectModule),
              icon: Icon(
                app.alarmModuleConnected
                    ? Icons.link_off_rounded
                    : Icons.usb_rounded,
                size: 18,
              ),
              label: Text(app.alarmModuleConnected ? '断开蜂鸣器' : '连接蜂鸣器'),
            ),
          ],
        ),
      ],
    );
  }
}

class _TemperatureAlarmConfigDialog extends StatefulWidget {
  final TemperatureAlarmConfig initial;
  const _TemperatureAlarmConfigDialog({required this.initial});

  @override
  State<_TemperatureAlarmConfigDialog> createState() =>
      _TemperatureAlarmConfigDialogState();
}

class _TemperatureAlarmConfigDialogState
    extends State<_TemperatureAlarmConfigDialog> {
  late bool _master;
  late bool _highEnabled;
  late bool _lowEnabled;
  late bool _latched;
  late final TextEditingController _highThreshold;
  late final TextEditingController _lowThreshold;
  late final TextEditingController _highHysteresis;
  late final TextEditingController _lowHysteresis;
  late final TextEditingController _triggerDelay;
  late final TextEditingController _clearDelay;
  late final TextEditingController _repeat;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _master = c.masterEnabled;
    _highEnabled = c.highEnabled;
    _lowEnabled = c.lowEnabled;
    _latched = c.latched;
    _highThreshold = TextEditingController(
      text: c.highThreshold.toStringAsFixed(1),
    );
    _lowThreshold = TextEditingController(
      text: c.lowThreshold.toStringAsFixed(1),
    );
    _highHysteresis = TextEditingController(
      text: c.highHysteresis.toStringAsFixed(1),
    );
    _lowHysteresis = TextEditingController(
      text: c.lowHysteresis.toStringAsFixed(1),
    );
    _triggerDelay = TextEditingController(text: c.triggerDelayMs.toString());
    _clearDelay = TextEditingController(text: c.clearDelayMs.toString());
    _repeat = TextEditingController(text: c.repeatMs.toString());
  }

  @override
  void dispose() {
    _highThreshold.dispose();
    _lowThreshold.dispose();
    _highHysteresis.dispose();
    _lowHysteresis.dispose();
    _triggerDelay.dispose();
    _clearDelay.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Widget _numberField(
    TextEditingController controller,
    String label,
    String suffix, {
    bool integer = false,
  }) => TextField(
    controller: controller,
    keyboardType: TextInputType.numberWithOptions(
      decimal: !integer,
      signed: !integer,
    ),
    decoration: InputDecoration(labelText: label, suffixText: suffix),
  );

  TemperatureAlarmConfig? _readConfig() {
    final config = widget.initial.copyWith(
      masterEnabled: _master,
      highEnabled: _highEnabled,
      highThreshold: double.tryParse(_highThreshold.text.trim()),
      lowEnabled: _lowEnabled,
      lowThreshold: double.tryParse(_lowThreshold.text.trim()),
      highHysteresis: double.tryParse(_highHysteresis.text.trim()),
      lowHysteresis: double.tryParse(_lowHysteresis.text.trim()),
      triggerDelayMs: int.tryParse(_triggerDelay.text.trim()),
      clearDelayMs: int.tryParse(_clearDelay.text.trim()),
      latched: _latched,
      repeatMs: int.tryParse(_repeat.text.trim()),
    );
    // copyWith intentionally treats null as "keep old". Detect malformed text
    // explicitly so a typo can never silently submit the previous value.
    if (double.tryParse(_highThreshold.text.trim()) == null ||
        double.tryParse(_lowThreshold.text.trim()) == null ||
        double.tryParse(_highHysteresis.text.trim()) == null ||
        double.tryParse(_lowHysteresis.text.trim()) == null ||
        int.tryParse(_triggerDelay.text.trim()) == null ||
        int.tryParse(_clearDelay.text.trim()) == null ||
        int.tryParse(_repeat.text.trim()) == null) {
      _error = '请检查所有数值输入';
      return null;
    }
    _error = config.validationError;
    return _error == null ? config : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.device_thermostat_rounded),
      title: const Text('设备温度报警'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('报警总开关'),
                subtitle: const Text('默认关闭；关闭后立即向报警模块发送解除事件'),
                value: _master,
                onChanged: (value) => setState(() => _master = value),
              ),
              const SizedBox(height: 8),
              _AlarmChannelCard(
                title: '过热报警',
                icon: Icons.local_fire_department_rounded,
                color: const Color(0xFFD32F2F),
                enabled: _highEnabled,
                onEnabled: (value) => setState(() => _highEnabled = value),
                threshold: _numberField(_highThreshold, '过热门槛', '°C'),
                hysteresis: _numberField(_highHysteresis, '恢复迟滞', '°C'),
              ),
              const SizedBox(height: 8),
              _AlarmChannelCard(
                title: '过冷报警',
                icon: Icons.ac_unit_rounded,
                color: const Color(0xFF1565C0),
                enabled: _lowEnabled,
                onEnabled: (value) => setState(() => _lowEnabled = value),
                threshold: _numberField(_lowThreshold, '过冷门槛', '°C'),
                hysteresis: _numberField(_lowHysteresis, '恢复迟滞', '°C'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _numberField(
                      _triggerDelay,
                      '触发确认时间',
                      'ms',
                      integer: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _numberField(
                      _clearDelay,
                      '恢复确认时间',
                      'ms',
                      integer: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _numberField(_repeat, '活动报警重复上报间隔（0 = 关闭）', 'ms', integer: true),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('锁存模式'),
                subtitle: const Text('触发后必须在设备或上位机人工确认；确认后需先回到迟滞恢复区才会重新布防'),
                value: _latched,
                onChanged: (value) => setState(() => _latched = value),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () {
            final config = _readConfig();
            if (config == null) {
              setState(() {});
              return;
            }
            Navigator.pop(context, config);
          },
          icon: const Icon(Icons.save_rounded, size: 18),
          label: const Text('写入并保存'),
        ),
      ],
    );
  }
}

class _AlarmChannelCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final bool enabled;
  final ValueChanged<bool> onEnabled;
  final Widget threshold;
  final Widget hysteresis;

  const _AlarmChannelCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onEnabled,
    required this.threshold,
    required this.hysteresis,
  });

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Switch(value: enabled, onChanged: onEnabled),
              ],
            ),
            Row(
              children: [
                Expanded(child: threshold),
                const SizedBox(width: 10),
                Expanded(child: hysteresis),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
