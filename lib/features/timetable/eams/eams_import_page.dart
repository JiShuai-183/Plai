import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/date_utils.dart';
import '../../../data/models/semester.dart';
import '../../../shared/plai_toast.dart';
import '../timetable_providers.dart';
import 'eams_client.dart';
import 'eams_import_service.dart';

/// 教务导入编排服务的 Provider。
///
/// 页面只依赖它；widget 测试可整体 override（注入内存假 repo / 假客户端），
/// 从而**不发真网络、不碰数据库**。
final eamsImportServiceProvider = Provider<EamsImportService>((ref) {
  return EamsImportService(
    timetable: ref.watch(timetableRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    importExport: ref.watch(timetableImportExportProvider),
  );
});

/// 开学日选择回调（默认走 [showDatePicker]；测试可注入假实现绕开真实弹窗）。
typedef EamsStartDatePicker = Future<DateTime?> Function(
  BuildContext context,
  DateTime initialDate,
);

/// 「从教务导入课表」页面：输入学号密码 → 拉取预览 → 确认导入。
///
/// 设计要点（见 `docs/教务一键导入-实施计划.md` §5.3 / §8）：
/// - **密码绝不落盘**：输入不进 settings、不进任何持久化；每次进入页面密码框为空。
///   学号可记（键 `eams.username`）。
/// - **开学日冲突**：教务侧推导的周次超出当前学期总周数时给出警告 + 勾选框
///   （默认**不勾**）；用户手动改开学日需**二次确认**（会改变该学期全部课程日期）。
///   未修改时传 `null`，学期原样不动。
/// - 连接为明文 HTTP，页面内明示用户（§8 风险 1）。
class EamsImportPage extends ConsumerStatefulWidget {
  const EamsImportPage({super.key, this.pickStartDate});

  /// 开学日选择回调；null 时用系统 [showDatePicker]。
  final EamsStartDatePicker? pickStartDate;

  /// 记住的学号设置键（点号命名空间）。
  static const String usernameSettingKey = 'eams.username';

  @override
  ConsumerState<EamsImportPage> createState() => _EamsImportPageState();
}

class _EamsImportPageState extends ConsumerState<EamsImportPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _obscurePassword = true;
  bool _loading = false;

  /// 上一次失败的可读文案（null 表示无错误）。
  String? _errorMessage;

  /// 拉取成功后的预览（未导入前非空）。
  EamsImportPreview? _preview;

  /// 导入完成后的结果摘要。
  EamsImportOutcome? _outcome;

  /// 用户修改后的开学日；null = 未修改（导入时学期原样不动）。
  DateTime? _startDate;

  /// 是否勾选「同时把本学期总周数改为 maxWeek」（默认不勾，见 §5.3）。
  bool _bumpTotalWeeks = false;

  /// 以教务课表为基准的对账结果（拉取后算出；见 [EamsImportPlan]）。
  EamsImportPlan? _plan;

  /// 是否把对账结果施加到本学期。
  ///
  /// **默认 true = 以教务为准**（用户已决定以教务课表为基准）；
  /// 用户可主动取消 —— 取消后点「确认导入」**不会改动任何课程**。
  bool _applyChanges = true;

  @override
  void initState() {
    super.initState();
    _loadRememberedUsername();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 预填上次记住的学号（密码不预填、不读取 —— 从不落盘）。
  Future<void> _loadRememberedUsername() async {
    try {
      final String? saved = await ref
          .read(settingsRepositoryProvider)
          .getValue(EamsImportPage.usernameSettingKey);
      if (!mounted || saved == null || saved.isEmpty) return;
      _username.text = saved;
    } catch (_) {
      // 设置不可用（如宿主 widget 测试）时静默，不阻断页面。
    }
  }

  @override
  Widget build(BuildContext context) {
    // 预热「课表设置」：导入时要用其 `defaultCourseColor`（生产已在
    // app_shell 启动时预热，这里 watch 保证本页独立可用、不依赖启动时序）。
    ref.watch(timetableStatusSettingsProvider);
    final AsyncValue<Semester?> semesterAsync =
        ref.watch(currentSemesterProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('从教务导入课表')),
      body: semesterAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('学期信息加载失败')),
        data: (Semester? semester) => _buildBody(context, semester),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Semester? semester) {
    final EamsImportPreview? preview = _preview;
    final EamsImportOutcome? outcome = _outcome;
    final bool canFetch = semester != null && !_loading;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (semester == null) ...<Widget>[
          _noticeCard(context, '当前没有学期，无法导入。请先在课表页创建或切换到目标学期。'),
          const SizedBox(height: 16),
        ],
        _sectionTitle(context, '教务账号'),
        const SizedBox(height: 8),
        TextField(
          controller: _username,
          enabled: !_loading,
          autofillHints: const <String>[],
          decoration: const InputDecoration(
            labelText: '学号',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: !_loading,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: '密码',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
              icon: Icon(_obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '连接为明文 http，密码不会保存在本机。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: canFetch ? _fetch : null,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('拉取课表'),
        ),
        if (_errorMessage != null) ...<Widget>[
          const SizedBox(height: 16),
          _errorCard(context, _errorMessage!),
        ],
        if (outcome != null) ...<Widget>[
          const SizedBox(height: 24),
          _outcomeCard(context, outcome),
        ] else if (preview != null && semester != null) ...<Widget>[
          const SizedBox(height: 24),
          ..._previewSection(context, semester, preview),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ 拉取

  Future<void> _fetch() async {
    // 入口防抖：只靠按钮 `onPressed: null` 不够 —— rebuild 要等下一帧，
    // 同一帧内到达的第二次点击仍会触发。重复拉取会打两次登录请求，
    // 徒增撞上服务端「提交过快」闸门与「密码错 N 次锁号」的风险。
    if (_loading) return;

    final String username = _username.text.trim();
    final String password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      _fail('请输入学号与密码');
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
      _preview = null;
      _outcome = null;
      _startDate = null;
      _bumpTotalWeeks = false;
      _plan = null;
      _applyChanges = true;
    });

    try {
      final EamsImportService service =
          ref.read(eamsImportServiceProvider);
      final EamsImportPreview preview = await service.fetchPreview(
          username: username, password: password);
      if (!mounted) return;

      // 以教务课表为基准做全量对账，列出将新增 / 更新 / 删除的课程。
      EamsImportPlan? plan;
      final Semester? semesterAsyncValue =
          ref.read(currentSemesterProvider).valueOrNull;
      final int? semesterId = semesterAsyncValue?.id;
      if (semesterId != null) {
        plan = await service.plan(preview: preview, semesterId: semesterId);
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _preview = preview;
        _plan = plan;
      });
      await _rememberUsername(username);
    } on EamsException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _fail(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      // 走进兜底说明抛的不是 [EamsException] 家族（网络 / 超时 / IO /
      // ClientException 都已在 `EamsClient._send` 里包成 [EamsNetworkException]，
      // 协议不符也已是 [EamsProtocolException]），即**未预期**异常 ——
      // 恰恰最需要细节。原先这里是 `catch (_)`，把类型与消息一并吞掉、
      // 只留一句「请稍后重试」，真机上一旦出现未预期异常就完全无法排查
      //（已踩过：一个 `_TypeError` 被吞成无信息提示，白跑了好几轮）。
      // 消息里不含凭据（密码只出现在 POST body）。
      final String detail = e.toString();
      _fail('拉取课表失败，请稍后重试\n[${e.runtimeType}] '
          '${detail.length > 160 ? '${detail.substring(0, 160)}…' : detail}');
    }
  }

  /// 记住学号（**只记学号**；密码从不读写 settings）。
  Future<void> _rememberUsername(String username) async {
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setValue(EamsImportPage.usernameSettingKey, username);
    } catch (_) {
      // 落盘失败不影响本次导入。
    }
  }

  // ------------------------------------------------------------ 预览

  List<Widget> _previewSection(
    BuildContext context,
    Semester semester,
    EamsImportPreview preview,
  ) {
    final int effectiveWeeks =
        _bumpTotalWeeks && preview.maxWeek > semester.totalWeeks
            ? preview.maxWeek
            : semester.totalWeeks;
    final DateTime effectiveStart = _startDate ?? semester.startDate;

    return <Widget>[
      _sectionTitle(context, '导入预览'),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '教务侧：共 ${preview.courseCount} 门课 / ${preview.entryCount} 条安排 '
                '/ 用到第 ${preview.minWeek}–${preview.maxWeek} 周',
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '当前学期：${semester.name}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => _changeStartDate(context, semester),
                    child: const Text('修改开学日'),
                  ),
                ],
              ),
              Text(
                '开学日 ${dateOnlyToString(effectiveStart)} · 共 $effectiveWeeks 周',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      if (preview.maxWeek > semester.totalWeeks) ...<Widget>[
        const SizedBox(height: 12),
        _weekOverflowCard(context, semester, preview),
      ],
      if (_plan?.hasChanges ?? false) ...<Widget>[
        const SizedBox(height: 12),
        _changeCard(context, _plan!),
      ],
      if (preview.warnings.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final String w in preview.warnings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '提示：$w',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 16),
      if (preview.entryCount == 0)
        _noticeCard(context, '教务课表里没有解析到任何课程安排，无法导入。')
      else
        FilledButton(
          // 取消勾选「以教务为准」后禁用 —— 明确告诉用户本次不会改动任何课程。
          onPressed: (_loading || !_applyChanges || _plan == null)
              ? null
              : () => _confirmImport(semester, preview),
          child: Text(_applyChanges ? '确认导入' : '已取消更改'),
        ),
    ];
  }

  /// 周次超出当前学期总周数的警告 + 「同时改总周数」勾选框（默认不勾）。
  Widget _weekOverflowCard(
    BuildContext context,
    Semester semester,
    EamsImportPreview preview,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '教务课表用到第 ${preview.maxWeek} 周，超出当前学期的 '
              '${semester.totalWeeks} 周',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Checkbox(
                  value: _bumpTotalWeeks,
                  onChanged: _loading
                      ? null
                      : (bool? value) =>
                          setState(() => _bumpTotalWeeks = value ?? false),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '同时把本学期总周数改为 ${preview.maxWeek}',
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                        Text(
                          '（会影响该学期全部课程的日期，包括你手动添加的）',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onErrorContainer),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 撞键课程裁决卡片（见 [EamsKeyCollision]）。
  ///
  /// 教务侧与现有课程**同键**（名称/星期/节次/周次全同）时，`importJson(merge)`
  /// 会跳过教务侧版本，改动永远进不来。故这里逐条列出，交由用户确认后再施加。
  ///
  /// **默认勾选 = 以教务为准**（用户已决定以教务课表为基准）；取消勾选后点
  /// 「确认导入」不会改动任何课程。
  Widget _changeCard(BuildContext context, EamsImportPlan plan) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int added = plan.countOf(EamsChangeKind.added);
    final int updated = plan.countOf(EamsChangeKind.updated);
    final int removed = plan.countOf(EamsChangeKind.removed);
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('与当前学期的差异（以教务课表为准）：'
                '将新增 $added 门、更新 $updated 门、删除 $removed 门'),
            const SizedBox(height: 6),
            for (final EamsChange c in plan.changes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  _changeLine(c),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Checkbox(
                  value: _applyChanges,
                  onChanged: _loading
                      ? null
                      : (bool? value) =>
                          setState(() => _applyChanges = value ?? false),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('以教务为准应用以上变更'),
                        Text(
                          '（取消勾选则本次不做任何改动 —— 想先自己看看差异时用）',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 变更清单里的一行：〔新增 / 更新 / 删除〕课程名 + 时间 + 差异。
  static String _changeLine(EamsChange c) {
    final String tag = switch (c.kind) {
      EamsChangeKind.added => '将新增',
      EamsChangeKind.updated => '将更新',
      EamsChangeKind.removed => '将删除',
    };
    return '· ［$tag］${c.courseName}　${c.detail}';
  }

  // ------------------------------------------------------------ 开学日

  /// 修改开学日：先选日期，再**二次确认**（会改变该学期全部课程日期）。
  Future<void> _changeStartDate(BuildContext context, Semester semester) async {
    final DateTime initial = _startDate ?? semester.startDate;
    final EamsStartDatePicker pick = widget.pickStartDate ?? _pickStartDate;
    final DateTime? picked = await pick(context, initial);
    if (picked == null || !context.mounted) return;

    final bool confirmed = await _confirmStartDateChange(context) ?? false;
    if (!confirmed || !mounted) return;
    setState(() {
      _startDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  Future<DateTime?> _pickStartDate(BuildContext context, DateTime initialDate) {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  Future<bool?> _confirmStartDateChange(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('修改开学日'),
        content: const Text('修改开学日会改变本学期的全部课程日期，包括你手动添加的课程。确定？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 需要随导入一起写回的学期；未做任何修改时返回 null（学期原样不动）。
  Semester? _updatedSemester(Semester semester, EamsImportPreview preview) {
    final bool dateChanged = _startDate != null;
    final bool weeksChanged =
        _bumpTotalWeeks && preview.maxWeek > semester.totalWeeks;
    if (!dateChanged && !weeksChanged) return null;
    return semester.copyWith(
      startDate: _startDate,
      totalWeeks: weeksChanged ? preview.maxWeek : null,
    );
  }

  // ------------------------------------------------------------ 导入

  Future<void> _confirmImport(
    Semester semester,
    EamsImportPreview preview,
  ) async {
    final int? semesterId = semester.id;
    if (semesterId == null) return;
    if (_loading) return; // 入口防抖，同 _fetch（rebuild 要等下一帧）。
    // 用户取消了「以教务为准」→ 本次不做任何改动（按钮也已禁用，这里是二道保险）。
    final EamsImportPlan? plan = _plan;
    if (!_applyChanges || plan == null) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final EamsImportOutcome outcome =
          await ref.read(eamsImportServiceProvider).import(
                preview: preview,
                plan: plan,
                semesterId: semesterId,
                // 只有用户明确改过才传（service 不自行改学期，见 §5.3）。
                updatedSemester: _updatedSemester(semester, preview),
                // 与手动加课 / JSON·CSV 导入同一来源的默认课程颜色。
                defaultCourseColor: ref
                        .read(timetableStatusSettingsProvider)
                        .valueOrNull
                        ?.defaultCourseColor ??
                    '',
              );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _outcome = outcome;
      });
      _refreshAfterImport();
    } on EamsException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _fail(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _fail('导入失败，请稍后重试');
    }
  }

  /// 导入后刷新课表数据并重排上课提醒（失败不阻断结果展示）。
  void _refreshAfterImport() {
    ref.invalidate(semestersProvider);
    ref.invalidate(coursesProvider);
    ref.invalidate(periodsProvider);
    ref.invalidate(holidaysProvider);
    // 重排提醒：课表已变，旧提醒需作废重建。
    rescheduleTimetableReminders(ref).catchError((Object _) {});
  }

  // ------------------------------------------------------------ 公共组件

  Widget _sectionTitle(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.titleMedium);

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
    showPlaiToast(context, message, kind: PlaiToastKind.error);
  }

  Widget _errorCard(BuildContext context, String message) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard(BuildContext context, String message) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.info_outline),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  Widget _outcomeCard(BuildContext context, EamsImportOutcome outcome) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '已更新 ${outcome.removed} 条、新增 ${outcome.inserted} 条、'
              '该学期现有 ${outcome.total} 条',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
