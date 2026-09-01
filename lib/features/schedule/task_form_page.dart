import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../shared/plai_time_picker.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';
import 'task_rules.dart';

/// 任务新建/编辑表单。
///
/// 字段：标题/描述/类型（定点日程|待办）/日期时刻/优先级/关联课程/提醒设置。
/// 保存后写入 `remindDate` 冗余存储并调用提醒调度（创建/编辑/删除同步注册或取消）。
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
  /// 定点日程提醒选项：值 → remindOffsetMin（none=null，onTime=-1，N=提前 N 分钟）。
  static const List<(String, String)> _scheduledRemindOptions = [
    ('none', '不提醒'),
    ('onTime', '准时'),
    ('5', '提前 5 分钟'),
    ('10', '提前 10 分钟'),
    ('15', '提前 15 分钟'),
    ('30', '提前 30 分钟'),
    ('60', '提前 60 分钟'),
  ];

  /// 待办任务提醒选项。
  static const List<(String, String)> _todoRemindOptions = [
    ('none', '不提醒'),
    ('8am', '当天 8:00 提醒'),
  ];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;

  late TaskType _type;
  late DateTime _date;
  TimeOfDay? _time;
  late Priority _priority;
  int? _courseId;
  late String _remindOption;

  bool get _isEditing => widget.task != null;

  @override
  void initState() {
    super.initState();
    final Task? t = widget.task;
    _titleCtrl = TextEditingController(text: t?.title ?? '');
    _descCtrl = TextEditingController(text: t?.description ?? '');
    _type = t?.type ?? TaskType.todo;
    _date = _dateOnly(t?.dueDate ?? widget.initialDate ?? DateTime.now());
    _time = _parseTime(t?.dueTime);
    _priority = t?.priority ?? Priority.normal;
    _courseId = t?.courseId ?? widget.initialCourseId;
    _remindOption = _initRemindOption(t);
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

  String _initRemindOption(Task? t) {
    if (t == null) return 'none';
    if (t.type == TaskType.todo) {
      return t.remindDate != null ? '8am' : 'none';
    }
    final int? offset = t.remindOffsetMin;
    if (offset == null) return 'none';
    if (offset == -1) return 'onTime';
    const Set<String> allowed = {'5', '10', '15', '30', '60'};
    return allowed.contains('$offset') ? '$offset' : 'none';
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
              SegmentedButton<TaskType>(
                segments: const [
                  ButtonSegment(value: TaskType.todo, label: Text('待办任务')),
                  ButtonSegment(
                      value: TaskType.scheduled, label: Text('定点日程')),
                ],
                selected: {_type},
                onSelectionChanged: (Set<TaskType> selection) =>
                    _onTypeChanged(selection.first),
              ),
              const SizedBox(height: 16),
              _dateTimeTile(context),
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
              const SizedBox(height: 16),
              _remindDropdown(context),
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

  Widget _remindDropdown(BuildContext context) {
    final bool isScheduled = _type == TaskType.scheduled;
    final List<(String, String)> options =
        isScheduled ? _scheduledRemindOptions : _todoRemindOptions;
    return DropdownButtonFormField<String>(
      initialValue: _remindOption,
      decoration: const InputDecoration(
        labelText: '提醒设置',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final (String value, String label) in options)
          DropdownMenuItem<String>(value: value, child: Text(label)),
      ],
      onChanged: (String? v) => setState(() => _remindOption = v ?? 'none'),
    );
  }

  void _onTypeChanged(TaskType type) {
    setState(() {
      _type = type;
      _remindOption = 'none';
      if (type == TaskType.scheduled && _time == null) {
        _time = const TimeOfDay(hour: 8, minute: 0);
      }
    });
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = _dateOnly(picked));
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showPlaiTimePicker(
      context,
      initialTime: _time ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 定点日程必填时刻（兜底为 08:00）。
    if (_type == TaskType.scheduled && _time == null) {
      setState(() => _time = const TimeOfDay(hour: 8, minute: 0));
    }

    final String? dueTimeStr = _time != null ? formatTimeOfDay(_time!) : null;
    int? remindOffset;
    DateTime? remindDate;

    if (_type == TaskType.scheduled) {
      if (_remindOption == 'none') {
        remindOffset = null;
      } else if (_remindOption == 'onTime') {
        remindOffset = -1;
      } else {
        remindOffset = int.tryParse(_remindOption);
      }
      if (remindOffset != null && dueTimeStr != null) {
        remindDate = computeRemindAt(Task(
          title: '',
          type: _type,
          dueDate: _date,
          dueTime: dueTimeStr,
          remindOffsetMin: remindOffset,
        ));
      }
    } else {
      if (_remindOption == '8am') {
        remindOffset = -1;
        remindDate = DateTime(_date.year, _date.month, _date.day, 8);
      } else {
        remindOffset = null;
      }
    }

    final Task? old = widget.task;
    final Task task = Task(
      id: old?.id,
      title: _titleCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      type: _type,
      dueDate: _date,
      dueTime: dueTimeStr,
      priority: _priority,
      courseId: _courseId,
      remindOffsetMin: remindOffset,
      remindDate: remindDate,
      completed: old?.completed ?? false,
      completedAt: old?.completedAt,
      createdAt: old?.createdAt,
    );

    try {
      await saveTask(ref, task);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，请稍后重试')),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败，请稍后重试')),
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
