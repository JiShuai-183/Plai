import 'dart:convert';

import '../../../data/db/default_periods.dart';
import '../../../data/import_export/timetable_import_export.dart';
import '../../../data/models/course.dart';
import '../../../data/models/semester.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/timetable_repository.dart';
import 'eams_client.dart';
import 'eams_import_models.dart';
import 'eams_parser.dart';

/// 一次拉取解析的**预览**（不写库，供 UI 展示后再由用户确认导入）。
class EamsImportPreview {
  const EamsImportPreview({
    required this.timetable,
    required this.entryCount,
    required this.courseCount,
    required this.minWeek,
    required this.maxWeek,
    this.warnings = const [],
  });

  /// 由解析结果推导统计量（活动条数 / 去重课程数 / 实际用到的周次范围）。
  ///
  /// [warnings] 应传入**解析层 warnings 原样透传**（可再追加导入侧告警）。
  factory EamsImportPreview.fromTimetable(
    EamsTimetable timetable, {
    List<String> warnings = const [],
  }) {
    var minWeek = 0;
    var maxWeek = 0;
    for (final EamsActivity a in timetable.activities) {
      for (final int w in a.weeks) {
        if (minWeek == 0 || w < minWeek) minWeek = w;
        if (w > maxWeek) maxWeek = w;
      }
    }
    return EamsImportPreview(
      timetable: timetable,
      entryCount: timetable.activities.length,
      courseCount: timetable.distinctCourseNames.length,
      minWeek: minWeek,
      maxWeek: maxWeek,
      warnings: warnings,
    );
  }

  /// 解析出的中间模型。
  final EamsTimetable timetable;

  /// 上课安排条数（= `activities.length`）。
  final int entryCount;

  /// 去重后的课程数（按课程名）。
  final int courseCount;

  /// 数据实际用到的最小 / 最大教学周（无数据时为 0）。
  final int minWeek;
  final int maxWeek;

  /// 告警：解析层 warnings 原样透传 + 导入侧补充（节次裁剪等）。
  final List<String> warnings;
}

/// 一次导入的结果摘要。
class EamsImportOutcome {
  const EamsImportOutcome({
    required this.removed,
    required this.inserted,
    required this.total,
  });

  /// 本次先删掉、随后由 merge 重写的现有课程数（勾选的「将更新 + 将删除」）。
  final int removed;

  /// 本次新写入的课程数。
  final int inserted;

  /// 导入后该学期的课程总数（含手动课程）。
  final int total;
}

/// 差异对账里的一条变更类型。
enum EamsChangeKind {
  /// 教务有、本地没有 → 将新增。
  added,

  /// 同键但字段不同（教师 / 教室 / 周次明细）→ 将更新。
  updated,

  /// 本地有、教务没有 → 将删除。
  removed,
}

/// 一条变更（供界面逐条展示与**逐项勾选**）。
class EamsChange {
  const EamsChange({
    required this.key,
    required this.kind,
    required this.courseName,
    required this.detail,
    this.existingCourseId,
  });

  /// 该变更的标识 —— 即 merge 去重键，在全表内唯一（见 [EamsImportService.plan]）。
  /// 界面用它记录用户勾选了哪几条。
  final String key;

  final EamsChangeKind kind;
  final String courseName;

  /// 时间与差异说明，如「周1 第1-1节 · X205 · 教室：A101 → B202」。
  final String detail;

  /// 对应的现有课程 id：仅「将更新 / 将删除」有；纯新增为 null。
  final int? existingCourseId;
}

/// 「以教务课表为基准」的全量对账结果（见 `docs/教务一键导入-实施计划.md` §5）。
///
/// 配对键沿用 `TimetableImportExport` 在 merge 策略下的去重键
/// `(name, weekday, startWeek, endWeek, startPeriod, endPeriod)`。
class EamsImportPlan {
  const EamsImportPlan({required this.changes});

  /// 全部差异，按「新增 → 更新 → 删除」再按课程名排序。
  final List<EamsChange> changes;

  /// 有无差异。无差异时不必打扰用户。
  bool get hasChanges => changes.isNotEmpty;

  /// 某一类变更的条数。
  int countOf(EamsChangeKind kind) =>
      changes.where((EamsChange c) => c.kind == kind).length;

  /// 全部变更的标识（界面初次展示时默认全选）。
  Set<String> get allKeys =>
      <String>{for (final EamsChange c in changes) c.key};

  /// 在勾选集合下，执行时要**先删掉**的现有课程 id（= 勾选的「将更新」与「将删除」）。
  ///
  /// 必须先删：同键的会被 `merge` 当作已存在而跳过，不删则教务改动进不来。
  Set<int> replacedIdsFor(Set<String> selected) => <int>{
        for (final EamsChange c in changes)
          if (selected.contains(c.key) && c.existingCourseId != null)
            c.existingCourseId!,
      };

