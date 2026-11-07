import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/task.dart';
import '../../shared/plai_time_picker.dart';
import '../../shared/plai_toast.dart';
import '../../shared/task_photo_picker.dart';
import '../../shared/task_photo_prepare.dart';
import '../../shared/task_photo_viewer.dart';
import '../timetable/format.dart';
import 'schedule_providers.dart';

/// 提醒重复方式（UI 原型；存储/调度只落地「每天」）。
enum _ReminderRepeat { daily, once }

/// 任务新建/编辑表单。
///
/// 字段：标题/描述/类型（待办任务|定点日程|每日打卡|一次性跨期）/日期（时刻）/
/// 优先级/关联课程/提醒。
/// - todo/scheduled：单个日期（scheduled 带具体时刻，todo 时刻可选）。
/// - daily/span：起始日期 + 截止日期。
/// - daily 提醒：沿用「每日提醒时刻」行 + 拨盘（每天同一时刻重复，区间内生效）。
/// - scheduled/todo/span 提醒：开关 + 重复方式（每天|不重复）+ 滚轮选时；
///   本阶段「不重复」仅做 UI 原型，保存被禁用（后续阶段再接存储与调度）。
/// 保存后调用提醒调度（创建/编辑/删除同步注册或取消）。
class TaskFormPage extends ConsumerStatefulWidget {
  const TaskFormPage({
    super.key,
    this.task,
    this.initialDate,
    this.initialCourseId,
  });

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
  late final List<Object?> _initialFields;
  bool _busy = false;
  bool _saving = false;
  bool _leaveDialogOpen = false;
  bool _allowPop = false;
  final List<String> _imagePaths = [];
  final Set<String> _newImagePaths = {};
  late final Future<void> Function(Iterable<String>) _releasePhotos;

  late TaskType _type;
  late DateTime _date;
  late DateTime _start;
  TimeOfDay? _time;
  TimeOfDay? _dailyRemindTime;
  late Priority _priority;
  int? _courseId;

  /// 非 daily 类型的「提醒」开关（daily 仍用上方 [_dailyRemindTime] 旧行）。
  bool _reminderEnabled = false;

  /// 「每天 | 不重复」重复方式。
  _ReminderRepeat _reminderRepeat = _ReminderRepeat.daily;

  /// 「不重复」选中的日期（仅日期语义）与时分。
  DateTime? _onceRemindDate;
  TimeOfDay? _onceRemindTime;

  /// 用户是否手动确定过「不重复」时刻（用于决定日期变化时是否重算默认）。
  bool _onceTouched = false;

