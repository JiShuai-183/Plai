import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/default_periods.dart';
import '../../data/models/period.dart';
import '../../services/notifications/notification_providers.dart';
import 'settings_providers.dart';

/// 节次时间表编辑页。
///
/// 支持：编辑各节起止时间、新增节次、删除节次、恢复内置默认模板。
/// 任何改动后调用提醒重排，使上课提醒按新的节次时间生效。
class PeriodsEditPage extends ConsumerStatefulWidget {
  const PeriodsEditPage({super.key});

  @override
  ConsumerState<PeriodsEditPage> createState() => _PeriodsEditPageState();
}

class _PeriodsEditPageState extends ConsumerState<PeriodsEditPage> {
  List<Period>? _periods;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<Period> periods =
          await ref.read(settingsTimetableRepoProvider).getPeriods();
      if (!mounted) return;
      setState(() {
        _periods = periods;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载节次时间表失败';
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------ 新增

  Future<void> _addPeriod() async {
    final int nextIndex =
        (_periods?.isEmpty ?? true) ? 1 : (_periods!.last.index + 1);
    final TimeOfDay? start = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
      helpText: '第 $nextIndex 节开始时间',
    );
    if (start == null || !mounted) return;
    final TimeOfDay? end = await showTimePicker(
      context: context,
      initialTime: _addMinutes(start, 45),
      helpText: '第 $nextIndex 节结束时间',
    );
    if (end == null || !mounted) return;
    if (_minuteOf(start) >= _minuteOf(end)) {
      _showSnack('结束时间必须晚于开始时间');
      return;
    }
    final Period period = Period(
      index: nextIndex,
      startTime: _fmt(start),
      endTime: _fmt(end),
    );
    try {
      await ref.read(settingsTimetableRepoProvider).insertPeriod(period);
      await _reschedule();
      await _load();
    } catch (_) {
      _showSnack('新增节次失败');
    }
  }

  // ------------------------------------------------------------ 编辑

  Future<void> _editPeriod(Period period) async {
    final TimeOfDay? start = await showTimePicker(
      context: context,
      initialTime: _parseTime(period.startTime),
      helpText: '第 ${period.index} 节开始时间',
    );
    if (start == null || !mounted) return;
    final TimeOfDay? end = await showTimePicker(
      context: context,
      initialTime: _parseTime(period.endTime),
      helpText: '第 ${period.index} 节结束时间',
    );
    if (end == null || !mounted) return;
    if (_minuteOf(start) >= _minuteOf(end)) {
      _showSnack('结束时间必须晚于开始时间');
      return;
    }
    await _persist(period.copyWith(startTime: _fmt(start), endTime: _fmt(end)));
  }

  Future<void> _persist(Period updated) async {
    try {
      await ref.read(settingsTimetableRepoProvider).updatePeriod(updated);
      await _reschedule();
      await _load();
    } catch (_) {
      _showSnack('保存失败');
    }
  }

  // ------------------------------------------------------------ 删除

  Future<void> _deletePeriod(Period period) async {
    final int? id = period.id;
    if (id == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除节次'),
          content: Text(
            '确定删除「第 ${period.index} 节（${period.startTime}–${period.endTime}）」吗？'
            '删除后序号不会自动重排。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(settingsTimetableRepoProvider).deletePeriod(id);
      await _reschedule();
      await _load();
    } catch (_) {
      _showSnack('删除节次失败');
    }
  }

  // ------------------------------------------------------------ 恢复默认

  Future<void> _restoreDefaults() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('恢复默认模板'),
          content: const Text('将当前节次时间表整体替换为国内高校常用 12 节模板，确定吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('恢复'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(settingsTimetableRepoProvider)
          .replacePeriods(defaultPeriods);
      await _reschedule();
      await _load();
    } catch (_) {
      _showSnack('恢复默认模板失败');
    }
  }

  // ------------------------------------------------------------ 提醒联动

  Future<void> _reschedule() async {
    try {
      await ref.read(notificationSchedulerProvider).rescheduleAll();
    } catch (_) {
      // 提醒重排失败不影响节次保存（如测试环境 / 通知插件异常）。
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('节次时间表')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPeriod,
        icon: const Icon(Icons.add),
        label: const Text('新增节次'),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final List<Period> periods = _periods ?? const [];
    if (periods.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 48),
          Icon(Icons.schedule, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            '还没有节次时间\n点右下角新增，或恢复内置默认模板',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Center(child: _restoreDefaultsButton()),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final Period p in periods)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Text('${p.index}'),
            ),
            title: Text('第 ${p.index} 节'),
            subtitle: Text('${p.startTime} — ${p.endTime}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () => _deletePeriod(p),
            ),
            onTap: () => _editPeriod(p),
          ),
        const Divider(),
        Center(child: _restoreDefaultsButton()),
      ],
    );
  }

  Widget _restoreDefaultsButton() {
    return TextButton.icon(
      onPressed: _restoreDefaults,
      icon: const Icon(Icons.restore),
      label: const Text('恢复内置默认模板（12 节）'),
    );
  }

  // ------------------------------------------------------------ 工具

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static int _minuteOf(TimeOfDay t) => t.hour * 60 + t.minute;

  static TimeOfDay _addMinutes(TimeOfDay t, int minutes) {
    final int total = t.hour * 60 + t.minute + minutes;
    return TimeOfDay(hour: total ~/ 60, minute: total % 60);
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static TimeOfDay _parseTime(String value) {
    final List<String> parts = value.split(':');
    if (parts.length != 2) return const TimeOfDay(hour: 8, minute: 0);
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return const TimeOfDay(hour: 8, minute: 0);
    return TimeOfDay(hour: h, minute: m);
  }
}
