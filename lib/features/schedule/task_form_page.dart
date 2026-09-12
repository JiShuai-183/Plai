import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../shared/plai_time_picker.dart';
import '../../shared/plai_toast.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';

/// 任务新建/编辑表单。
///
/// 字段：标题/描述/类型（待办任务|定点日程|每日打卡|一次性跨期）/日期（时刻）/
/// 优先级/关联课程/每日提醒时刻。
/// - todo/scheduled：单个日期（scheduled 带具体时刻，todo 时刻可选）。
/// - daily/span：起始日期 + 截止日期。
/// 提醒统一为「每日提醒时刻」（各类型同款，可清除）：到点每天重复提醒，
/// todo/scheduled 勾完成即停，daily/span 在区间内生效。保存后调用提醒调度
/// （创建/编辑/删除同步注册或取消）。
class TaskFormPage extends ConsumerStatefulWidget {
  const TaskFormPage({super.key, this.task, this.initialDate, this.initialCourseId});

  /// 待编辑任务；null 为新建。
  final Task? task;

  /// 预填日期（如从日历某天新建）。
  final DateTime? initialDate;

  /// 预填关联课程（如从课程详情新建作业）。
  final int? initialCourseId;

  @override
  ConsumerState<TaskFormPage> createState() => _TaskFormPageState();
}