  /// 在勾选集合下，要**从写入内容里剔除**的标识 —— 即**未勾选的「将新增」**。
  ///
  /// 未勾选的「将更新 / 将删除」无需剔除：前者本地同键记录仍在（merge 会跳过），
  /// 后者本就不在教务列表里。但未勾选的「将新增」若不剔除，`merge` 照样会插进去。
  Set<String> skippedAddKeysFor(Set<String> selected) => <String>{
        for (final EamsChange c in changes)
          if (!selected.contains(c.key) && c.kind == EamsChangeKind.added) c.key,
      };
}

/// 郑航教务课表导入编排：**以教务课表为基准的全量对账**（见实施计划 §5）。
///
/// 流程：`plan()` 先按 merge 去重键
/// `(name, weekday, startWeek, endWeek, startPeriod, endPeriod)` 对账，产出
/// 「将新增 / 将更新 / 将删除」三类变更，交界面逐项展示与勾选；再由
/// `import()` 施加**用户勾选**的那部分 —— 先删掉这些变更涉及的现有课程
/// （同键的不先删，merge 会当作已存在而跳过），再用 merge 写入教务课程。
///
/// **曾有过的记账式方案（记「哪些课是我导入的」）已废弃** —— 该信息必然不完备
/// （用户手动加过、或用「导入导出」页导过的课都不在记账里），导致「教务改了不生效」
/// 与「同键旧记录删不掉、产生重复」两个实测故障。详见实施计划 §5.1。
class EamsImportService {
  EamsImportService({
    required this.timetable,
    required this.settings,
    required this.importExport,
    EamsClient? client,
  }) : _client = client ?? EamsClient();

  /// 课表域仓库（只依赖 `plai-data` 的接口）。
  final ITimetableRepository timetable;

  /// 设置域仓库。
  final ISettingsRepository settings;

  /// 课表导入导出工具（复用其严格校验 + 事务写入 + merge 去重）。
  final TimetableImportExport importExport;

  final EamsClient _client;

  /// 拉取 + 解析，**不写库**。UI 拿到预览后再让用户确认。
  Future<EamsImportPreview> fetchPreview({
    required String username,
    required String password,
  }) async {
    final String html =
        await _client.fetchCourseTableHtml(username: username, password: password);
    final EamsTimetable timetable = parseEamsCourseTable(html);

    final List<String> warnings = <String>[...timetable.warnings];
    final int unit = timetable.unitCount;
    if (unit > defaultPeriods.length) {
      warnings.add('教务课表每天 $unit 节，超过 Plai 默认节次模板的 '
          '${defaultPeriods.length} 节；导入只沿用前 ${defaultPeriods.length} 节的时间。');
    } else if (unit <= 0) {
      warnings.add('未能从教务响应确定每天节数，节次将沿用 Plai 默认模板全部 '
          '${defaultPeriods.length} 节。');
    }

    return EamsImportPreview.fromTimetable(timetable, warnings: warnings);
  }

  /// 以**教务课表为基准**做全量对账，产出变更清单（见 [EamsImportPlan]）。
  ///
  /// 配对按 merge 去重键；分三类：
  /// - **将新增**：教务有、本地没有；
  /// - **将更新**：键相同但教师 / 教室 / 周次明细不同；
  /// - **将删除**：本地有、教务没有（**含用户手动添加的** —— 用户已决定以教务为
  ///   基准，但此项会在界面上逐条列出并由用户确认，见计划书 §5）。
  ///
  /// 无差异时 `changes` 为空，界面不必打扰用户。
  Future<EamsImportPlan> plan({
    required EamsImportPreview preview,
    required int semesterId,
  }) async {
    final Map<String, Map<String, Object?>> incoming =
        <String, Map<String, Object?>>{};
    for (final Map<String, Object?> c in preview.timetable.toCourseJsonList()) {
      incoming.putIfAbsent(_keyOfJson(c), () => c);
    }

    final Map<String, Course> local = <String, Course>{};
    for (final Course c in await timetable.getCourses(semesterId)) {
      local.putIfAbsent(_keyOfCourse(c), () => c);
    }

    final List<EamsChange> changes = <EamsChange>[];

    // 本地 → 教务：删 or 更新。
    for (final MapEntry<String, Course> e in local.entries) {
      final Course cur = e.value;
      final Map<String, Object?>? inc = incoming[e.key];
      if (inc == null) {
        changes.add(EamsChange(
          key: e.key,
          kind: EamsChangeKind.removed,
          courseName: cur.name,
          detail: _detailOfCourse(cur),
          existingCourseId: cur.id,
        ));
        continue;
      }
      final String diff = _diffOf(cur, inc);
      if (diff.isEmpty) continue; // 完全一致 → 不动（保留其 id 与自定义颜色）。
      changes.add(EamsChange(
        key: e.key,
        kind: EamsChangeKind.updated,
        courseName: cur.name,
        detail: '${_detailOfCourse(cur)} · $diff',
        existingCourseId: cur.id,
      ));
    }

    // 教务 → 本地：新增。
    for (final MapEntry<String, Map<String, Object?>> e in incoming.entries) {
      if (local.containsKey(e.key)) continue;
      changes.add(EamsChange(
        key: e.key,
        kind: EamsChangeKind.added,
        courseName: (e.value['name'] as String?) ?? '',
        detail: _detailOfJson(e.value),
      ));
    }

    changes.sort((EamsChange a, EamsChange b) {
      final int byKind = a.kind.index.compareTo(b.kind.index);
      if (byKind != 0) return byKind;
      return a.courseName.compareTo(b.courseName);
    });
    return EamsImportPlan(changes: changes);
  }