  /// 用户是否手动选过「每天」的时分（用于决定切换重复方式是否沿用该时分）。
  bool _dailyTimeTouched = false;

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
    _imagePaths.addAll(t?.imagePaths ?? const <String>[]);
    _releasePhotos = ref.read(taskPhotoReleaseProvider);
    _type = t?.type ?? TaskType.todo;
    _date = _dateOnly(t?.dueDate ?? widget.initialDate ?? DateTime.now());
    // 起始日期：编辑回填 task.startDate（缺失回退截止日）；
    // 新建默认同截止日（今天 / 入口选日），切到 daily/span 时截止自动扩为 +6 天。
    _start = _dateOnly(t?.startDate ?? _date);
    _time = _parseTime(t?.dueTime);
    _dailyRemindTime = _parseTime(t?.dailyRemindTime);
    // 编辑回填：显式 reminderRepeat 优先；`null`（老数据）按「有每日时刻即每天」。
    final ReminderRepeat? repeat = t?.reminderRepeat;
    _reminderEnabled = repeat != null || _dailyRemindTime != null;
    if (repeat == ReminderRepeat.once) {
      _reminderRepeat = _ReminderRepeat.once;
      final DateTime? at = t?.remindOnceAt;
      if (at != null) {
        _onceRemindDate = _dateOnly(at);
        _onceRemindTime = TimeOfDay(hour: at.hour, minute: at.minute);
        _onceTouched = true;
      }
    }
    _dailyTimeTouched = _dailyRemindTime != null;
    if (!_onceTouched) _resetOnceDefault();
    _priority = t?.priority ?? Priority.normal;
    _courseId = t?.courseId ?? widget.initialCourseId;
    if (_type == TaskType.scheduled && _time == null) {
      _time = const TimeOfDay(hour: 8, minute: 0);
    }
    _initialFields = _fields;
    _titleCtrl.addListener(_onTextChanged);
    _descCtrl.addListener(_onTextChanged);
  }

  // Capture after defaults are applied so opening an untouched form stays clean.
  List<Object?> get _fields => <Object?>[
    _titleCtrl.text,
    _descCtrl.text,
    _type,
    _date,
    _start,
    _time,
    _dailyRemindTime,
    _priority,
    _courseId,
    _reminderEnabled,
    _reminderRepeat,
    _onceRemindDate,
    _onceRemindTime,
    ..._imagePaths,
  ];

  bool get _dirty => !listEquals(_initialFields, _fields);

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _leave() async {
    if (_busy || _leaveDialogOpen || _allowPop) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_dirty) {
      await _close();
      return;
    }
    _leaveDialogOpen = true;
    final bool? save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存更改？'),
        content: const Text('还有未保存的更改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('放弃更改'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存并退出'),
          ),
        ],
      ),
    );
    _leaveDialogOpen = false;
    if (!mounted || save == null) return;
    if (save) {
      await _save();
    } else {
      await _close();
    }
  }

  Future<void> _close() async {
    if (!mounted || _allowPop) return;
    setState(() => _allowPop = true);
    // PopScope must receive canPop before the programmatic pop.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    // No ref access after unmount; in-flight imports release their own result.
    if (!_saving) unawaited(_releaseNewPhotos());
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<(int, String)>> coursesAsync = ref.watch(
      courseOptionsProvider,
    );
    return PopScope<void>(
      canPop: _allowPop || (!_dirty && !_busy),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: coursesAsync.when(
        loading: () => Scaffold(
          appBar: AppBar(title: Text(_isEditing ? '编辑任务' : '新建任务')),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => Scaffold(
          appBar: AppBar(title: Text(_isEditing ? '编辑任务' : '新建任务')),
          body: const Center(child: Text('课程数据加载失败')),
        ),
        data: (options) => AbsorbPointer(
          absorbing: _busy || _allowPop,
          child: _buildForm(context, options),
        ),
      ),
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
              _descriptionField(),
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
              // daily 保持旧「每日提醒时刻」行；其余类型用「开关 + 重复方式 +
              // 提醒时刻」新 UI。
              if (_type == TaskType.daily)
                _dailyRemindTile(context)
              else
                _reminderSection(context),
              const SizedBox(height: 16),
              // 关联课程是可选次要字段，按用户要求放在表单最后一行。
              _courseDropdown(context, courseOptions),
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

  Widget _descriptionField() {
    final scheme = Theme.of(context).colorScheme;
    final cacheSide = (68 * MediaQuery.devicePixelRatioOf(context)).round();
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '描述（可选）',
        border: OutlineInputBorder(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _descCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
          ),
          if (_imagePaths.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _imagePaths.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 12, right: 12),
                            child: GestureDetector(
                              key: ValueKey('task_photo_$i'),
                              onTap: () => showTaskPhotoViewer(
                                context,
                                paths: List.of(_imagePaths),
                                initialIndex: i,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(_imagePaths[i]),
                                  width: 68,
                                  height: 68,
                                  cacheWidth: cacheSide,
                                  cacheHeight: cacheSide,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => SizedBox(
                                    width: 68,
                                    height: 68,
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: scheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            width: 24,
                            height: 24,
                            child: IconButton.filledTonal(
                              key: ValueKey('task_photo_remove_$i'),
                              tooltip: '移除照片',
                              visualDensity: VisualDensity.standard,
                              style: IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              constraints: const BoxConstraints.tightFor(
                                width: 24,
                                height: 24,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () => _removePhoto(i),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.bottomRight,
            child: IconButton(
              key: const Key('task_photo_add'),
              tooltip: '添加照片',
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 22),
              onPressed: _busy || _imagePaths.length >= 4 ? null : _pickPhotos,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickPhotos() async {
    if (_busy || _leaveDialogOpen || _allowPop || _imagePaths.length >= 4) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final picker = ref.read(taskPhotoPickerProvider);
    final prepare = ref.read(taskPhotoPreparerProvider);
    final store = ref.read(taskImageStoreProvider);
    setState(() => _busy = true);
    try {
      final paths = await picker(context, remaining: 4 - _imagePaths.length);
      for (final path in paths.take(4 - _imagePaths.length)) {
        if (!mounted) break;
        final prepared = await prepare(path);
        if (!mounted) break;
        final retained = await store.importFile(
          path,
          bytes: prepared?.bytes,
          extension: prepared?.extension,
        );
        _newImagePaths.add(retained);
        if (!mounted) {
          await _releaseNewPhotos();
          break;
        }
        setState(() => _imagePaths.add(retained));
      }
    } catch (_) {
      if (mounted) _warn('添加照片失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePhoto(int index) async {
    if (_busy || _leaveDialogOpen || _allowPop) return;
    final path = _imagePaths[index];
    setState(() {
      _busy = true;
      _imagePaths.removeAt(index);
    });
    // Existing images stay alive until the edited task is committed.
    if (_newImagePaths.contains(path)) {
      try {
        await _releasePhotos([path]);
        _newImagePaths.remove(path);
      } catch (_) {
        // Retain ownership so dispose/save can retry cleanup.
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _releaseNewPhotos() async {
    final paths = _newImagePaths.toList();
    if (paths.isEmpty) return;
    try {
      await _releasePhotos(paths);
      _newImagePaths.removeAll(paths);
    } catch (_) {
      // Cleanup failure must not turn a saved task into an apparent failure.
    }
  }

  /// 日期区：daily/span 显示「起始日期/截止日期」，其余维持单日期（+ 时刻）。
  Widget _dateSection(BuildContext context) {
    if (_isRangeType(_type)) {
      return Column(
        children: [
          _rangeDateTile(
            context,
            title: '起始日期',
            date: _start,
            onPick: _pickStartDate,
          ),
          const SizedBox(height: 4),
          _rangeDateTile(
            context,
            title: '截止日期',
            date: _date,
            onPick: _pickDueDate,
          ),
        ],
      );
    }
    return _dateTimeTile(context);
  }

  /// daily/span 的日期选择行（无具体时刻）。
  Widget _rangeDateTile(
    BuildContext context, {
    required String title,
    required DateTime date,
    required VoidCallback onPick,
  }) {
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
      // isExpanded 必须开：DropdownButton 内部用 IndexedStack 承载所有选项，
      // 宽度按「最宽的那个」算；默认 isExpanded:false 时外层 Row 会按最宽
      // 选项撑破一行 —— 选项形如「课程名（学期名）」时真机水平溢出过 228px
      // （黄黑条纹出现在关联课程框右侧，见 2026-10-31 截图）。
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '关联课程（可选）',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<int?>(
          value: null,
          child: Text('不关联课程', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        for (final (int id, String label) in options)
          DropdownMenuItem<int?>(
            value: id,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
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

  /// 非 daily 类型的提醒区：开关 → 重复方式（开时）→ 提醒时刻（开时）。
  Widget _reminderSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('提醒'),
          value: _reminderEnabled,
          onChanged: _onReminderToggled,
        ),
        if (_reminderEnabled) ...[
          const SizedBox(height: 4),
          Text('重复方式', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          // SegmentedButton 在窄屏/大字体下会按等分宽度压缩，不会横向溢出；
          // 外层再套横向滚动，极端字号下仍可完整查看而不报 RenderFlex 溢出。
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<_ReminderRepeat>(
                segments: const [
                  ButtonSegment<_ReminderRepeat>(
                    value: _ReminderRepeat.daily,
                    label: Text('每天'),
                  ),
                  ButtonSegment<_ReminderRepeat>(
                    value: _ReminderRepeat.once,
                    label: Text('不重复'),
                  ),
                ],
                selected: <_ReminderRepeat>{_reminderRepeat},
                showSelectedIcon: false,
                onSelectionChanged: (Set<_ReminderRepeat> selection) =>
                    _onRepeatChanged(selection.first),
              ),
            ),
          ),
          const SizedBox(height: 4),
          _reminderTimeTile(context),
        ],
      ],
    );
  }

  /// 「提醒时刻」行：副标题显示当前值，点击打开滚轮底部弹层。
  Widget _reminderTimeTile(BuildContext context) {
    final String subtitle = _reminderRepeat == _ReminderRepeat.daily
        ? '每天 ${formatTimeOfDay(_dailyRemindTime ?? _defaultReminderTime)}'
        : _formatOnceReminderLabel();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.alarm_outlined),
      title: const Text('提醒时刻'),
      subtitle: Text(subtitle),
      onTap: _pickReminderTime,
    );
  }

  static const TimeOfDay _defaultReminderTime = TimeOfDay(hour: 8, minute: 0);

  void _onReminderToggled(bool value) {
    setState(() {
      _reminderEnabled = value;
      if (!value) return;
      // 重开提醒保留上次值；从未设过才补默认 08:00。
      _dailyRemindTime ??= _defaultReminderTime;
      if (!_onceTouched || _onceRemindDate == null) _resetOnceDefault();
      _onceRemindTime ??= _dailyRemindTime;
    });
  }

  void _onRepeatChanged(_ReminderRepeat mode) {
    if (mode == _reminderRepeat) return;
    setState(() {
      if (mode == _ReminderRepeat.once) {
        if (_onceTouched || _dailyTimeTouched) {
          // 用户手动选过时分：切换重复方式保留该时分（若已过去，弹层会让
          // 用户改，确定按钮在结果不晚于现在时禁用）。
          _onceRemindTime = _dailyRemindTime ?? _onceRemindTime;
        } else {
          // 从未手动选过：按默认规则（任务日期 08:00 / 已过去则顺延）。
          _resetOnceDefault();
        }
      } else {
        _dailyRemindTime = _onceRemindTime ?? _dailyRemindTime;
      }
      _reminderRepeat = mode;
    });
  }

  /// 「不重复」默认值：任务日期当天 08:00；已过去则顺延到 now 之后最近时刻。
  /// 日期下限今天、上限今天 + 365 天。
  void _resetOnceDefault() {
    final DateTime now = DateTime.now();
    final DateTime base = _isRangeType(_type) ? _start : _date;
    DateTime candidate = DateTime(base.year, base.month, base.day, 8, 0);
    if (!candidate.isAfter(now)) {
      candidate = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
      ).add(const Duration(minutes: 1));
    }
    final DateTime today = _dateOnly(now);
    final DateTime last = today.add(const Duration(days: 365));
    DateTime day = _dateOnly(candidate);
    TimeOfDay time = TimeOfDay(hour: candidate.hour, minute: candidate.minute);
    if (day.isBefore(today)) {
      day = today;
      time = TimeOfDay(hour: now.hour, minute: now.minute);
    } else if (day.isAfter(last)) {
      day = last;
    }
    _onceRemindDate = day;
    _onceRemindTime = time;
  }

  /// 「不重复」副标题：`10月24日（次年） 08:00`；跨年必须显式标注。
  String _formatOnceReminderLabel() {
    final DateTime? date = _onceRemindDate;
    final TimeOfDay? time = _onceRemindTime;
    if (date == null || time == null) return '未设置';
    final String suffix = date.year == DateTime.now().year ? '' : '（次年）';
    return '${formatMonthDay(date)}$suffix ${formatTimeOfDay(time)}';
  }

  Future<void> _pickReminderTime() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_reminderRepeat == _ReminderRepeat.daily) {
      final TimeOfDay initial = _dailyRemindTime ?? _defaultReminderTime;
      final TimeOfDay? picked = await showModalBottomSheet<TimeOfDay>(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext sheetContext) =>
            _ReminderTimeWheelSheet(initialTime: initial),
      );
      if (picked != null && mounted) {
        setState(() {
          _dailyRemindTime = picked;
          _onceRemindTime = picked;
          _dailyTimeTouched = true;
        });
      }
      return;
    }

    final DateTime? date = _onceRemindDate;
    final TimeOfDay? time = _onceRemindTime;
    if (date == null || time == null) return;
    final DateTime? picked = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _ReminderDateTimeWheelSheet(
        initial: DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _onceRemindDate = _dateOnly(picked);
        _onceRemindTime = TimeOfDay(hour: picked.hour, minute: picked.minute);
        _dailyRemindTime = _onceRemindTime;
        _onceTouched = true;
      });
    }
  }

  void _onTypeChanged(TaskType type) {
    setState(() {
      final bool enteredRange = _isRangeType(type) && !_isRangeType(_type);
      final bool leftDaily = _type == TaskType.daily && type != TaskType.daily;
      _type = type;
      // 两套提醒 UI 共用同一时刻字段：daily ↔ 其余类型切换时同步开关状态，
      // 避免「开关关着却在 daily 行里留着时间」的不一致。
      if (leftDaily) _reminderEnabled = _dailyRemindTime != null;
      if (type == TaskType.daily && !_reminderEnabled) _dailyRemindTime = null;
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
    if (picked != null) {
      setState(() {
        _date = _dateOnly(picked);
        _onBaseDateChanged();
      });
    }
  }

  Future<void> _pickStartDate() async {
    final DateTime? picked = await _withPicker(() => _showDatePicker(_start));
    if (picked != null) {
      setState(() {
        _start = _dateOnly(picked);
        _onBaseDateChanged();
      });
    }
  }

  Future<void> _pickDueDate() async {
    final DateTime? picked = await _withPicker(() => _showDatePicker(_date));
    if (picked != null) {
      setState(() {
        _date = _dateOnly(picked);
        _onBaseDateChanged();
      });
    }
  }

  /// 任务基准日期变化后，若用户尚未手动选过「不重复」时刻，重算其默认值
  /// （默认 = 任务日期当天 08:00，已过去则顺延）。
  void _onBaseDateChanged() {
    if (!_onceTouched) _resetOnceDefault();
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
    if (picked != null) {
      setState(() {
        _dailyRemindTime = picked;
        _dailyTimeTouched = true;
      });
    }
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
    if (_busy || _leaveDialogOpen || _allowPop) return;
    setState(() {
      _busy = true;
      _saving = true;
    });
    try {
      await _saveImpl();
    } finally {
      _saving = false;
      if (mounted) {
        setState(() => _busy = false);
      } else {
        await _releaseNewPhotos();
      }
    }
  }

  Future<void> _saveImpl() async {
    final form = _formKey.currentState;
    if (form == null) {
      _warn('表单尚未就绪，请稍后重试');
      return;
    }
    if (!form.validate()) return;

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

    final String? dueTimeStr = _isRangeType(_type)
        ? null
        : (_time != null ? formatTimeOfDay(_time!) : null);
    // 提醒落库：
    // - daily 类型保持旧行为，只写 daily_remind_time（时刻为空即不提醒）；
    // - 其余类型开关关 = 两个字段都空（等价清除）；开关开时按重复方式写：
    //   「每天」→ daily_remind_time + reminder_repeat=daily；
    //   「不重复」→ remind_once_at + reminder_repeat=once（daily_remind_time 清空）。
    // 新版不再提供单次 offset 提醒 UI；编辑旧任务保存会把 remindOffsetMin/
    // remindDate 清空（存量未编辑任务的原单次调度仍保留，见调度器兼容分支）。
    String? dailyRemindStr;
    ReminderRepeat? repeat;
    DateTime? onceAt;
    if (_type == TaskType.daily) {
      dailyRemindStr = _dailyRemindTime != null
          ? formatTimeOfDay(_dailyRemindTime!)
          : null;
    } else if (_reminderEnabled) {
      if (_reminderRepeat == _ReminderRepeat.once) {
        final DateTime? date = _onceRemindDate;
        final TimeOfDay? time = _onceRemindTime;
        if (date == null || time == null) {
          _warn('请选择提醒时刻');
          return;
        }
        final DateTime at = DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        );
        // 与弹层「确定」同一判据：只能排到未来，已过去的要求重选。
        if (!at.isAfter(DateTime.now())) {
          _warn('提醒时刻已过，请重新选择');
          return;
        }
        repeat = ReminderRepeat.once;
        onceAt = at;
      } else {
        dailyRemindStr = formatTimeOfDay(
          _dailyRemindTime ?? _defaultReminderTime,
        );
        repeat = ReminderRepeat.daily;
      }
    }

    final Task? old = widget.task;
    final Task task = Task(
      id: old?.id,
      title: _titleCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      imagePaths: _imagePaths,
      type: _type,
      dueDate: _date,
      startDate: _isRangeType(_type) ? _start : null,
      dueTime: dueTimeStr,
      dailyRemindTime: dailyRemindStr,
      reminderRepeat: repeat,
      remindOnceAt: onceAt,
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
    _newImagePaths.removeAll(task.imagePaths);
    await _releaseNewPhotos();
    if (!mounted) return;
    // 先取 overlay（pop 之后本页 context 失效，不能再取值），再返回上一页，
    // 最后按需弹气泡。底部偏移交由 showPlaiToast 的默认规则处理。
    final OverlayState? overlay = reminderFailed ? Overlay.of(context) : null;
    await _close();
    if (reminderFailed && mounted) {
      try {
        showPlaiToast(context, '任务已保存，但提醒设置失败', overlay: overlay);
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
    if (_busy || _leaveDialogOpen || _allowPop) return;
    setState(() => _busy = true);
    try {
      await _confirmDeleteImpl();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDeleteImpl() async {
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
        showPlaiToast(context, '删除失败，请稍后重试', kind: PlaiToastKind.error);
      }
      return;
    }
    if (mounted) await _close();
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

// ---------------------------------------------------------------------------
// 提醒滚轮底部弹层
// ---------------------------------------------------------------------------

/// 弹层骨架：SafeArea + LayoutBuilder + 高度上限，滚轮区高度随可用空间收缩，
/// 标题/提示/按钮固定可见。
///
/// 高度策略（2026-10-31 修「无法正常显示 + 溢出」）：
/// - 旧实现取 `可用高 × 0.6` 且再减去键盘高度，键盘弹起时（表单里刚敲过字
///   就点「提醒时刻」）可用高只剩 ~200dp，上限被压到 ~120dp，扣掉标题与
///   按钮后滚轮区被挤成 0 甚至负数 —— 于是既看不到滚轮、又报 RenderFlex
///   溢出（实测 320×568 @1.5× 溢出 44px）。
/// - 现在上限只取 `min(可用高, 360)`，滚轮区高度 = `(上限 - 150).clamp(80,180)`，
///   空间仍不够时整体走 [SingleChildScrollView]，任何字号/键盘组合都不溢出。
class _ReminderSheetFrame extends StatelessWidget {
  const _ReminderSheetFrame({
    required this.title,
    required this.selectedLabel,
    required this.canConfirm,
    required this.onConfirm,
    required this.wheels,
    this.hint,
  });

  final String title;
  final String selectedLabel;
  final bool canConfirm;
  final VoidCallback onConfirm;
  final List<Widget> wheels;

  /// 不可确定时的原因提示（如「请选择晚于现在的时间」）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        // 键盘弹出时整体上移；可用高度随之收缩，滚轮区跟着变矮。
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double availableHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 360.0;
            final double maxHeight = math.min(availableHeight, 360.0);
            final double wheelHeight = (maxHeight - 150)
                .clamp(80.0, 180.0)
                .toDouble();
            return MediaQuery.withClampedTextScaling(
              // 弹层内文字最多放大到 1.5×（滚轮项另有 FittedBox 兜底）。
              maxScaleFactor: 1.5,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 标题 + 滚轮 + 提示放滚动区：空间不足时它们可滚动，
                    // 而底部按钮永远钉在可视区内（否则小屏 + 键盘下点不到）。
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    title,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    selectedLabel,
                                    key: const Key('reminder_sheet_selected'),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              height: wheelHeight,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final Widget wheel in wheels)
                                    Expanded(child: wheel),
                                ],
                              ),
                            ),
                            if (!canConfirm && hint != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  0,
                                ),
                                child: Text(
                                  hint!,
                                  key: const Key('reminder_sheet_hint'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Align(
                        alignment: Alignment.centerRight,
                        // Wrap：大字体下按钮可换行，始终完整可见。
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              key: const Key('reminder_sheet_confirm'),
                              onPressed: canConfirm ? onConfirm : null,
                              child: const Text('确定'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 滚轮项：FittedBox 只缩不放大，超长日期/大字体也不会撑破固定 itemExtent。
Widget _wheelItem(String text) {
  return Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: const TextStyle(fontSize: 16),
      ),
    ),
  );
}

Widget _numberWheel({
  required Key key,
  required FixedExtentScrollController controller,
  required int count,
  required ValueChanged<int> onSelectedItemChanged,
  required String Function(int) label,
}) {
  return CupertinoPicker(
    key: key,
    scrollController: controller,
    itemExtent: 40,
    useMagnifier: true,
    magnification: 1.05,
    onSelectedItemChanged: onSelectedItemChanged,
    children: [for (int i = 0; i < count; i++) _wheelItem(label(i))],
  );
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// 「每天」提醒：2 轮（时 / 分）。
class _ReminderTimeWheelSheet extends StatefulWidget {
  const _ReminderTimeWheelSheet({required this.initialTime});

  final TimeOfDay initialTime;

  @override
  State<_ReminderTimeWheelSheet> createState() =>
      _ReminderTimeWheelSheetState();
}

class _ReminderTimeWheelSheetState extends State<_ReminderTimeWheelSheet> {
  late int _hour;
  late int _minute;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialTime.hour;
    _minute = widget.initialTime.minute;
    _hourController = FixedExtentScrollController(initialItem: _hour);
    _minuteController = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ReminderSheetFrame(
      title: '提醒时刻（每天）',
      selectedLabel: '每天 ${_twoDigits(_hour)}:${_twoDigits(_minute)}',
      canConfirm: true,
      onConfirm: () =>
          Navigator.of(context).pop(TimeOfDay(hour: _hour, minute: _minute)),
      wheels: [
        _numberWheel(
          key: const Key('reminder_hour_picker'),
          controller: _hourController,
          count: 24,
          onSelectedItemChanged: (int value) => setState(() => _hour = value),
          label: _twoDigits,
        ),
        _numberWheel(
          key: const Key('reminder_minute_picker'),
          controller: _minuteController,
          count: 60,
          onSelectedItemChanged: (int value) => setState(() => _minute = value),
          label: _twoDigits,
        ),
      ],
    );
  }
}

/// 「不重复」提醒：3 轮（日期 / 时 / 分）。日期下限今天、上限今天 + 365 天；
/// 结果不晚于现在时禁用「确定」并提示。
class _ReminderDateTimeWheelSheet extends StatefulWidget {
  const _ReminderDateTimeWheelSheet({required this.initial});

  final DateTime initial;

  @override
  State<_ReminderDateTimeWheelSheet> createState() =>
      _ReminderDateTimeWheelSheetState();
}

class _ReminderDateTimeWheelSheetState
    extends State<_ReminderDateTimeWheelSheet> {
  late final DateTime _today;
  late final List<DateTime> _days;
  late int _dayIndex;
  late int _hour;
  late int _minute;
  late final FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;

  @override
  void initState() {
    super.initState();
    _today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    _days = <DateTime>[
      for (int i = 0; i <= 365; i++) _today.add(Duration(days: i)),
    ];
    final DateTime initialDay = DateTime(
      widget.initial.year,
      widget.initial.month,
      widget.initial.day,
    );
    final int index = _days.indexWhere(
      (DateTime d) =>
          d.year == initialDay.year &&
          d.month == initialDay.month &&
          d.day == initialDay.day,
    );
    _dayIndex = index < 0 ? 0 : index;
    _hour = widget.initial.hour;
    _minute = widget.initial.minute;
    _dayController = FixedExtentScrollController(initialItem: _dayIndex);
    _hourController = FixedExtentScrollController(initialItem: _hour);
    _minuteController = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _dayController.dispose();
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  DateTime get _selectedDay => _days[_dayIndex];

  DateTime get _selectedDateTime => DateTime(
    _selectedDay.year,
    _selectedDay.month,
    _selectedDay.day,
    _hour,
    _minute,
  );

  bool get _isValid => _selectedDateTime.isAfter(DateTime.now());

  String _selectedLabel() {
    final DateTime day = _selectedDay;
    final String suffix = day.year == DateTime.now().year ? '' : '（次年）';
    return '${formatFullDate(day)}$suffix ${weekdayLabel(day.weekday)} '
        '${_twoDigits(_hour)}:${_twoDigits(_minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final bool valid = _isValid;
    return _ReminderSheetFrame(
      title: '提醒时刻（不重复）',
      selectedLabel: _selectedLabel(),
      canConfirm: valid,
      hint: '请选择晚于现在的时间',
      onConfirm: () => Navigator.of(context).pop(_selectedDateTime),
      wheels: [
        _numberWheel(
          key: const Key('reminder_day_picker'),
          controller: _dayController,
          count: _days.length,
          onSelectedItemChanged: (int value) {
            setState(() => _dayIndex = value);
          },
          label: (int index) {
            final DateTime d = _days[index];
            return '${d.year}年${d.month}月${d.day}日';
          },
        ),
        _numberWheel(
          key: const Key('reminder_hour_picker'),
          controller: _hourController,
          count: 24,
          onSelectedItemChanged: (int value) => setState(() => _hour = value),
          label: _twoDigits,
        ),
        _numberWheel(
          key: const Key('reminder_minute_picker'),
          controller: _minuteController,
          count: 60,
          onSelectedItemChanged: (int value) => setState(() => _minute = value),
          label: _twoDigits,
        ),
      ],
    );
  }
}