class _TaskFormPageState extends ConsumerState<TaskFormPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;

  late TaskType _type;
  late DateTime _date;
  late DateTime _start;
  TimeOfDay? _time;
  TimeOfDay? _dailyRemindTime;
  late Priority _priority;
  int? _courseId;

  /// 新建时是否已对 daily/span 应用默认区间（防切回类型时二次覆盖）。
  bool _rangeDefaulted = false;

  bool get _isEditing => widget.task != null;

  /// daily/span 为起止区间型任务（仅日期字段，无单点时刻）。
  static bool _isRangeType(TaskType type) =>
      type == TaskType.daily || type == TaskType.span;

  @override
  void initState() {
    super.initState();
    final Task? t = widget.task;
    _titleCtrl = TextEditingController(text: t?.title ?? '');
    _descCtrl = TextEditingController(text: t?.description ?? '');
    _type = t?.type ?? TaskType.todo;
    _date = _dateOnly(t?.dueDate ?? widget.initialDate ?? DateTime.now());
    // 起始日期：编辑回填 task.startDate（缺失回退截止日）；
    // 新建默认同截止日（今天 / 入口选日），切到 daily/span 时截止自动扩为 +6 天。
    _start = _dateOnly(t?.startDate ?? _date);
    _time = _parseTime(t?.dueTime);
    _dailyRemindTime = _parseTime(t?.dailyRemindTime);
    _priority = t?.priority ?? Priority.normal;
    _courseId = t?.courseId ?? widget.initialCourseId;
    if (_type == TaskType.scheduled && _time == null) {
      _time = const TimeOfDay(hour: 8, minute: 0);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<(int, String)>> coursesAsync =
        ref.watch(courseOptionsProvider);
    return coursesAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: Text(_isEditing ? '编辑任务' : '新建任务')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => Scaffold(
        appBar: AppBar(title: Text(_isEditing ? '编辑任务' : '新建任务')),
        body: const Center(child: Text('课程数据加载失败')),
      ),
      data: (options) => _buildForm(context, options),
    );
  }

  Widget _buildForm(BuildContext context, List<(int, String)> courseOptions) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑任务' : '新建任务'),
        actions: [
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除任务',
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '如：交高等数学作业',
                  border: OutlineInputBorder(),
                ),
                validator: (String? v) =>
                    (v == null || v.trim().isEmpty) ? '请输入标题' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '描述（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<TaskType>(
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: '类型',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final TaskType t in TaskType.values)
                    DropdownMenuItem<TaskType>(value: t, child: Text(t.label)),
                ],
                onChanged: (TaskType? v) {
                  if (v != null) _onTypeChanged(v);
                },
              ),
              const SizedBox(height: 16),
              _dateSection(context),
              const SizedBox(height: 8),
              Text('优先级', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<Priority>(
                segments: const [
                  ButtonSegment(value: Priority.normal, label: Text('普通')),
                  ButtonSegment(value: Priority.important, label: Text('重要')),
                  ButtonSegment(value: Priority.urgent, label: Text('紧急')),
                ],
                selected: {_priority},
                onSelectionChanged: (Set<Priority> selection) =>
                    setState(() => _priority = selection.first),
              ),
              const SizedBox(height: 16),
              _courseDropdown(context, courseOptions),
              // 各类型统一的「每日提醒时刻」（可清除 = 不提醒）。
              const SizedBox(height: 16),
              _dailyRemindTile(context),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                child: Text(_isEditing ? '保存修改' : '添加任务'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 日期区：daily/span 显示「起始日期/截止日期」，其余维持单日期（+ 时刻）。
  Widget _dateSection(BuildContext context) {
    if (_isRangeType(_type)) {
      return Column(
        children: [
          _rangeDateTile(context,
              title: '起始日期', date: _start, onPick: _pickStartDate),
          const SizedBox(height: 4),
          _rangeDateTile(context,
              title: '截止日期', date: _date, onPick: _pickDueDate),
        ],
      );
    }
    return _dateTimeTile(context);
  }

  /// daily/span 的日期选择行（无具体时刻）。
  Widget _rangeDateTile(BuildContext context,
      {required String title, required DateTime date, required VoidCallback onPick}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.event_outlined),
      title: Text(title),
      subtitle: Text(formatFullDate(date)),
      onTap: onPick,
    );
  }

  Widget _dateTimeTile(BuildContext context) {
    final bool isScheduled = _type == TaskType.scheduled;
    final String timeText = _time == null ? '未设置' : formatTimeOfDay(_time!);
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_outlined),
          title: const Text('日期'),
          subtitle: Text(formatFullDate(_date)),
          onTap: _pickDate,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule_outlined),
          title: Text(isScheduled ? '时间' : '截止时刻（可选）'),
          subtitle: Text(timeText),
          trailing: (!isScheduled && _time != null)
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: '清除时刻',
                  onPressed: () => setState(() => _time = null),
                )
              : null,
          onTap: _pickTime,
        ),
      ],
    );
  }

  Widget _courseDropdown(BuildContext context, List<(int, String)> options) {
    return DropdownButtonFormField<int?>(
      initialValue: _courseId,
      decoration: const InputDecoration(
        labelText: '关联课程（可选）',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('不关联课程')),
        for (final (int id, String label) in options)
          DropdownMenuItem<int?>(value: id, child: Text(label)),
      ],
      onChanged: (int? v) => setState(() => _courseId = v),
    );
  }

  /// 各类型统一的「每日提醒时刻」行：每天同一时刻重复提醒（区间/完成停），
  /// 可清除。
  Widget _dailyRemindTile(BuildContext context) {
    final TimeOfDay? at = _dailyRemindTime;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.notifications_active_outlined),
      title: const Text('每日提醒时刻'),
      subtitle: Text(at == null ? '不提醒' : '每天 ${formatTimeOfDay(at)}'),
      trailing: at != null
          ? IconButton(
              icon: const Icon(Icons.clear),
              tooltip: '清除每日提醒',
              onPressed: () => setState(() => _dailyRemindTime = null),
            )
          : null,
      onTap: () => _pickDailyRemindTime(at),
    );
  }

  void _onTypeChanged(TaskType type) {
    setState(() {
      final bool enteredRange = _isRangeType(type) && !_isRangeType(_type);
      _type = type;
      // 每日提醒时刻不随类型切换清空（各类型统一拥有）。
      // 新建首次切入 daily/span：起始=当前所选日（默认今天/入口选日），
      // 截止默认 = 起始 + 6 天；切回再进入不二次覆盖（_rangeDefaulted）。
      if (!_isEditing && enteredRange && !_rangeDefaulted) {
        _rangeDefaulted = true;
        _start = _date;
        _date = _start.add(const Duration(days: 6));
      }
      if (_isRangeType(type)) {
        _time = null; // daily/span 不设具体时刻。
      } else if (type == TaskType.scheduled && _time == null) {
        _time = const TimeOfDay(hour: 8, minute: 0);
      }
    });
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await _withPicker(() => _showDatePicker(_date));
    if (picked != null) setState(() => _date = _dateOnly(picked));
  }

  Future<void> _pickStartDate() async {
    final DateTime? picked = await _withPicker(() => _showDatePicker(_start));
    if (picked != null) setState(() => _start = _dateOnly(picked));
  }

  Future<void> _pickDueDate() async {
    final DateTime? picked = await _withPicker(() => _showDatePicker(_date));
    if (picked != null) setState(() => _date = _dateOnly(picked));
  }

  Future<DateTime?> _showDatePicker(DateTime initialDate) {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await _withPicker(
      () => showPlaiTimePicker(
        context,
        initialTime: _time ?? const TimeOfDay(hour: 8, minute: 0),
      ),
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _pickDailyRemindTime(TimeOfDay? current) async {
    final TimeOfDay? picked = await _withPicker(
      () => showPlaiTimePicker(
        context,
        initialTime: current ?? const TimeOfDay(hour: 8, minute: 0),
      ),
    );
    if (picked != null) setState(() => _dailyRemindTime = picked);
  }

  /// 打开选择器前先清焦点，防「选完时间/日期后软键盘再次弹出」。
  ///
  /// 反直觉的坑（勿当冗余删除）：本页时间/日期字段是 [ListTile]（onTap 开
  /// 选择器），**不是** TextField —— 点它们不会转移焦点，「标题」输入框全程
  /// 仍是 primaryFocus。选择器走 showDialog 路由，弹窗期间底路由的
  /// FocusScope 仍把那个输入框记为 focusedChild；弹窗关闭、焦点回到原路由时
  /// 它重新取得 primary focus → TextInputConnection 重连 → 键盘再次弹出。
  /// 打开前清一次即让底路由的 focusedChild 置空、弹出后无从恢复（实测单次
  /// 即够，无需 await 后再清）。与 `course_form_page.dart` 的 unfocus 写法一致。
  Future<T?> _withPicker<T>(Future<T?> Function() open) async {
    FocusManager.instance.primaryFocus?.unfocus();
    return open();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_isRangeType(_type)) {
      // daily/span：起止日期已默认填充，仅需校验 截止 ≥ 起始。
      if (_start.isAfter(_date)) {
        _warn('截止日期不能早于起始日期');
        return;
      }
    } else {
      // 定点日程必填时刻（兜底为 08:00）。
      if (_type == TaskType.scheduled && _time == null) {
        setState(() => _time = const TimeOfDay(hour: 8, minute: 0));
      }
    }

    final String? dueTimeStr =
        _isRangeType(_type) ? null : (_time != null ? formatTimeOfDay(_time!) : null);
    // 提醒统一「每日提醒时刻」（存 daily_remind_time）：各类型同款。新版不再
    // 提供单次 offset 提醒 UI；编辑旧任务保存会把 remindOffsetMin/remindDate
    // 清空（存量未编辑任务的原单次调度仍保留，见调度器兼容分支）。
    final String? dailyRemindStr =
        _dailyRemindTime != null ? formatTimeOfDay(_dailyRemindTime!) : null;

    final Task? old = widget.task;
    final Task task = Task(
      id: old?.id,
      title: _titleCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      type: _type,
      dueDate: _date,
      startDate: _isRangeType(_type) ? _start : null,
      dueTime: dueTimeStr,
      dailyRemindTime: dailyRemindStr,
      priority: _priority,
      courseId: _courseId,
      completed: old?.completed ?? false,
      completedAt: old?.completedAt,
      createdAt: old?.createdAt,
    );

    // 提醒调度失败：保存成功但提醒没设上。回调在 saveTask 返回前触发（此时
    // 本页尚未 pop），只记标志位，等返回后再决定是否弹气泡。
    bool reminderFailed = false;
    try {
      await saveTask(ref, task, onReminderFailed: () => reminderFailed = true);
    } catch (_) {
      if (mounted) _warn('保存失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    // 先取 overlay（pop 之后本页 context 失效，不能再取值），再返回上一页，
    // 最后按需弹气泡。底部偏移交由 showPlaiToast 的默认规则处理。
    final OverlayState? overlay = reminderFailed ? Overlay.of(context) : null;
    Navigator.of(context).pop();
    if (reminderFailed) {
      try {
        showPlaiToast(
          context,
          '任务已保存，但提醒设置失败',
          overlay: overlay,
        );
      } catch (_) {
        // toast 失败不阻断。
      }
    }
  }

  /// 页内轻提示（校验/保存失败的醒目样式）。
  void _warn(String message) {
    showPlaiToast(context, message, kind: PlaiToastKind.error);
  }

  Future<void> _confirmDelete() async {
    final Task? task = widget.task;
    final int? id = task?.id;
    if (id == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定删除「${task!.title}」吗？此操作不可恢复。'),
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
    if (ok != true || !mounted) return;
    try {
      await deleteTask(ref, id);
    } catch (_) {
      if (mounted) {
        showPlaiToast(
          context,
          '删除失败，请稍后重试',
          kind: PlaiToastKind.error,
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  static TimeOfDay? _parseTime(String? time) {
    if (time == null || time.isEmpty) return null;
    final List<String> parts = time.split(':');
    if (parts.length != 2) return null;
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}
