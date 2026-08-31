import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/semester.dart';
import 'course_form_page.dart';
import 'import_export_page.dart';
import 'period_page.dart';
import 'semester_page.dart';
import 'timetable_providers.dart';
import 'week_view.dart';

/// 课表页（Tab 内容，承载在 [AppShell] 的 IndexedStack 中，不 push 成新路由）。
///
/// 展示当前学期周视图；提供学期管理 / 节次时间 / 导入导出入口与添加课程。
class TimetablePage extends ConsumerStatefulWidget {
  const TimetablePage({super.key});

  @override
  ConsumerState<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends ConsumerState<TimetablePage> {
  /// 右上角加号菜单是否展开（驱动加号 → × 的旋转动画）。
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    // 首次进入：节次表为空时写入内置模板（静默失败，不阻断页面）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ensureDefaultPeriods(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<Semester?> semesterAsync =
        ref.watch(currentSemesterProvider);
    return semesterAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const Scaffold(
        body: Center(child: Text('课表加载失败')),
      ),
      data: (Semester? semester) {
        if (semester == null) return const _NoSemesterView();
        return _buildBody(context, semester);
      },
    );
  }

  Widget _buildBody(BuildContext context, Semester semester) {
    return Scaffold(
      appBar: AppBar(
        title: Text(semester.name),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            position: PopupMenuPosition.under,
            onOpened: () => setState(() => _menuOpen = true),
            onCanceled: () => setState(() => _menuOpen = false),
            onSelected: (String value) {
              setState(() => _menuOpen = false);
              _onMenu(context, value, semester);
            },
            icon: AnimatedRotation(
              turns: _menuOpen ? -0.125 : 0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: const Icon(Icons.add),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'course', child: Text('添加课程')),
              PopupMenuItem(value: 'semester', child: Text('学期管理')),
              PopupMenuItem(value: 'period', child: Text('节次时间')),
              PopupMenuItem(value: 'import', child: Text('导入导出')),
            ],
          ),
        ],
      ),
      body: WeekView(semester: semester, key: ValueKey(semester.id)),
    );
  }

  Future<void> _onMenu(
    BuildContext context,
    String value,
    Semester semester,
  ) async {
    switch (value) {
      case 'course':
        await _openCourseForm(context, semester);
      case 'semester':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SemesterManagePage()),
        );
      case 'period':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PeriodManagePage()),
        );
      case 'import':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ImportExportPage()),
        );
    }
  }

  Future<void> _openCourseForm(BuildContext context, Semester semester) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CourseFormPage(semester: semester),
      ),
    );
  }
}

/// 无学期时的空态视图：引导创建学期。
class _NoSemesterView extends StatelessWidget {
  const _NoSemesterView();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('课表')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.calendar_month_outlined,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('还没有学期', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '先创建一个学期，再添加课程吧',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SemesterManagePage(),
                  ),
                ),
                child: const Text('创建学期'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
