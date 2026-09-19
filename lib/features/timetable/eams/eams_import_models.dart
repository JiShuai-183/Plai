import '../../../data/models/course.dart';

/// 郑航教务（Beangle / EAMS 系）课表解析的中间模型（纯数据，无网络 / 无数据库）。
///
/// 解析层把 `courseTableForStd!courseTable.action` 的响应体（一段 JS）转为
/// [EamsTimetable]，再由 `eams_import_service` 组装成
/// `TimetableImportExport.importJson` 需要的 JSON。中间模型刻意**不含**
/// `id` / `semesterId` / `color` —— 这些由导入侧回填。

/// 一条「同一课程、同一星期、同一节次段」的上课安排。
///
/// 一个教务 `TaskActivity` 若横跨多个星期或含不连续节次，会被拆成多条
/// [EamsActivity]（见 `eams_parser.dart`）。
class EamsActivity {
  const EamsActivity({
    required this.courseName,
    required this.courseCode,
    required this.teacher,
    required this.location,
    required this.weekday,
    required this.startPeriod,
    required this.endPeriod,
    required this.weeks,
  });

  /// 课程名（已剥离结尾的 `(<课程代码>)` 后缀，课程名自带的中文括号保留）。
  final String courseName;

  /// 课程代码（取自 `TaskActivity` arg2 最后一对括号内，如 `26271.MK00001A.050`）。
  final String courseCode;

  /// 教师名，多教师用 `,` 连接；实验辅导老师追加在后（见解析层说明）。
  final String teacher;

  /// 教室名（原样保留，可能是「示例场馆」「示例场地」等非规范名）。
  final String location;

  /// 星期几（1=周一 … 7=周日）。
  final int weekday;

  /// 起始节次（1 起，闭区间）。
  final int startPeriod;

  /// 结束节次（1 起，闭区间）。
  final int endPeriod;

  /// 上课周次集合（升序、去重，第 1 周起）。
  final List<int> weeks;

  @override
  bool operator ==(Object other) =>
      other is EamsActivity &&
      other.courseName == courseName &&
      other.courseCode == courseCode &&
      other.teacher == teacher &&
      other.location == location &&
      other.weekday == weekday &&
      other.startPeriod == startPeriod &&
      other.endPeriod == endPeriod &&
      _listEquals(other.weeks, weeks);

  @override
  int get hashCode => Object.hash(courseName, courseCode, teacher, location,
      weekday, startPeriod, endPeriod, Object.hashAll(weeks));

  @override
  String toString() => 'EamsActivity($courseName @ 周$weekday '
      '$startPeriod-$endPeriod, weeks=$weeks)';