  /// 同键课程之间**可见字段**的差异描述；无差异返回空串。
  ///
  /// 只比教师 / 教室 / 周次明细（键已覆盖名称、星期、节次、起止周）。
  static String _diffOf(Course cur, Map<String, Object?> inc) {
    final List<String> parts = <String>[];

    final String teacher = (inc['teacher'] as String?) ?? '';
    if (cur.teacher != teacher) {
      parts.add('教师：${_show(cur.teacher)} → ${_show(teacher)}');
    }

    final String location = (inc['location'] as String?) ?? '';
    if (cur.location != location) {
      parts.add('教室：${_show(cur.location)} → ${_show(location)}');
    }

    final String weekType = (inc['weekType'] as String?) ?? '';
    final List<int> weekList = <int>[
      for (final dynamic w in (inc['weekList'] as List<dynamic>? ?? <dynamic>[]))
        w as int,
    ];
    if (cur.weekType.code != weekType || !_sameWeeks(cur.weekList, weekList)) {
      parts.add('周次已调整');
    }

    return parts.join('；');
  }

  static bool _sameWeeks(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _detailOfCourse(Course c) =>
      '周${c.weekday} 第${c.startPeriod}-${c.endPeriod}节 · ${_show(c.location)}';

  static String _detailOfJson(Map<String, Object?> c) =>
      '周${c['weekday']} 第${c['startPeriod']}-${c['endPeriod']}节 · '
      '${_show((c['location'] as String?) ?? '')}';

  /// 空串显示为「（空）」，避免出现「」「」这种读不出来的对比。
  static String _show(String s) => s.trim().isEmpty ? '（空）' : s.trim();

  /// merge 策略的去重键，**复刻** `TimetableImportExport._findCourseId` 的 WHERE 条件：
  /// `(name, weekday, start_week, end_week, start_period, end_period)`。
  ///
  /// ⚠️ 该规则由**数据层**定义，此处无法调用其私有方法只能复刻 —— 若数据层改规则，
  /// 这里必须同步。`eams_import_service_test` 有对应用例钉住两侧一致。
  static String _keyOfParts(Object? name, Object? weekday, Object? startWeek,
          Object? endWeek, Object? startPeriod, Object? endPeriod) =>
      <Object?>[name, weekday, startWeek, endWeek, startPeriod, endPeriod]
          .join('\u0000');

  static String _keyOfCourse(Course c) => _keyOfParts(
      c.name, c.weekday, c.startWeek, c.endWeek, c.startPeriod, c.endPeriod);

  static String _keyOfJson(Map<String, Object?> c) => _keyOfParts(
        c['name'],
        c['weekday'],
        c['startWeek'],
        c['endWeek'],
        c['startPeriod'],
        c['endPeriod'],
      );

  /// 执行导入：按 [plan] 把该学期课程调整成**教务课表的样子**。
  ///
  /// 步骤：先删 [EamsImportPlan.replacedCourseIds]（将更新 + 将删除的那些），
  /// 再用 `merge` 写入教务全量课程 —— 删过的会被重新写入（拿到教务版本），
  /// 同键且无变化的被跳过（**保留其 id 与用户自定义的颜色**）。
  ///
  /// ⚠️ **不再有记账**：用户已决定「以教务课表为基准」，是否施加由调用方（界面上
  /// 的勾选）决定 —— **不调用本方法即不做任何改动**。
  ///
  /// [updatedSemester] 非空时**先**更新学期再导入 —— 由 UI 在用户**明确勾选**后
  /// 传入，service 不自行决定（改开学日会影响该学期全部课程；见计划书 §5.3）。
  /// [defaultCourseColor] 为「课表设置」里用户自定义的默认课程颜色，套给
  /// **解析结果中颜色为空**的课程（已有非空色不覆盖）。与手动加课
  /// (`course_form_page`) / JSON·CSV 导入 (`import_export_page`) 保持同一来源。
  Future<EamsImportOutcome> import({
    required EamsImportPreview preview,
    required EamsImportPlan plan,
    required Set<String> selectedChangeKeys,
    required int semesterId,
    Semester? updatedSemester,
    String defaultCourseColor = '',
  }) async {
    if (selectedChangeKeys.isEmpty) {
      throw ArgumentError.value(selectedChangeKeys, 'selectedChangeKeys',
          '至少要勾选一条变更；界面在未勾选时应禁用确认按钮，不应调用本方法');
    }
    if (updatedSemester != null) {
      await timetable.updateSemester(updatedSemester.copyWith(id: semesterId));
    }

    // ① 先删**已勾选**的「将更新 / 将删除」现有课程 —— 同键的不先删，merge 会当作
    //    已存在而跳过，教务改动就进不来（此前「改了看不到」与「产生重复」的根因）。
    final Set<int> present = _idsOf(await timetable.getCourses(semesterId));
    var removed = 0;
    for (final int id in plan.replacedIdsFor(selectedChangeKeys)) {
      if (!present.contains(id)) continue; // 用户已手删 → 跳过，无副作用。
      removed += await timetable.deleteCourse(id);
    }

    // ② 写入教务课程。**未勾选的「将新增」要从写入内容里剔除**，否则 merge 照样会插。
    //    未勾选的「将更新」无需剔除：本地同键记录仍在，merge 会跳过。
    //    前快照在删除之后取，避免 sqlite 复用 rowid 使差集失真。
    final Semester? semester = await timetable.getSemesterById(semesterId);
    if (semester == null) throw StateError('学期不存在: $semesterId');

    final Set<int> beforeIds = _idsOf(await timetable.getCourses(semesterId));
    await importExport.importJson(
      _buildImportJson(
        preview.timetable,
        semester,
        defaultCourseColor,
        skipKeys: plan.skippedAddKeysFor(selectedChangeKeys),
      ),
      targetSemesterId: semesterId,
      strategy: ImportStrategy.merge,
    );
    final Set<int> afterIds = _idsOf(await timetable.getCourses(semesterId));

    return EamsImportOutcome(
      removed: removed,
      inserted: afterIds.difference(beforeIds).length,
      total: afterIds.length,
    );
  }

  // ---- 内部 ----

  /// 组装 `importJson` 需要的 `{semester, periods, courses}` JSON。
  ///
  /// `targetSemesterId` 非空时 `semester` 只做结构校验、不写库 —— 传**当前学期**
  /// 的 `toJson()` 即可。节次沿用 `defaultPeriods` 前 `unitCount` 条（merge 策略下
  /// 已存在的 idx 会跳过，不破坏用户自定义的节次时间）。
  ///
  /// [defaultCourseColor] 只填补 `color` 为空的课程（非空色原样保留）；空串表示
  /// 不套色、维持解析层的原值。
  String _buildImportJson(
    EamsTimetable parsed,
    Semester semester,
    String defaultCourseColor, {
    Set<String> skipKeys = const <String>{},
  }) {
    final int count = _periodCount(parsed.unitCount);
    final Map<String, Object?> json = <String, Object?>{
      'semester': semester.toJson(),
      'periods': <Map<String, Object?>>[
        for (final p in defaultPeriods.take(count)) p.toJson(),
      ],
      'courses': <Map<String, Object?>>[
        for (final Map<String, Object?> c in parsed.toCourseJsonList())
          // [skipKeys] = 用户在变更清单里**取消勾选**的「将新增」项。
          if (!skipKeys.contains(_keyOfJson(c))) _fillColor(c, defaultCourseColor),
      ],
    };
    return jsonEncode(json);
  }

  /// 课程 JSON 的 `color` 为空时用 [fallback] 填补；非空 / [fallback] 为空则原样。
  static Map<String, Object?> _fillColor(
    Map<String, Object?> course,
    String fallback,
  ) {
    if (fallback.isEmpty) return course;
    final Object? color = course['color'];
    if (color is String && color.isNotEmpty) return course;
    return <String, Object?>{...course, 'color': fallback};
  }

  /// 需要沿用的默认节次数：[unitCount] 与模板长度取小；[unitCount] 非正时取满。
  static int _periodCount(int unitCount) {
    if (unitCount <= 0) return defaultPeriods.length;
    return unitCount < defaultPeriods.length ? unitCount : defaultPeriods.length;
  }

  static Set<int> _idsOf(List<Course> courses) => <int>{
        for (final Course c in courses)
          if (c.id != null) c.id!,
      };
}
