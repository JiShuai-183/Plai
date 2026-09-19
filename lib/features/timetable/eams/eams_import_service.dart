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

  /// 清掉的「上次导入的」课程数。
  final int removed;

  /// 本次新增的课程数（= 写回的记账条数）。
  final int inserted;

  /// 导入后该学期的课程总数（含手动课程）。
  final int total;
}

/// 郑航教务课表导入编排：**记账式**（见 `docs/教务一键导入-实施计划.md` §5）。
///
/// 纯 merge 的去重键为 `(semester_id, name, weekday, start_week, end_week,
/// start_period, end_period)`，**不含教室 / 教师 / weekList**，于是「教务换教室」
/// 不会更新、「教务改周次」会产出重复课。记账式修掉这两点：
///
/// 1. 读 setting「`eams.imported_ids.<学期id>`」= 上次导入写入的课程 id 集合；
/// 2. 删除其中**仍然存在**的课程（用户已手删的 id 直接跳过）；
/// 3. `importJson(…, strategy: merge)` 写入；
/// 4. 取导入前后的课程 id 差集 = 本次新增，序列化写回记账。
///
/// **用户手动添加的课程从未进入记账 → 结构上不可能被删或改**（计划书决策 4）。
class EamsImportService {
  EamsImportService({
    required this.timetable,
    required this.settings,
    required this.importExport,
    EamsClient? client,
  }) : _client = client ?? EamsClient();

  /// 课表域仓库（只依赖 `plai-data` 的接口）。
  final ITimetableRepository timetable;

  /// 设置域仓库（存记账键）。
  final ISettingsRepository settings;

  /// 课表导入导出工具（复用其严格校验 + 事务写入 + merge 去重）。
  final TimetableImportExport importExport;

  final EamsClient _client;

  /// 记账键前缀；完整键为 `eams.imported_ids.<学期id>`。
  static const String ledgerKeyPrefix = 'eams.imported_ids';

  /// 某学期的记账键。
  static String ledgerKey(int semesterId) => '$ledgerKeyPrefix.$semesterId';

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

  /// 执行导入（记账式）。
  ///
  /// [updatedSemester] 非空时**先**更新学期再导入 —— 由 UI 在用户**明确勾选**后
  /// 传入，service 不自行决定（改开学日会影响该学期全部课程，包括手动的；
  /// 见计划书 §5.3）。
  Future<EamsImportOutcome> import({
    required EamsImportPreview preview,
    required int semesterId,
    Semester? updatedSemester,
  }) async {
    if (updatedSemester != null) {
      await timetable.updateSemester(updatedSemester.copyWith(id: semesterId));
    }

    final String key = ledgerKey(semesterId);

    // ① 读记账。
    final Set<int> ledger = await _readLedger(key);

    // ② 删除记账中仍存在的课程（手删过的 id 已不存在 → 跳过，无副作用）。
    final List<Course> existing = await timetable.getCourses(semesterId);
    final Set<int> existingIds = <int>{
      for (final Course c in existing)
        if (c.id != null) c.id!,
    };
    var removed = 0;
    for (final int id in ledger) {
      if (!existingIds.contains(id)) continue;
      removed += await timetable.deleteCourse(id);
    }

    // ③ 组装并导入（merge）。
    final Semester? semester = await timetable.getSemesterById(semesterId);
    if (semester == null) throw StateError('学期不存在: $semesterId');

    // ④ 差集取「本次新增」：前快照在**删除之后**取，避免 sqlite 复用 rowid
    //    造成差集失真（删掉的 id 若被新行复用，会误判为「非新增」）。
    final Set<int> beforeIds = _idsOf(await timetable.getCourses(semesterId));

    await importExport.importJson(
      _buildImportJson(preview.timetable, semester),
      targetSemesterId: semesterId,
      strategy: ImportStrategy.merge,
    );

    final List<Course> after = await timetable.getCourses(semesterId);
    final Set<int> afterIds = _idsOf(after);
    final Set<int> added = afterIds.difference(beforeIds);

    // ⑤ 记账写回：只留本次导入的 id（过期条目由此清掉）。
    final List<int> sorted = added.toList()..sort();
    await settings.setValue(key, jsonEncode(sorted));

    return EamsImportOutcome(
      removed: removed,
      inserted: added.length,
      total: afterIds.length,
    );
  }

  // ---- 内部 ----

  /// 组装 `importJson` 需要的 `{semester, periods, courses}` JSON。
  ///
  /// `targetSemesterId` 非空时 `semester` 只做结构校验、不写库 —— 传**当前学期**
  /// 的 `toJson()` 即可。节次沿用 `defaultPeriods` 前 `unitCount` 条（merge 策略下
  /// 已存在的 idx 会跳过，不破坏用户自定义的节次时间）。
  String _buildImportJson(EamsTimetable parsed, Semester semester) {
    final int count = _periodCount(parsed.unitCount);
    final Map<String, Object?> json = <String, Object?>{
      'semester': semester.toJson(),
      'periods': <Map<String, Object?>>[
        for (final p in defaultPeriods.take(count)) p.toJson(),
      ],
      'courses': parsed.toCourseJsonList(),
    };
    return jsonEncode(json);
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

  /// 读记账（JSON 数组字符串）；缺失 / 损坏一律当作空集合，绝不抛。
  Future<Set<int>> _readLedger(String key) async {
    final String? raw = await settings.getValue(key);
    if (raw == null || raw.trim().isEmpty) return <int>{};
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return <int>{};
      return <int>{
        for (final dynamic e in decoded)
          if (e is int) e,
      };
    } on FormatException {
      return <int>{};
    }
  }
}