  static bool _listEquals(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 一次解析的完整结果。
class EamsTimetable {
  const EamsTimetable({
    required this.year,
    required this.unitCount,
    required this.activities,
    this.warnings = const [],
  });

  /// `CourseTable` 第一个参数（年份，如 2026）。
  final int year;

  /// 每天节数（`var unitCount = N;`，如 10）。
  final int unitCount;

  /// 全部上课安排（未去重，按解析顺序）。
  final List<EamsActivity> activities;

  /// 解析告警 / 可诊断问题（非致命；致命问题见下：返回空结果）。
  ///
  /// 关键用途之一：**合并键冲突检测**。`importJson(strategy: merge)` 的去重键
  /// 为 `(name, weekday, startWeek, endWeek, startPeriod, endPeriod)`，两条产出
  /// 课程若键相同，第二条会被静默丢弃 —— 解析层必须在此暴露告警，绝不静默丢课。
  final List<String> warnings;

  /// 无数据的空结果（解析失败时返回）。
  static const EamsTimetable empty =
      EamsTimetable(year: 0, unitCount: 0, activities: []);

  /// 去重后的课程名集合（仅用于统计 / 测试断言）。
  Set<String> get distinctCourseNames =>
      activities.map((a) => a.courseName).toSet();

  /// 转成 `TimetableImportExport.importJson` 所需的 `courses` 数组，
  /// 每项为 `Course.toJson()` 的形状（camelCase）。
  ///
  /// [color] 为统一填充的课程颜色（导入侧套默认色的入口）；`id` / `semesterId`
  /// 在 JSON 里仅占位（`importJson` 会忽略，由 `targetSemesterId` 回填）。
  List<Map<String, Object?>> toCourseJsonList({String color = ''}) {
    return <Map<String, Object?>>[
      for (final EamsActivity a in activities)
        _courseJson(a, classifyWeeks(a.weeks), color),
    ];
  }

  static Map<String, Object?> _courseJson(
      EamsActivity a, WeekClassification c, String color) {
    return <String, Object?>{
      'id': null,
      'semesterId': 0,
      'name': a.courseName,
      'teacher': a.teacher,
      'location': a.location,
      'color': color,
      'weekType': c.weekType.code,
      'weekList': c.weekList,
      'startWeek': c.startWeek,
      'endWeek': c.endWeek,
      'weekday': a.weekday,
      'startPeriod': a.startPeriod,
      'endPeriod': a.endPeriod,
    };
  }
}

/// 周次集合的归类结果（映射到 `Course` 的 `weekType` / 周次字段）。
class WeekClassification {
  const WeekClassification({
    required this.weekType,
    required this.startWeek,
    required this.endWeek,
    this.weekList = const [],
  });

  final WeekType weekType;
  final int startWeek;
  final int endWeek;

  /// 仅 [WeekType.custom] 非空，其余为空列表。
  final List<int> weekList;

  @override
  bool operator ==(Object other) =>
      other is WeekClassification &&
      other.weekType == weekType &&
      other.startWeek == startWeek &&
      other.endWeek == endWeek &&
      _listEquals(other.weekList, weekList);

  @override
  int get hashCode =>
      Object.hash(weekType, startWeek, endWeek, Object.hashAll(weekList));

  @override
  String toString() =>
      'WeekClassification(${weekType.code}, $startWeek-$endWeek, $weekList)';

  static bool _listEquals(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 把周次集合归类为 `every` / `odd` / `even` / `custom`。
///
/// 判定边界（**已由单测锁死**，输入先升序去重）：
/// 1. 连续整数（步长 1，起点任意）→ `every`，`startWeek`=首、`endWeek`=末。
///    例：`{1..16}` → `every` 1-16；`{5,6,7}` → `every` 5-7；`{8,9}` → `every` 8-9。
/// 2. 全为奇数且步长 2 连续 → `odd`，`startWeek`/`endWeek` 取首末。
///    例：`{11,13,15}` → `odd` 11-15。
/// 3. 全为偶数且步长 2 连续 → `even`。例：`{10,12,14}` → `even` 10-14。
/// 4. 其余 → `custom`，`weekList` = 完整集合，`startWeek`/`endWeek` 取首末。
///    例：`{1,2,3,8,9,11,13,15}` → `custom`。
///
/// 注意规则 1 先于 2/3：单元素集合（如 `{3}`）恒为 `every 3-3`，不会落到
/// `odd`；`{1,3}` 因步长非 1 而落到 `odd`。
WeekClassification classifyWeeks(List<int> weeks) {
  final List<int> w = weeks.toSet().toList()..sort();
  if (w.isEmpty) {
    // 调用方应先行拦截空周次；这里兜底给一个安全值。
    return const WeekClassification(
        weekType: WeekType.every, startWeek: 1, endWeek: 1);
  }
  final int first = w.first;
  final int last = w.last;
  if (_step(w, 1)) {
    return WeekClassification(
        weekType: WeekType.every, startWeek: first, endWeek: last);
  }
  if (w.length >= 2 && w.every((int x) => x.isOdd) && _step(w, 2)) {
    return WeekClassification(
        weekType: WeekType.odd, startWeek: first, endWeek: last);
  }
  if (w.length >= 2 && w.every((int x) => x.isEven) && _step(w, 2)) {
    return WeekClassification(
        weekType: WeekType.even, startWeek: first, endWeek: last);
  }
  return WeekClassification(
    weekType: WeekType.custom,
    startWeek: first,
    endWeek: last,
    weekList: List<int>.unmodifiable(w),
  );
}

/// [w] 是否严格以 [step] 递增（首元素之外逐项校验差值）。
bool _step(List<int> w, int step) {
  for (var i = 1; i < w.length; i++) {
    if (w[i] - w[i - 1] != step) return false;
  }
  return true;
}
