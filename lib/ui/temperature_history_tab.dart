/// 本地温度历史分析栏目。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../main.dart' show appPhotoDownloadDir;
import '../temperature/temperature_history_store.dart';
import '../temperature/temperature_recorder.dart';
import 'banana_toast.dart';
import 'app_font.dart';
import 'temperature_export_dialog.dart';

enum _HistoryDateFilter { all, today, sevenDays, thirtyDays }

class TemperatureHistoryTab extends StatefulWidget {
  const TemperatureHistoryTab({super.key});

  @override
  State<TemperatureHistoryTab> createState() => _TemperatureHistoryTabState();
}

class _TemperatureHistoryTabState extends State<TemperatureHistoryTab> {
  final _store = TemperatureHistoryStore.instance;
  final _searchController = TextEditingController();
  _HistoryDateFilter _dateFilter = _HistoryDateFilter.all;
  String? _selectedId;
  final Set<String> _selectedSessionIds = <String>{};
  bool _selectionMode = false;
  bool _deleting = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    if (_store.sessions.isNotEmpty) _selectedId = _store.sessions.first.id;
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final sessions = _store.sessions;
    if (_selectedId != null &&
        !sessions.any((session) => session.id == _selectedId)) {
      _selectedId = sessions.isEmpty ? null : sessions.first.id;
    }
    _selectedSessionIds.removeWhere(
      (id) => !sessions.any((session) => session.id == id),
    );
    setState(() {});
  }

  List<TemperatureHistorySession> get _filteredSessions {
    final query = _searchController.text.trim().toLowerCase();
    final now = DateTime.now();
    return _store.sessions
        .where((session) {
          if (query.isNotEmpty) {
            final haystack = '${session.name} ${session.deviceSerial ?? ''}'
                .toLowerCase();
            if (!haystack.contains(query)) return false;
          }
          final local = session.startedAt.toLocal();
          return switch (_dateFilter) {
            _HistoryDateFilter.all => true,
            _HistoryDateFilter.today =>
              local.year == now.year &&
                  local.month == now.month &&
                  local.day == now.day,
            _HistoryDateFilter.sevenDays => local.isAfter(
              now.subtract(const Duration(days: 7)),
            ),
            _HistoryDateFilter.thirtyDays => local.isAfter(
              now.subtract(const Duration(days: 30)),
            ),
          };
        })
        .toList(growable: false);
  }

  void _pruneSelectionToFilter() {
    final visibleIds = _filteredSessions.map((session) => session.id).toSet();
    _selectedSessionIds.removeWhere((id) => !visibleIds.contains(id));
  }

  void _onSearchChanged(String _) {
    setState(_pruneSelectionToFilter);
  }

  void _setDateFilter(_HistoryDateFilter value) {
    setState(() {
      _dateFilter = value;
      _pruneSelectionToFilter();
    });
  }

  bool get _allFilteredSelected =>
      _filteredSessions.isNotEmpty &&
      _filteredSessions.every(
        (session) => _selectedSessionIds.contains(session.id),
      );

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedSessionIds.clear();
    });
  }

  void _toggleSessionSelection(String sessionId) {
    setState(() {
      if (!_selectedSessionIds.add(sessionId)) {
        _selectedSessionIds.remove(sessionId);
      }
    });
  }

  void _selectAllFiltered() {
    final filteredIds = _filteredSessions.map((session) => session.id);
    setState(() {
      if (_allFilteredSelected) {
        _selectedSessionIds.removeAll(filteredIds);
      } else {
        _selectedSessionIds.addAll(filteredIds);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedSessionIds.toList(growable: false);
    if (ids.isEmpty || _deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined, size: 32),
        title: Text('删除 ${ids.length} 条历史记录？'),
        content: const Text('所选记录及其原始测温数据将从本地永久删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final includesActive =
        _store.activeSession != null && ids.contains(_store.activeSession!.id);
    setState(() => _deleting = true);
    try {
      if (includesActive) TemperatureRecorder.instance.clearRecords();
      await _store.deleteSessions(ids);
      if (!mounted) return;
      setState(() {
        _selectedSessionIds.clear();
        _selectionMode = false;
      });
      BananaToast.show(
        context,
        '已删除 ${ids.length} 条历史记录',
        icon: Icons.delete_sweep_outlined,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _importJson() async {
    if (_importing) return;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '导入温度历史 JSON',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || !mounted) return;
    setState(() => _importing = true);
    try {
      final selected = result.files.single;
      final contents = selected.bytes != null
          ? utf8.decode(selected.bytes!)
          : selected.path != null
          ? await File(selected.path!).readAsString()
          : throw StateError('无法读取所选文件');
      final session = await _store.importJsonContent(
        contents,
        name: p.basenameWithoutExtension(selected.name),
      );
      if (!mounted) return;
      setState(() => _selectedId = session.id);
      BananaToast.show(
        context,
        '已导入 ${session.sampleCount} 条温度数据',
        icon: Icons.file_download_done_rounded,
      );
    } catch (error) {
      if (mounted) {
        BananaToast.show(
          context,
          '导入失败：$error',
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _finishCurrentSession() async {
    final active = _store.activeSession;
    if (active == null) return;
    await _store.finishActiveSession();
    final recorder = TemperatureRecorder.instance;
    recorder.clearRecords();
    if (!mounted) return;
    final nextLabel = recorder.recordingPaused ? '恢复记录时' : '下一帧';
    BananaToast.show(
      context,
      '“${active.name}”已归档，将在$nextLabel创建新会话',
      icon: Icons.inventory_2_outlined,
    );
  }

  void _openNarrowDetail(TemperatureHistorySession session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('历史分析')),
          body: SafeArea(
            child: _HistorySessionDetail(
              sessionId: session.id,
              onDeleted: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_store.initialized) {
      return _HistoryUnavailable(
        error: _store.lastError,
        onRetry: () async {
          try {
            await _store.initialize();
          } catch (_) {}
          if (mounted) setState(() {});
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final list = _buildSessionPane(context, wide: wide);
        if (!wide) return list;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 350, child: list),
            const SizedBox(width: 12),
            VerticalDivider(
              width: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _selectedId == null
                  ? const _HistoryEmptyDetail()
                  : _HistorySessionDetail(
                      key: ValueKey(_selectedId),
                      sessionId: _selectedId!,
                      onDeleted: () {
                        final remaining = _filteredSessions;
                        setState(
                          () => _selectedId = remaining.isEmpty
                              ? null
                              : remaining.first.id,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSessionPane(BuildContext context, {required bool wide}) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = _filteredSessions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.monitor_heart_outlined, color: scheme.primary),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '温度历史',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  Text('本地会话、趋势复盘与数据分析', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
            if (_store.activeSession != null)
              IconButton.filledTonal(
                tooltip: '保存当前会话并新建',
                onPressed: _finishCurrentSession,
                icon: const Icon(Icons.save_as_rounded, size: 19),
              ),
            const SizedBox(width: 4),
            IconButton.filledTonal(
              tooltip: '导入历史 JSON',
              onPressed: _importing ? null : _importJson,
              icon: _importing
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_download_outlined, size: 19),
            ),
            const SizedBox(width: 4),
            IconButton.filledTonal(
              tooltip: _selectionMode ? '退出批量选择' : '批量管理历史',
              onPressed: _deleting ? null : _toggleSelectionMode,
              icon: Icon(
                _selectionMode ? Icons.close_rounded : Icons.checklist_rounded,
                size: 19,
              ),
            ),
          ],
        ),
        if (!wide && _store.storagePath != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              _store.storagePath!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: '搜索名称或设备序列号',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: () {
                      _searchController.clear();
                      setState(_pruneSelectionToFilter);
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _dateChip(_HistoryDateFilter.all, '全部'),
              _dateChip(_HistoryDateFilter.today, '今天'),
              _dateChip(_HistoryDateFilter.sevenDays, '近 7 天'),
              _dateChip(_HistoryDateFilter.thirtyDays, '近 30 天'),
              const SizedBox(width: 8),
              Text(
                '${sessions.length} 个会话',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
            ],
          ),
        ),
        if (_selectionMode) ...[
          const SizedBox(height: 7),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                spacing: 2,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '已选 ${_selectedSessionIds.length} / ${sessions.length}',
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontSize: 11,
                    ),
                  ),
                  TextButton(
                    onPressed: sessions.isEmpty ? null : _selectAllFiltered,
                    child: Text(_allFilteredSelected ? '取消全选' : '全选当前'),
                  ),
                  TextButton(
                    onPressed: _selectedSessionIds.isEmpty
                        ? null
                        : () => setState(_selectedSessionIds.clear),
                    child: const Text('清空选择'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _selectedSessionIds.isEmpty || _deleting
                        ? null
                        : _deleteSelected,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                    label: const Text('删除'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (_store.lastError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '最近一次存储错误：${_store.lastError}',
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 11),
            ),
          ),
        Expanded(
          child: sessions.isEmpty
              ? const _HistoryEmptyList()
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: sessions.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    return _HistorySessionCard(
                      session: session,
                      selected: wide && session.id == _selectedId,
                      selectionMode: _selectionMode,
                      batchSelected: _selectedSessionIds.contains(session.id),
                      onTap: () {
                        if (_selectionMode) {
                          _toggleSessionSelection(session.id);
                          return;
                        }
                        if (wide) {
                          setState(() => _selectedId = session.id);
                        } else {
                          _openNarrowDetail(session);
                        }
                      },
                      onSelectChanged: (_) =>
                          _toggleSessionSelection(session.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _dateChip(_HistoryDateFilter value, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: _dateFilter == value,
        onSelected: (_) => _setDateFilter(value),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _HistorySessionCard extends StatelessWidget {
  const _HistorySessionCard({
    required this.session,
    required this.selected,
    required this.selectionMode,
    required this.batchSelected,
    required this.onTap,
    required this.onSelectChanged,
  });

  final TemperatureHistorySession session;
  final bool selected;
  final bool selectionMode;
  final bool batchSelected;
  final VoidCallback onTap;
  final ValueChanged<bool?> onSelectChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: batchSelected
          ? scheme.primaryContainer.withValues(alpha: 0.65)
          : selected
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: session.active
                          ? const Color(0xFF43A047)
                          : scheme.outline,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (session.imported)
                    const Padding(
                      padding: EdgeInsets.only(left: 5),
                      child: Icon(Icons.file_download_done_rounded, size: 15),
                    ),
                  if (selectionMode)
                    Checkbox(
                      value: batchSelected,
                      onChanged: onSelectChanged,
                      visualDensity: VisualDensity.compact,
                    )
                  else
                    const Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                _formatDateTime(session.startedAt),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  _miniStat(
                    Icons.local_fire_department_outlined,
                    '${_temperature(session.maximum)}°',
                    const Color(0xFFFF5252),
                  ),
                  _miniStat(
                    Icons.ac_unit_rounded,
                    '${_temperature(session.minimum)}°',
                    const Color(0xFF42A5F5),
                  ),
                  _miniStat(
                    Icons.data_usage_rounded,
                    '${session.sampleCount} 条',
                    scheme.onSurfaceVariant,
                  ),
                  _miniStat(
                    Icons.schedule_rounded,
                    _formatDuration(session.duration),
                    scheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (session.deviceSerial != null) ...[
                const SizedBox(height: 5),
                Text(
                  '设备 ${session.deviceSerial}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static Widget _miniStat(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 10.5, color: color)),
      ],
    );
  }
}

enum _HistoryChartRange { all, minute, tenMinutes, hour }

class _HistorySessionDetail extends StatefulWidget {
  const _HistorySessionDetail({
    super.key,
    required this.sessionId,
    required this.onDeleted,
  });

  final String sessionId;
  final VoidCallback onDeleted;

  @override
  State<_HistorySessionDetail> createState() => _HistorySessionDetailState();
}

class _HistorySessionDetailState extends State<_HistorySessionDetail> {
  final _store = TemperatureHistoryStore.instance;
  List<TemperatureSample> _samples = const [];
  bool _loading = true;
  bool _mutating = false;
  bool _showMaximum = true;
  bool _showMinimum = true;
  bool _showAverage = true;
  bool _showSingle = true;
  bool _showMulti = true;
  final Set<int> _visiblePointIds = {};
  bool _pointSelectionInitialized = false;
  _HistoryChartRange _range = _HistoryChartRange.all;
  int _loadGeneration = 0;
  Timer? _activeReloadTimer;

  TemperatureHistorySession? get _session {
    for (final session in _store.sessions) {
      if (session.id == widget.sessionId) return session;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant _HistorySessionDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _samples = const [];
      _range = _HistoryChartRange.all;
      _visiblePointIds.clear();
      _pointSelectionInitialized = false;
      _load();
    }
  }

  @override
  void dispose() {
    _activeReloadTimer?.cancel();
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    if (_session == null) {
      widget.onDeleted();
      return;
    }
    setState(() {});
    if (_session!.active && _activeReloadTimer == null) {
      _activeReloadTimer = Timer(const Duration(seconds: 2), () {
        _activeReloadTimer = null;
        if (mounted) _load(silent: true);
      });
    }
  }

  Future<void> _load({bool silent = false}) async {
    final generation = ++_loadGeneration;
    if (!silent) setState(() => _loading = true);
    final samples = await _store.loadSamples(widget.sessionId);
    if (!mounted || generation != _loadGeneration) return;
    final pointIds = _pointIds(samples);
    _visiblePointIds.removeWhere((id) => !pointIds.contains(id));
    if (!_pointSelectionInitialized && pointIds.isNotEmpty) {
      _visiblePointIds.addAll(pointIds.take(3));
      _pointSelectionInitialized = true;
    }
    setState(() {
      _samples = samples;
      _loading = false;
    });
  }

  Future<void> _rename() async {
    final session = _session;
    if (session == null) return;
    final controller = TextEditingController(text: session.name);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名测温会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '会话名称'),
          onSubmitted: (text) => Navigator.of(dialogContext).pop(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !mounted) return;
    await _store.renameSession(widget.sessionId, value);
  }

  Future<void> _finish() async {
    setState(() => _mutating = true);
    await _store.finishActiveSession();
    TemperatureRecorder.instance.clearRecords();
    if (!mounted) return;
    setState(() => _mutating = false);
    BananaToast.show(context, '当前会话已归档', icon: Icons.inventory_2_outlined);
  }

  Future<void> _delete() async {
    final session = _session;
    if (session == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_forever_outlined, size: 32),
        title: const Text('删除历史会话？'),
        content: Text(
          '“${session.name}”及其 ${session.sampleCount} 条原始温度数据将从本地永久删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _mutating = true);
    if (session.active) TemperatureRecorder.instance.clearRecords();
    await _store.deleteSession(widget.sessionId);
    if (!mounted) return;
    widget.onDeleted();
  }

  Future<void> _export() async {
    final samples = await _store.loadSamples(widget.sessionId);
    if (!mounted || samples.isEmpty) return;
    setState(() => _samples = samples);
    final session = _session;
    await showTemperatureExportDialog(
      context,
      singlePointMode: false,
      initialDirectory: appPhotoDownloadDir.value,
      samples: samples,
      title: '导出 · ${session?.name ?? '温度历史'}',
      allowClear: false,
    );
  }

  List<TemperatureSample> get _rangeSamples {
    if (_samples.isEmpty || _range == _HistoryChartRange.all) return _samples;
    final duration = switch (_range) {
      _HistoryChartRange.minute => const Duration(minutes: 1),
      _HistoryChartRange.tenMinutes => const Duration(minutes: 10),
      _HistoryChartRange.hour => const Duration(hours: 1),
      _HistoryChartRange.all => Duration.zero,
    };
    final since = _samples.last.timestamp.subtract(duration);
    return _samples
        .where((sample) => !sample.timestamp.isBefore(since))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) return const _HistoryEmptyDetail();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          session.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (session.active) ...[
                        const SizedBox(width: 8),
                        const _ActiveBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_formatDateTime(session.startedAt)}'
                    '  —  ${_formatDateTime(session.endedAt)}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '重命名',
              onPressed: _mutating ? null : _rename,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '导出 CSV / PNG / JSON',
              onPressed: _samples.isEmpty || _mutating ? null : _export,
              icon: const Icon(Icons.download_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: '更多操作',
              enabled: !_mutating,
              onSelected: (value) {
                if (value == 'finish') _finish();
                if (value == 'delete') _delete();
              },
              itemBuilder: (_) => [
                if (session.active)
                  const PopupMenuItem(
                    value: 'finish',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.inventory_2_outlined),
                      title: Text('结束并归档'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_forever_outlined),
                    title: Text('删除本地历史'),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _samples.isEmpty
              ? const Center(child: Text('会话暂无可读取的温度采样'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HistoryStats(session: session),
                      const SizedBox(height: 10),
                      _buildChartCard(context),
                      const SizedBox(height: 10),
                      _HistoryRecentSamples(samples: _samples),
                      if (_store.storagePath != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          '存储位置：${_store.storagePath}',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildChartCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final samples = _rangeSamples;
    final chartSamples = _downsample(samples, 1200);
    final origin = chartSamples.first.timestamp;
    final pointIds = _pointIds(samples);

    List<FlSpot> spots(double? Function(TemperatureSample sample) valueOf) {
      return [
        for (final sample in chartSamples)
          if (valueOf(sample) case final double value)
            FlSpot(
              sample.timestamp.difference(origin).inMilliseconds / 1000,
              value,
            ),
      ];
    }

    final bars = <LineChartBarData>[
      if (_showMaximum)
        _historyLine(
          spots((sample) => sample.maximum),
          const Color(0xFFFF5252),
        ),
      if (_showMinimum)
        _historyLine(
          spots((sample) => sample.minimum),
          const Color(0xFF42A5F5),
        ),
      if (_showAverage)
        _historyLine(
          spots((sample) => sample.average),
          const Color(0xFF66BB6A),
        ),
      if (_showSingle)
        _historyLine(
          spots((sample) => sample.singleTemperature),
          const Color(0xFFFFA726),
        ),
      if (_showMulti)
        _historyLine(
          spots((sample) => sample.multiPointAverage),
          const Color(0xFFAB47BC),
        ),
      for (final id in pointIds)
        if (_visiblePointIds.contains(id))
          _historyLine(
            spots((sample) => _pointTemperature(sample, id)),
            _pointColor(id),
          ),
    ].where((line) => line.spots.isNotEmpty).toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '趋势分析',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 4),
                _rangeChip(_HistoryChartRange.all, '全部'),
                _rangeChip(_HistoryChartRange.minute, '近 1 分钟'),
                _rangeChip(_HistoryChartRange.tenMinutes, '近 10 分钟'),
                _rangeChip(_HistoryChartRange.hour, '近 1 小时'),
              ],
            ),
            const SizedBox(height: 7),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _seriesChip(
                    '最高',
                    const Color(0xFFFF5252),
                    _showMaximum,
                    (value) => _showMaximum = value,
                  ),
                  _seriesChip(
                    '最低',
                    const Color(0xFF42A5F5),
                    _showMinimum,
                    (value) => _showMinimum = value,
                  ),
                  _seriesChip(
                    '平均',
                    const Color(0xFF66BB6A),
                    _showAverage,
                    (value) => _showAverage = value,
                  ),
                  _seriesChip(
                    '固定单点',
                    const Color(0xFFFFA726),
                    _showSingle,
                    (value) => _showSingle = value,
                  ),
                  _seriesChip(
                    '多点均值',
                    const Color(0xFFAB47BC),
                    _showMulti,
                    (value) => _showMulti = value,
                  ),
                  for (final id in pointIds)
                    _seriesChip(
                      '测温点 $id',
                      _pointColor(id),
                      _visiblePointIds.contains(id),
                      (value) {
                        if (value) {
                          _visiblePointIds.add(id);
                        } else {
                          _visiblePointIds.remove(id);
                        }
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 300,
              child: bars.isEmpty
                  ? Center(
                      child: Text(
                        '当前选择的曲线没有数据',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        lineTouchData: LineTouchData(
                          enabled: true,
                          touchTooltipData: LineTouchTooltipData(
                            getTooltipItems: (spots) => [
                              for (final spot in spots)
                                LineTooltipItem(
                                  '${spot.y.toStringAsFixed(2)} °C',
                                  TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                    fontFamily: currentAppFontFamily,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: false,
                          getDrawingHorizontalLine: (_) => FlLine(
                            color: scheme.outlineVariant.withValues(alpha: 0.3),
                            strokeWidth: 1,
                          ),
                        ),
                        borderData: FlBorderData(show: false),
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 46,
                              getTitlesWidget: (value, meta) => Text(
                                '${value.toStringAsFixed(1)}°',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 9,
                                ),
                              ),
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 25,
                              interval: _axisInterval(chartSamples),
                              getTitlesWidget: (value, meta) => Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  _elapsedLabel(value),
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        lineBarsData: bars,
                      ),
                    ),
            ),
            const SizedBox(height: 5),
            Text(
              '显示 ${samples.length} 条数据；图表最多等距绘制 1200 点，导出仍保留全部原始记录。',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeChip(_HistoryChartRange value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _range == value,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => _range = value),
    );
  }

  Widget _seriesChip(
    String label,
    Color color,
    bool selected,
    ValueChanged<bool> assign,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        avatar: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (value) => setState(() => assign(value)),
      ),
    );
  }
}

class _HistoryStats extends StatelessWidget {
  const _HistoryStats({required this.session});
  final TemperatureHistorySession session;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 580;
        final cards = [
          _HistoryKpi(
            icon: Icons.local_fire_department_rounded,
            label: '会话最高',
            value: '${_temperature(session.maximum)} °C',
            color: const Color(0xFFFF5252),
          ),
          _HistoryKpi(
            icon: Icons.ac_unit_rounded,
            label: '会话最低',
            value: '${_temperature(session.minimum)} °C',
            color: const Color(0xFF42A5F5),
          ),
          _HistoryKpi(
            icon: Icons.analytics_outlined,
            label: '平均温度',
            value: '${_temperature(session.average)} °C',
            color: const Color(0xFF66BB6A),
          ),
          _HistoryKpi(
            icon: Icons.data_usage_rounded,
            label: '记录规模',
            value: '${session.sampleCount} 条',
            color: Theme.of(context).colorScheme.primary,
          ),
          _HistoryKpi(
            icon: Icons.schedule_rounded,
            label: '持续时间',
            value: _formatDuration(session.duration),
            color: Theme.of(context).colorScheme.secondary,
          ),
          _HistoryKpi(
            icon: Icons.timer_outlined,
            label: '采样间隔',
            value: _intervalLabel(session.sampleIntervalMs),
            color: Theme.of(context).colorScheme.tertiary,
          ),
        ];
        if (compact) {
          return GridView.count(
            crossAxisCount: 2,
            childAspectRatio: 2.15,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: cards,
          );
        }
        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              Expanded(child: cards[i]),
              if (i != cards.length - 1) const SizedBox(width: 7),
            ],
          ],
        );
      },
    );
  }
}

class _HistoryKpi extends StatelessWidget {
  const _HistoryKpi({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 9.5,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRecentSamples extends StatelessWidget {
  const _HistoryRecentSamples({required this.samples});
  final List<TemperatureSample> samples;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recent = samples.length <= 8
        ? samples.reversed
        : samples.sublist(samples.length - 8).reversed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '最近采样',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 34,
                dataRowMinHeight: 32,
                dataRowMaxHeight: 36,
                columnSpacing: 28,
                columns: const [
                  DataColumn(label: Text('时间')),
                  DataColumn(label: Text('最高')),
                  DataColumn(label: Text('最低')),
                  DataColumn(label: Text('平均')),
                  DataColumn(label: Text('单点')),
                  DataColumn(label: Text('多点均值')),
                ],
                rows: [
                  for (final sample in recent)
                    DataRow(
                      cells: [
                        DataCell(Text(_formatClock(sample.timestamp))),
                        DataCell(Text('${sample.maximum.toStringAsFixed(2)}°')),
                        DataCell(Text('${sample.minimum.toStringAsFixed(2)}°')),
                        DataCell(Text('${sample.average.toStringAsFixed(2)}°')),
                        DataCell(
                          Text(
                            sample.singleTemperature?.toStringAsFixed(2) ?? '—',
                          ),
                        ),
                        DataCell(
                          Text(
                            sample.multiPointAverage?.toStringAsFixed(2) ?? '—',
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Text(
              '完整逐点数据可通过 CSV 或 JSON 导出。',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF43A047).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.fiber_manual_record_rounded,
            size: 10,
            color: Color(0xFF43A047),
          ),
          SizedBox(width: 3),
          Text(
            '记录中',
            style: TextStyle(
              color: Color(0xFF43A047),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryUnavailable extends StatelessWidget {
  const _HistoryUnavailable({this.error, this.onRetry});
  final String? error;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storage_outlined, size: 46),
            const SizedBox(height: 12),
            const Text(
              '温度历史存储尚未就绪',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            if (error != null) ...[
              const SizedBox(height: 7),
              SelectableText(error!, textAlign: TextAlign.center),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试初始化'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryEmptyList extends StatelessWidget {
  const _HistoryEmptyList();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history_toggle_off_rounded, size: 44),
          SizedBox(height: 8),
          Text('暂无匹配的温度历史'),
          SizedBox(height: 3),
          Text('连接设备并收到热像数据后会自动创建会话', style: TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _HistoryEmptyDetail extends StatelessWidget {
  const _HistoryEmptyDetail();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.query_stats_rounded, size: 52),
          SizedBox(height: 10),
          Text('选择一个历史会话进行复盘分析'),
        ],
      ),
    );
  }
}

LineChartBarData _historyLine(List<FlSpot> spots, Color color) {
  return LineChartBarData(
    spots: spots,
    color: color,
    barWidth: 2,
    isCurved: true,
    dotData: const FlDotData(show: false),
  );
}

List<TemperatureSample> _downsample(
  List<TemperatureSample> source,
  int maximum,
) {
  if (source.length <= maximum) return source;
  final last = source.length - 1;
  return List<TemperatureSample>.generate(maximum, (index) {
    return source[(index * last / (maximum - 1)).round()];
  }, growable: false);
}

List<int> _pointIds(List<TemperatureSample> samples) {
  final ids = <int>{};
  for (final sample in samples) {
    for (final reading in sample.pointReadings) {
      ids.add(reading.id);
    }
  }
  return ids.toList()..sort();
}

double? _pointTemperature(TemperatureSample sample, int id) {
  for (final reading in sample.pointReadings) {
    if (reading.id == id) return reading.temperature;
  }
  return null;
}

Color _pointColor(int id) {
  const colors = <Color>[
    Color(0xFF26C6DA),
    Color(0xFFEC407A),
    Color(0xFF7E57C2),
    Color(0xFFFF7043),
    Color(0xFF8D6E63),
    Color(0xFF78909C),
  ];
  return colors[id.abs() % colors.length];
}

double _axisInterval(List<TemperatureSample> samples) {
  if (samples.length < 2) return 1;
  final seconds =
      samples.last.timestamp
          .difference(samples.first.timestamp)
          .inMilliseconds /
      1000;
  if (seconds <= 10) return 2;
  if (seconds <= 60) return 10;
  if (seconds <= 600) return 120;
  if (seconds <= 3600) return 600;
  return (seconds / 5).clamp(1, double.infinity);
}

String _elapsedLabel(double seconds) {
  if (seconds < 60) return '${seconds.round()}s';
  if (seconds < 3600) return '${(seconds / 60).round()}m';
  return '${(seconds / 3600).toStringAsFixed(1)}h';
}

String _formatDateTime(DateTime value) {
  final t = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _formatClock(DateTime value) {
  final t = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _formatDuration(Duration duration) {
  if (duration.isNegative) return '0 秒';
  if (duration.inHours > 0) {
    return '${duration.inHours}时${duration.inMinutes.remainder(60)}分';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}分${duration.inSeconds.remainder(60)}秒';
  }
  return '${duration.inSeconds} 秒';
}

String _intervalLabel(int milliseconds) {
  if (milliseconds < 1000 && milliseconds > 0) {
    return '${1000 ~/ milliseconds} 次/秒';
  }
  if (milliseconds % 1000 == 0) {
    return '${milliseconds ~/ 1000} 秒';
  }
  return '$milliseconds ms';
}

String _temperature(double value) =>
    value.isFinite ? value.toStringAsFixed(1) : '—';
