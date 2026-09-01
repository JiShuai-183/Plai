import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/semester.dart';
import 'format.dart';
import 'timetable_providers.dart';
import 'week_rules.dart';

/// 学期管理：列表 / 新建 / 编辑 / 切换当前学期 / 删除（二次确认）。
class SemesterManagePage extends ConsumerWidget {
  const SemesterManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Semester>> semestersAsync =
        ref.watch(semestersProvider);
    final int? selectedId = ref.watch(currentSemesterIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('学期管理')),
      body: semestersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('学期加载失败')),
        data: (semesters) {
          if (semesters.isEmpty) {
            return Center(
              child: Text(
                '暂无学期，点击右下角新建',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return ListView.separated(
            itemCount: semesters.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final Semester s = semesters[index];
              final bool isCurrent = s.id == selectedId ||
                  (selectedId == null && semesters.first.id == s.id);
              return ListTile(
                leading: Icon(
                  isCurrent ? Icons.check_circle : Icons.school_outlined,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(s.name),
                subtitle: Text(
                  '开学 ${formatMonthDay(s.startDate)} · 共 ${s.totalWeeks} 周',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (String value) {
                    if (value == 'edit') {
                      _showSemesterDialog(context, ref, existing: s);
                    } else if (value == 'delete') {
                      _deleteSemester(context, ref, s);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text('编辑学期'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('删除学期'),
                    ),
                  ],
                ),
                onTap: () => _switchSemester(context, ref, s),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showSemesterDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('新建学期'),
      ),
    );
  }

  void _switchSemester(BuildContext context, WidgetRef ref, Semester s) {
    ref.read(currentSemesterIdProvider.notifier).state = s.id;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换为「${s.name}」')),
    );
  }

  Future<void> _deleteSemester(
      BuildContext context, WidgetRef ref, Semester s) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除学期'),
        content: Text(
          '删除「${s.name}」将同时删除其下全部课程与停课记录，且不可恢复。确定删除吗？',
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
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(timetableRepositoryProvider).deleteSemester(s.id!);
      // 若删除的是当前选中学期，回到自动选择。
      if (ref.read(currentSemesterIdProvider) == s.id) {
        ref.read(currentSemesterIdProvider.notifier).state = null;
      }
      ref.invalidate(semestersProvider);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败，请稍后重试')),
        );
      }
    }
  }

  /// 新建 / 编辑共用学期对话框。
  ///
  /// 返回 true 表示已保存；false/null 表示取消。新建时保存成功后自动切换
  /// 为新建学期；编辑时更新既有学期字段（名称 / 开学日期 / 总周数）。
  ///
  /// 开学日期 ListTile 下方提供实时周次提示：按 [WeekRules] 推算
  /// 「今天 = 本学期第几周」，未开学 / 超范围分别提示。
  Future<bool?> _showSemesterDialog(
    BuildContext context,
    WidgetRef ref, {
    Semester? existing,
  }) async {
    final bool isEdit = existing != null;
    final TextEditingController nameCtrl =
        TextEditingController(text: existing?.name ?? '');
    final TextEditingController weeksCtrl =
        TextEditingController(text: (existing?.totalWeeks ?? 16).toString());
    DateTime startDate = existing?.startDate ?? DateTime.now();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            String errorText = '';
            // 提示用总周数：非法/空输入按 16 兜底（保存仍按原校验）。
            final int hintWeeks = int.tryParse(weeksCtrl.text.trim()) ?? 16;
            final DateTime today = DateTime.now();
            final DateTime startOnly =
                DateTime(startDate.year, startDate.month, startDate.day);
            final DateTime todayOnly =
                DateTime(today.year, today.month, today.day);
            final String weekHint;
            if (startOnly.isAfter(todayOnly)) {
              weekHint = '尚未开学';
            } else {
              final int week = WeekRules(
                semesterStart: startDate,
                totalWeeks: hintWeeks,
              ).weekOfDate(today);
              if (week > hintWeeks) {
                weekHint = '今天已超出本学期范围（共 $hintWeeks 周）';
              } else {
                weekHint = '今天 = 本学期第 $week 周';
              }
            }
            return AlertDialog(
              title: Text(isEdit ? '编辑学期' : '新建学期'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '学期名称',
                        hintText: '如 2026 秋',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('开学日期'),
                      subtitle: Text(formatFullDate(startDate)),
                      trailing: const Icon(Icons.calendar_today_outlined),
                      onTap: () async {
                        final DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: startDate,
                          firstDate: DateTime(startDate.year - 2),
                          lastDate: DateTime(startDate.year + 2),
                        );
                        if (picked != null) {
                          setDialogState(() => startDate = picked);
                        }
                      },
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        weekHint,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: weeksCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '总周数',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (errorText.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(errorText,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final String name = nameCtrl.text.trim();
                    final int? weeks = int.tryParse(weeksCtrl.text.trim());
                    if (name.isEmpty) {
                      setDialogState(() => errorText = '请输入学期名称');
                      return;
                    }
                    if (weeks == null || weeks < 1) {
                      setDialogState(() => errorText = '总周数必须为正整数');
                      return;
                    }
                    Navigator.of(context).pop(true);
                  },
                  child: Text(isEdit ? '保存' : '创建'),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != true) return false;

    final String name = nameCtrl.text.trim();
    final int weeks = int.tryParse(weeksCtrl.text.trim()) ?? 16;
    try {
      if (isEdit) {
        await ref.read(timetableRepositoryProvider).updateSemester(
              existing.copyWith(
                name: name,
                startDate: startDate,
                totalWeeks: weeks,
              ),
            );
      } else {
        final int id = await ref
            .read(timetableRepositoryProvider)
            .insertSemester(Semester(
              name: name,
              startDate: startDate,
              totalWeeks: weeks,
            ));
        ref.read(currentSemesterIdProvider.notifier).state = id;
      }
      ref.invalidate(semestersProvider);
      await rescheduleTimetableReminders(ref);
      return true;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isEdit ? '保存失败，请稍后重试' : '创建失败，请稍后重试')),
        );
      }
      return false;
    }
  }
}
