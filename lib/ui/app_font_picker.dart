import 'package:flutter/material.dart';

import 'app_font.dart';
import 'banana_toast.dart';

class AppFontSettingsControl extends StatelessWidget {
  const AppFontSettingsControl({super.key});

  Future<void> _openPicker(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _AppFontPickerDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<AppFontOption>(
      valueListenable: AppFontController.instance.selection,
      builder: (context, selected, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.font_download_outlined,
                    color: scheme.primary,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: selected.resolvedFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'BananaThermal 中文 123.4 °C',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: selected.resolvedFamily,
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () => _openPicker(context),
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('选择字体'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '字体不包含的字符会由系统字体自动补齐；串口日志仍使用等宽字体。',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
          ],
        );
      },
    );
  }
}

class _AppFontPickerDialog extends StatefulWidget {
  const _AppFontPickerDialog();

  @override
  State<_AppFontPickerDialog> createState() => _AppFontPickerDialogState();
}

class _AppFontPickerDialogState extends State<_AppFontPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  List<AppFontOption> _fonts = const [];
  bool _loading = true;
  String? _applyingId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fonts = await AppFontController.instance.listAvailableFonts(
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _fonts = fonts;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取系统字体失败：$error';
        _loading = false;
      });
    }
  }

  Future<void> _select(AppFontOption option) async {
    if (_applyingId != null) return;
    setState(() => _applyingId = option.id);
    try {
      await AppFontController.instance.select(option);
      if (!mounted) return;
      BananaToast.show(
        context,
        '界面字体已切换为 ${option.label}',
        icon: Icons.check_circle_outline_rounded,
      );
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _applyingId = null);
      BananaToast.show(
        context,
        '字体加载失败：$error',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedId = AppFontController.instance.selection.value.id;
    final screenSize = MediaQuery.sizeOf(context);
    final contentWidth = (screenSize.width - 80).clamp(280.0, 560.0);
    final contentHeight = (screenSize.height - 190).clamp(280.0, 560.0);
    final query = _searchController.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? _fonts
        : _fonts
              .where((font) => font.label.toLowerCase().contains(query))
              .toList();
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      title: Row(
        children: [
          const Expanded(child: Text('选择界面字体')),
          IconButton(
            tooltip: '重新读取系统字体',
            onPressed: _loading || _applyingId != null
                ? null
                : () => _load(refresh: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _searchController,
              autofocus: false,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: '搜索系统字体',
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: scheme.error,
                        size: 34,
                      ),
                      const SizedBox(height: 10),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => _load(refresh: true),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              Text(
                query.isEmpty
                    ? '共 ${_fonts.length} 个可用选项'
                    : '找到 ${visible.length} 个字体',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: visible.isEmpty
                    ? const Center(child: Text('没有匹配的字体'))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final option = visible[index];
                          final selected = option.id == selectedId;
                          final applying = option.id == _applyingId;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            enabled: _applyingId == null,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            leading: applying
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    option.source == AppFontSource.bundled
                                        ? Icons.inventory_2_outlined
                                        : option.source ==
                                              AppFontSource.systemDefault
                                        ? Icons.devices_rounded
                                        : Icons.font_download_outlined,
                                    size: 20,
                                  ),
                            title: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily:
                                    option.source == AppFontSource.systemFile
                                    ? null
                                    : option.resolvedFamily,
                              ),
                            ),
                            subtitle: option.source == AppFontSource.systemFile
                                ? const Text('Android 系统字体')
                                : null,
                            trailing: selected
                                ? Icon(
                                    Icons.check_circle_rounded,
                                    color: scheme.primary,
                                  )
                                : null,
                            onTap: () => _select(option),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _applyingId == null
              ? () => Navigator.of(context).pop()
              : null,
          child: const Text('取消'),
        ),
      ],
    );
  }
}
