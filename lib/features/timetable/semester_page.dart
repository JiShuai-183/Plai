import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/semester.dart';
import 'format.dart';
import 'timetable_providers.dart';

/// 学期管理：列表 / 新建 / 切换当前学期 / 删除（二次确认）。
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
                    if (value == 'delete') _deleteSemester(context, ref, s);
                  },
                  itemBuilder: (_) => const [
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
        onPressed: () => _createSemester(context, ref),
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

  Future<void> _createSemester(BuildContext context, WidgetRef ref) async {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController weeksCtrl =
        TextEditingController(text: '16');
    DateTime startDate = DateTime.now();

    final bool? created = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            String errorText = '';
            return AlertDialog(
              title: const Text('新建学期'),
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
                    const SizedBox(height: 4),
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
                  child: const Text('创建'),
                ),
              ],
            );
          },
        );
      },
    );
    if (created != true || !context.mounted) return;

    final String name = nameCtrl.text.trim();
    final int weeks = int.tryParse(weeksCtrl.text.trim()) ?? 16;
    try {
      final int id = await ref
          .read(timetableRepositoryProvider)
          .insertSemester(Semester(
            name: name,
            startDate: startDate,
            totalWeeks: weeks,
          ));
      ref.read(currentSemesterIdProvider.notifier).state = id;
      ref.invalidate(semestersProvider);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('创建失败，请稍后重试')),
        );
      }
    }
  }
}
