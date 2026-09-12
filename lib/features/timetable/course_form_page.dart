import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../shared/plai_toast.dart';
import 'color_utils.dart';
import 'format.dart';
import 'timetable_providers.dart';
import '../../services/notifications/notification_providers.dart';

/// 课程新建/编辑表单：名称/教师/地点/颜色/周次类型/开始结束周/星期/节次范围。
///
/// 保存后重排上课提醒；编辑模式支持删除（二次确认）。
class CourseFormPage extends ConsumerStatefulWidget {
  const CourseFormPage({super.key, required this.semester, this.course});

  /// 所属学期（决定节次与周数范围）。
  final Semester semester;

  /// 待编辑课程；null 为新建。
  final Course? course;

  @override
  ConsumerState<CourseFormPage> createState() => _CourseFormPageState();
}

class _CourseFormPageState extends ConsumerState<CourseFormPage> {
  static const List<String> _palette = [
    '#E57373', '#F06292', '#BA68C8', '#9575CD', '#64B5F6',
    '#4FC3F7', '#4DB6AC', '#81C784', '#FFB74D', '#A1887F',
    '#9E9E9E',
  ];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _teacherCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _startWeekCtrl;
  late final TextEditingController _endWeekCtrl;
  late final TextEditingController _weekListCtrl;

  late WeekType _weekType;
  late int _weekday;
  late int _startPeriod;
  late int _endPeriod;
  late String _color;

  /// 新建课程是否已套用「默认课程颜色」（用户显式选色后不再覆盖）。
  bool _defaultApplied = false;

  /// 最新 watch 到的节次表，供 [_resolvePeriod]/[_save] 复用。
  List<Period> _periods = const [];

  bool get _isEditing => widget.course != null;

