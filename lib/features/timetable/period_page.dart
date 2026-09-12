import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/default_periods.dart';
import '../../data/models/period.dart';
import '../../shared/plai_time_picker.dart';
import '../../shared/plai_toast.dart';
import 'format.dart';
import 'timetable_providers.dart';

/// 节次时间表管理：内置国内高校模板 + 自定义增删改。
///
/// 改动后重排上课提醒（节次时间影响上课时刻）。
class PeriodManagePage extends ConsumerWidget {
  const PeriodManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('节次时间'),
        actions: [
          TextButton(
            onPressed: () => _restoreTemplate(context, ref),
            child: const Text('恢复内置模板'),
          ),
        ],
      ),
      body: periodsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('节次加载失败')),
        data: (periods) {
          if (periods.isEmpty) {
            return Center(
              child: Text(
                '暂无节次配置，点击右下角添加，或右上角恢复内置模板',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return ListView.separated(
            itemCount: periods.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final Period p = periods[index];
              return ListTile(
                leading: CircleAvatar(
                  child: Text('${p.index}'),
                ),
                title: Text('${p.startTime} - ${p.endTime}'),
                subtitle: Text('第 ${p.index} 节'),
                trailing: PopupMenuButton<String>(
                  onSelected: (String value) {
                    if (value == 'edit') {
                      _editPeriod(context, ref, p);
                    } else if (value == 'delete') {
                      _deletePeriod(context, ref, p);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addPeriod(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加节次'),
      ),
    );
  }

  Future<void> _restoreTemplate(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('恢复内置模板'),
        content: const Text('将用国内高校常用 12 节模板替换当前节次配置，确定吗？'),
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
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(timetableRepositoryProvider).replacePeriods(defaultPeriods);
      ref.invalidate(periodsProvider);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      if (context.mounted) {
        showPlaiToast(context, '恢复失败，请稍后重试',
            kind: PlaiToastKind.error);
      }
    }
  }

  Future<void> _addPeriod(BuildContext context, WidgetRef ref) async {
    final Period? period = await _periodDialog(context);
    if (period == null || !context.mounted) return;
    try {
      await ref.read(timetableRepositoryProvider).insertPeriod(period);
      ref.invalidate(periodsProvider);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      if (context.mounted) {
        showPlaiToast(context, '添加失败（节次序号可能重复）',
            kind: PlaiToastKind.error);
      }
    }
  }

  Future<void> _editPeriod(BuildContext context, WidgetRef ref, Period p) async {
    final Period? updated = await _periodDialog(context, existing: p);
    if (updated == null || !context.mounted) return;
    try {
      await ref
          .read(timetableRepositoryProvider)
          .updatePeriod(updated.copyWith(id: p.id));
      ref.invalidate(periodsProvider);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      if (context.mounted) {
        showPlaiToast(context, '保存失败（节次序号可能重复）',
            kind: PlaiToastKind.error);
      }
    }
  }

  Future<void> _deletePeriod(BuildContext context, WidgetRef ref, Period p) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除节次'),
        content: Text('确定删除第 ${p.index} 节（${p.startTime}-${p.endTime}）吗？'),
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
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(timetableRepositoryProvider).deletePeriod(p.id!);
      ref.invalidate(periodsProvider);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      if (context.mounted) {
        showPlaiToast(context, '删除失败，请稍后重试',
            kind: PlaiToastKind.error);
      }
    }
  }

  /// 添加/编辑节次的对话框，返回新的节次；取消返回 null。
  Future<Period?> _periodDialog(
    BuildContext context, {
    Period? existing,
  }) async {
    final TextEditingController indexCtrl =
        TextEditingController(text: '${existing?.index ?? ''}');
    TimeOfDay startTime = _parseTime(existing?.startTime) ?? const TimeOfDay(hour: 8, minute: 0);
    TimeOfDay endTime = _parseTime(existing?.endTime) ?? const TimeOfDay(hour: 8, minute: 45);

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: Text(existing == null ? '添加节次' : '编辑节次'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: indexCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '节次序号（1 起）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开始时间'),
                    trailing: Text(formatTimeOfDay(startTime)),
                    onTap: () async {
                      final TimeOfDay? picked = await showPlaiTimePicker(
                        context,
                        initialTime: startTime,
                      );
                      if (picked != null) setDialogState(() => startTime = picked);
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('结束时间'),
                    trailing: Text(formatTimeOfDay(endTime)),
                    onTap: () async {
                      final TimeOfDay? picked = await showPlaiTimePicker(
                        context,
                        initialTime: endTime,
                      );
                      if (picked != null) setDialogState(() => endTime = picked);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final int? index = int.tryParse(indexCtrl.text.trim());
                    if (index == null || index < 1) return;
                    final String start = formatTimeOfDay(startTime);
                    final String end = formatTimeOfDay(endTime);
                    if (start.compareTo(end) >= 0) return;
                    Navigator.of(context).pop(true);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return null;
    final int index = int.tryParse(indexCtrl.text.trim()) ?? 1;
    return Period(
      index: index,
      startTime: formatTimeOfDay(startTime),
      endTime: formatTimeOfDay(endTime),
    );
  }

  TimeOfDay? _parseTime(String? value) {
    if (value == null) return null;
    final List<String> parts = value.split(':');
    if (parts.length != 2) return null;
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }
}