  @override
  void initState() {
    super.initState();
    final Course? c = widget.course;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _teacherCtrl = TextEditingController(text: c?.teacher ?? '');
    _locationCtrl = TextEditingController(text: c?.location ?? '');
    _startWeekCtrl = TextEditingController(text: '${c?.startWeek ?? 1}');
    _endWeekCtrl =
        TextEditingController(text: '${c?.endWeek ?? widget.semester.totalWeeks}');
    _weekListCtrl = TextEditingController(text: c?.weekList.join(',') ?? '');
    _weekType = c?.weekType ?? WeekType.every;
    _weekday = c?.weekday ?? 1;
    _startPeriod = c?.startPeriod ?? 1;
    _endPeriod = c?.endPeriod ?? 1;
    // 新建课程先落无色（''），设置解析后由「默认课程颜色」接管。
    _color = (c?.color.isNotEmpty ?? false) ? c!.color : '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _teacherCtrl.dispose();
    _locationCtrl.dispose();
    _startWeekCtrl.dispose();
    _endWeekCtrl.dispose();
    _weekListCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Period>> periodsAsync = ref.watch(periodsProvider);
    final AsyncValue<TimetableStatusSettings> statusSettingsAsync =
        ref.watch(timetableStatusSettingsProvider);
    // 新建课程：设置解析后用「默认课程颜色」作为初始色（默认无色）；用户显式
    // 点过色板后不再覆盖。
    statusSettingsAsync.whenData((settings) {
      if (!_isEditing && !_defaultApplied) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_defaultApplied) {
            setState(() {
              _color = settings.defaultCourseColor;
              _defaultApplied = true;
            });
          }
        });
      }
    });
    return periodsAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: Text(_isEditing ? '编辑课程' : '新建课程')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => Scaffold(
        appBar: AppBar(title: Text(_isEditing ? '编辑课程' : '新建课程')),
        body: const Center(child: Text('节次配置加载失败')),
      ),
      data: (periods) => _buildForm(context, periods),
    );
  }

  Widget _buildForm(BuildContext context, List<Period> periods) {
    _periods = periods;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑课程' : '新建课程'),
        actions: [
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除课程',
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
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '课程名称',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入课程名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _teacherCtrl,
                decoration: const InputDecoration(
                  labelText: '教师（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _locationCtrl,
                decoration: const InputDecoration(
                  labelText: '上课地点（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text('课程颜色', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              _buildColorPicker(context),
              const SizedBox(height: 16),
              Text('周次类型', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<WeekType>(
                segments: const [
                  ButtonSegment(value: WeekType.every, label: Text('每周')),
                  ButtonSegment(value: WeekType.odd, label: Text('单周')),
                  ButtonSegment(value: WeekType.even, label: Text('双周')),
                  ButtonSegment(value: WeekType.custom, label: Text('自定义')),
                ],
                selected: {_weekType},
                onSelectionChanged: (Set<WeekType> selection) =>
                    setState(() => _weekType = selection.first),
              ),
              if (_weekType == WeekType.custom) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _weekListCtrl,
                  decoration: const InputDecoration(
                    labelText: '自定义周序列',
                    hintText: '如 1,3,5,8',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateWeekList,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _startWeekCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '开始周',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => _validateWeek(v, '开始周'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _endWeekCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '结束周',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => _validateWeek(v, '结束周'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _weekday,
                decoration: const InputDecoration(
                  labelText: '星期',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (int i = 1; i <= 7; i++)
                    DropdownMenuItem(value: i, child: Text(weekdayFullLabel(i))),
                ],
                onChanged: (int? v) => setState(() => _weekday = v ?? 1),
              ),
              const SizedBox(height: 12),
              _buildPeriodDropdowns(context, periods),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                child: Text(_isEditing ? '保存修改' : '添加课程'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorPicker(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 「无色」色块：空心圆形 + 斜线图标；选中时主色描边加宽并显示对勾。
        GestureDetector(
          onTap: () => setState(() {
            _color = '';
            _defaultApplied = true;
          }),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: _color.isEmpty
                  ? Border.all(color: scheme.primary, width: 3)
                  : Border.all(color: scheme.outline),
            ),
            child: _color.isEmpty
                ? Icon(Icons.check, color: scheme.primary, size: 18)
                : Icon(Icons.block, color: scheme.onSurfaceVariant, size: 18),
          ),
        ),
        for (final String hex in _palette)
          GestureDetector(
            onTap: () => setState(() {
              _color = hex;
              _defaultApplied = true;
            }),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colorFromHex(hex),
                shape: BoxShape.circle,
                border: _color == hex
                    ? Border.all(color: scheme.primary, width: 3)
                    : Border.all(color: Colors.transparent),
              ),
              child: _color == hex
                  ? const Icon(Icons.check, color: Colors.white, size: 18)
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _buildPeriodDropdowns(
      BuildContext context, List<Period> periods) {
    if (periods.isEmpty) {
      return const Text('暂无节次配置，请先到「节次时间」中添加节次',
          style: TextStyle(color: Colors.orange));
    }
    final List<int> indices = periods.map((p) => p.index).toList();
    final int start = _resolvePeriod(_startPeriod);
    final int end = _resolvePeriod(_endPeriod);
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: start,
            decoration: const InputDecoration(
              labelText: '开始节次',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final int i in indices)
                DropdownMenuItem(value: i, child: Text('第 $i 节')),
            ],
            onChanged: (int? v) {
              if (v == null) return;
              setState(() {
                _startPeriod = v;
                // 结束节次联动抬升，并同步状态字段，保证显示与落库一致。
                if (_endPeriod < v) _endPeriod = v;
              });
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: end,
            decoration: const InputDecoration(
              labelText: '结束节次',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final int i in indices)
                DropdownMenuItem(value: i, child: Text('第 $i 节')),
            ],
            onChanged: (int? v) {
              if (v == null) return;
              // 结束节次不允许小于开始节次。
              setState(() => _endPeriod = v < _startPeriod ? _startPeriod : v);
            },
          ),
        ),
      ],
    );
  }

  /// 解析节次序号：若该节已被删除则回落到节次表第一节，保证状态与落库一致。
  int _resolvePeriod(int value) {
    if (_periods.isEmpty) return value;
    final List<int> indices = _periods.map((p) => p.index).toList();
    return indices.contains(value) ? value : indices.first;
  }

  String? _validateWeek(String? value, String label) {
    final int? week = int.tryParse(value?.trim() ?? '');
    if (week == null) return '$label必须是整数';
    if (week < 1 || week > widget.semester.totalWeeks) {
      return '$label应在 1-$_totalWeeks 之间';
    }
    final int? start = int.tryParse(_startWeekCtrl.text.trim());
    final int? end = int.tryParse(_endWeekCtrl.text.trim());
    if (start != null && end != null && start > end) {
      return '开始周不能大于结束周';
    }
    return null;
  }

  String? _validateWeekList(String? value) {
    final List<int> parsed = _parseWeekList(value ?? '');
    if (parsed.isEmpty) return '请填写至少一个周次（如 1,3,5）';
    return null;
  }

  /// 解析「1,3,5」或「[1,3,5]」，含非法项时返回空列表。
  List<int> _parseWeekList(String raw) {
    String text = raw.trim();
    if (text.startsWith('[') && text.endsWith(']')) {
      text = text.substring(1, text.length - 1).trim();
    }
    if (text.isEmpty) return const [];
    final List<int> result = <int>[];
    for (final String part in text.split(RegExp(r'[,，;；\s]+'))) {
      if (part.isEmpty) continue;
      final int? v = int.tryParse(part);
      if (v == null || v < 1 || v > 99) return const [];
      result.add(v);
    }
    return result;
  }

  Future<void> _save() async {
    // 点击保存即收起键盘（保存后返回课表页，避免键盘残留）。
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_formKey.currentState!.validate()) return;
    final int startPeriod = _resolvePeriod(_startPeriod);
    final int endPeriod = _resolvePeriod(_endPeriod);
    if (startPeriod > endPeriod) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('开始节次不能大于结束节次')),
      );
      return;
    }

    final Course? existing = widget.course;
    final int? semesterId = widget.semester.id;
    if (semesterId == null) return;

    final int startWeek = int.parse(_startWeekCtrl.text.trim());
    final int endWeek = int.parse(_endWeekCtrl.text.trim());
    final List<int> weekList =
        _weekType == WeekType.custom ? _parseWeekList(_weekListCtrl.text) : const [];

    final Course course = Course(
      id: existing?.id,
      semesterId: semesterId,
      name: _nameCtrl.text.trim(),
      teacher: _teacherCtrl.text.trim(),
      location: _locationCtrl.text.trim(),
      color: _color,
      weekType: _weekType,
      weekList: weekList,
      startWeek: startWeek,
      endWeek: endWeek,
      weekday: _weekday,
      startPeriod: startPeriod,
      endPeriod: endPeriod,
    );

    // 新建查重：与当前学期已有课程全字段相同 → 提示是否再次添加，避免误重复添加。
    if (existing == null) {
      final List<Course> all = ref.read(coursesProvider).value ?? const [];
      final bool duplicate = all.any(
          (c) => c.semesterId == semesterId && _sameContent(c, course));
      if (duplicate) {
        final bool? again = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('重复添加'),
            content: const Text('该课程您已添加过一次，是否再次添加？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('否'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('是'),
              ),
            ],
          ),
        );
        if (again != true || !mounted) return;
      }
    }

    try {
      final repo = ref.read(timetableRepositoryProvider);
      if (existing == null) {
        await repo.insertCourse(course);
      } else {
        await repo.updateCourse(course);
      }
      ref.invalidate(coursesProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，请稍后重试')),
        );
      }
      return;
    }
    // 插入成功立即弹提示（不等提醒重排，重排较慢会延迟提示）。
    if (mounted) {
      // 气泡挂在本页与课表页共用的根 Overlay 上：先取 overlay（pop 之后本页
      // context 失效，不能再取值），再返回课表页，最后弹气泡。底部偏移交由
      // showPlaiToast 的默认规则处理（窄屏避让底部导航栏）。
      final OverlayState overlay = Overlay.of(context);
      Navigator.of(context).pop();
      // 保存后返回课表页再弹提示（异常不阻断）。
      try {
        showPlaiToast(
          context,
          existing == null ? '课程添加成功' : '课程已保存',
          overlay: overlay,
        );
      } catch (_) {
        // toast 失败不阻断。
      }
    }
    // 课程/节次改动后重排上课提醒（取消旧 + 按最新数据重建）；失败不阻断。
    try {
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      // 重排失败不阻断提示。
    }
  }

  /// 两门课内容是否完全相同（不含主键 id；学期 id 由调用方另行比较）。
  static bool _sameContent(Course a, Course b) =>
      a.name == b.name &&
      a.teacher == b.teacher &&
      a.location == b.location &&
      a.color == b.color &&
      a.weekType == b.weekType &&
      _listEquals(a.weekList, b.weekList) &&
      a.startWeek == b.startWeek &&
      a.endWeek == b.endWeek &&
      a.weekday == b.weekday &&
      a.startPeriod == b.startPeriod &&
      a.endPeriod == b.endPeriod;

  static bool _listEquals(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _confirmDelete() async {
    final Course? course = widget.course;
    if (course?.id == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除课程'),
        content: Text('确定删除课程「${course!.name}」吗？此操作不可恢复。'),
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
    if (confirmed != true || !mounted) return;

    final int courseId = course!.id!;
    try {
      await ref.read(timetableRepositoryProvider).deleteCourse(courseId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败，请稍后重试')),
        );
      }
      return;
    }
    ref.invalidate(coursesProvider);
    // 删除确认后立即返回课表界面，不被提醒取消/重排拖慢。
    if (mounted) Navigator.of(context).pop();
    // 删除后取消该课程全部提醒并重建其余提醒；失败不阻断返回。
    try {
      await ref
          .read(notificationSchedulerProvider)
          .cancelAllRemindersFor(courseId: courseId);
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      // 忽略：提醒重排失败不影响删除结果。
    }
  }

  int get _totalWeeks => widget.semester.totalWeeks;
}
