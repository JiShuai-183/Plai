import 'eams_import_models.dart';

/// 解析郑航教务（Beangle / EAMS 系）课表响应体，返回中间模型 [EamsTimetable]。
///
/// **纯函数**：不碰网络、不碰数据库、不抛异常。解析失败（空串 / 截断 / 缺
/// `CourseTable` / 缺 `unitCount`）一律返回空结果并在 `warnings` 里说明原因。
///
/// 响应是一段 JS（见 `docs/教务一键导入-实施计划.md` §2.4，已用真样本逐位验证）：
///
/// ```js
/// var table0 = new CourseTable(2026, 70);   // arg1 = 年份；arg2 = 7 × 每天节数
/// var unitCount = 10;                        // 每天节数
/// var actTeachers = [{id:260,name:"…",lab:false}];
/// activity = new TaskActivity(teacherIds, teacherNames,
///     "17808(26271.MK00001A.050)",           // arg2 课程代码
///     "示例课程甲(26271.MK00001A.050)", // arg3 课程名(代码)
///     "258", "X205",                        // arg4 教室 id；arg5 教室名
///     "0011000011111111…",                    // arg6 周次串（长 53）
///     null, null, assistantName, "", "");
/// index = 1*unitCount+0;                       // i = 星期索引(0=周一)…
/// table0.activities[index][…] = activity;
/// index = 1*unitCount+1;                       // j = 节次索引(0=第一节)
/// ```
///
/// 四条关键编码：
/// - `index = i*unitCount + j`：`i` 为星期索引（0=周一 … 6=周日）→ `weekday=i+1`；
///   `j` 为节次索引（0 起）→ `period=j+1`。
/// - 周次串第 `p` 位（`p` 从 1 起）对应第 `p` 教学周；第 0 位是恒为 `'0'` 的占位，忽略。
/// - 一个 `TaskActivity` 可有多条 `index` 行：按 `weekday` 分组，组内**连续节次合并**
///   为一条（不连续则拆多条）。同一课程的多条 `TaskActivity` 各自产出独立条目。
/// - 参数按「引号外的逗号」切分（`teacherIds` 是 `xxx.join(',')` 这类表达式，含引号）。
///
/// 教师：取该 activity 之前**最近一个** `var actTeachers = [...]` 里的全部 `name`
/// 用 `,` 连接；`assistantName`（arg9）非空且不在列表内时追加（真样本中 arg9 恒为
/// 标识符 `assistantName`，其运行时值由 `_.filter/_.reject` 依 `teachers` 推出）。
EamsTimetable parseEamsCourseTable(String source) {
  final List<String> warnings = <String>[];

  if (source.trim().isEmpty) {
    warnings.add('教务课表响应为空');
    return EamsTimetable(
        year: 0, unitCount: 0, activities: const [], warnings: warnings);
  }

  final RegExpMatch? table = _rgxCourseTable.firstMatch(source);
  if (table == null) {
    warnings.add('未找到 CourseTable 声明，无法确定年份');
    return EamsTimetable(
        year: 0, unitCount: 0, activities: const [], warnings: warnings);
  }
  final int year = int.parse(table.group(1)!);

  final RegExpMatch? uc = _rgxUnitCount.firstMatch(source);
  if (uc == null) {
    warnings.add('未找到 unitCount 声明，无法确定每天节数');
    return EamsTimetable(
        year: year, unitCount: 0, activities: const [], warnings: warnings);
  }
  final int unitCount = int.parse(uc.group(1)!);

  final List<RegExpMatch> tasks = _rgxTaskActivity.allMatches(source).toList();
  if (tasks.isEmpty) {
    warnings.add('未找到任何 TaskActivity 上课安排');
    return EamsTimetable(
        year: year,
        unitCount: unitCount,
        activities: const [],
        warnings: warnings);
  }

  final List<_TeacherList> actTeacherLists =
      _collectTeacherLists(source, _rgxActTeachers);
  final List<_TeacherList> allTeacherLists =
      _collectTeacherLists(source, _rgxTeachers);
  final List<_IndexCell> indices = <_IndexCell>[
    for (final RegExpMatch m in _rgxIndex.allMatches(source))
      _IndexCell(
          pos: m.start, weekday: int.parse(m.group(1)!) + 1,
          period: int.parse(m.group(2)!) + 1),
  ];

  final List<EamsActivity> activities = <EamsActivity>[];
  for (var k = 0; k < tasks.length; k++) {
    final RegExpMatch task = tasks[k];
    final int pos = task.start;
    final int nextPos = k + 1 < tasks.length ? tasks[k + 1].start : source.length;
    final int no = k + 1;
    try {
      final List<String>? args = _splitArgs(source, task.end - 1);
      if (args == null || args.length < 7) {
        warnings.add('第 $no 条 TaskActivity 参数不完整，已跳过');
        continue;
      }
      final String courseCode = _extractCode(_unquote(args[2]));
      final String courseName = _stripCode(_unquote(args[3]), courseCode);
      final String location = _unquote(args[5]);
      final List<int> weeks = _parseWeeks(_unquote(args[6]));

      // 按 weekday 归组节次，组内合并连续节次。
      final Map<int, List<int>> byWeekday = <int, List<int>>{};
      for (final _IndexCell c in indices) {
        if (c.pos <= pos || c.pos >= nextPos) continue;
        if (c.weekday < 1 || c.weekday > 7 ||
            c.period < 1 || c.period > unitCount) {
          warnings.add('课程「$courseName」节次越界：'
              '周${c.weekday} 第${c.period}节，已忽略该格');
          continue;
        }
        byWeekday.putIfAbsent(c.weekday, () => <int>[]).add(c.period);
      }
      if (byWeekday.isEmpty) {
        warnings.add('课程「$courseName」缺少可用的 index 行，已跳过');
        continue;
      }
      if (weeks.isEmpty) {
        warnings.add('课程「$courseName」周次串为空，已跳过');
        continue;
      }

      final String teacher = _resolveTeacher(
        args,
        _nearest(actTeacherLists, pos),
        _nearest(allTeacherLists, pos),
      );

      for (final int weekday in byWeekday.keys.toList()..sort()) {
        final List<int> periods = byWeekday[weekday]!..sort();
        for (final List<int> run in _mergeRuns(periods)) {
          activities.add(EamsActivity(
            courseName: courseName,
            courseCode: courseCode,
            teacher: teacher,
            location: location,
            weekday: weekday,
            startPeriod: run[0],
            endPeriod: run[1],
            weeks: weeks,
          ));
        }
      }
    } catch (e) {
      warnings.add('第 $no 条 TaskActivity 解析失败：$e');
    }
  }

  _detectMergeConflicts(activities, warnings);

  return EamsTimetable(
      year: year, unitCount: unitCount, activities: activities,
      warnings: warnings);
}

// ---------------------------------------------------------------------------
// 合并键冲突检测
// ---------------------------------------------------------------------------

/// 检测「产出课程在 `importJson(strategy: merge)` 下会互相覆盖」的情况。
///
/// merge 的去重键为 `(name, weekday, startWeek, endWeek, startPeriod, endPeriod)`
/// （不含教师 / 教室 / 颜色 / weekList）。键相同 → 后写被丢弃。此处按同一规则
/// 分组，命中即写入 warnings，**绝不静默丢课**。
void _detectMergeConflicts(List<EamsActivity> activities, List<String> warnings) {
  final Map<String, int> counts = <String, int>{};
  final Map<String, String> label = <String, String>{};
  for (final EamsActivity a in activities) {
    final WeekClassification c = classifyWeeks(a.weeks);
    final String key = '${a.courseName}|${a.weekday}|${c.startWeek}|'
        '${c.endWeek}|${a.startPeriod}|${a.endPeriod}';
    counts[key] = (counts[key] ?? 0) + 1;
    label[key] = '${a.courseName} 周${a.weekday} '
        '第${a.startPeriod}-${a.endPeriod}节 周次${c.startWeek}-${c.endWeek}';
  }
  for (final MapEntry<String, int> e in counts.entries) {
    if (e.value > 1) {
      warnings.add('合并键冲突：${e.value} 条课程「${label[e.key]}」在 merge 去重键上'
          '完全相同，导入时仅保留 1 条，请检查教务侧是否存在重复排课');
    }
  }
}

// ---------------------------------------------------------------------------
// TaskActivity 参数
// ---------------------------------------------------------------------------

/// 以 [openParen]（指向 `(`）为起点切分参数：按「引号外、括号深度 0 的逗号」切。
///
/// 截断（括号 / 引号不闭合）时返回 null。
List<String>? _splitArgs(String s, int openParen) {
  if (openParen < 0 || openParen >= s.length || s[openParen] != '(') return null;
  final List<String> args = <String>[];
  final StringBuffer cur = StringBuffer();
  var depth = 1;
  var inQuote = false;
  var i = openParen + 1;
  while (i < s.length) {
    final String c = s[i];
    if (inQuote) {
      if (c == r'\') {
        if (i + 1 >= s.length) return null;
        cur.write(c);
        cur.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == '"') inQuote = false;
      cur.write(c);
      i++;
      continue;
    }
    if (c == '"') {
      inQuote = true;
      cur.write(c);
      i++;
      continue;
    }
    if (c == '(') {
      depth++;
      cur.write(c);
      i++;
      continue;
    }
    if (c == ')') {
      depth--;
      if (depth == 0) {
        args.add(cur.toString());
        return args;
      }
      cur.write(c);
      i++;
      continue;
    }
    if (c == ',' && depth == 1) {
      args.add(cur.toString());
      cur.clear();
      i++;
      continue;
    }
    cur.write(c);
    i++;
  }
  return null;
}

/// 取最后一个括号内的内容（`17808(26271.MK00001A.050)` → `26271.MK00001A.050`）。
String _extractCode(String s) {
  final int open = s.lastIndexOf('(');
  final int close = s.lastIndexOf(')');
  if (open >= 0 && close > open) return s.substring(open + 1, close).trim();
  return s.trim();
}

/// 去掉课程名结尾的 `(<课程代码>)`。课程名自带中文括号（如 `大学英语I（三）`）保留。
String _stripCode(String name, String code) {
  final String trimmed = name.trim();
  if (code.isNotEmpty) {
    final String suffix = '($code)';
    if (trimmed.endsWith(suffix)) {
      return trimmed.substring(0, trimmed.length - suffix.length).trim();
    }
  }
  final RegExpMatch? m = _rgxTrailingParen.firstMatch(trimmed);
  return m == null ? trimmed : trimmed.substring(0, m.start).trim();
}

/// 周次串 → 周次集合。第 0 位（占位）忽略，第 `p` 位为 `'1'` 即第 `p` 周。
List<int> _parseWeeks(String s) {
  final List<int> weeks = <int>[];
  for (var p = 1; p < s.length; p++) {
    if (s.codeUnitAt(p) == 0x31) weeks.add(p);
  }
  return weeks;
}

String _unquote(String raw) {
  final String s = raw.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s
        .substring(1, s.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }
  if (s == 'null') return '';
  return s;
}

// ---------------------------------------------------------------------------
// 教师
// ---------------------------------------------------------------------------

String _resolveTeacher(
    List<String> args, _TeacherList? act, _TeacherList? all) {
  final List<String> names = act?.names ?? const <String>[];
  final String arg9 = args.length > 9 ? args[9].trim() : '';
  String assistant = '';
  if (arg9.startsWith('"')) {
    assistant = _unquote(arg9);
  } else if (arg9 == 'assistantName') {
    assistant = _computeAssistant(act, all);
  }
  if (assistant.isNotEmpty && !names.contains(assistant)) {
    return names.isEmpty ? assistant : '${names.join(',')},$assistant';
  }
  return names.join(',');
}

/// 复刻站点 JS：assistant = `actTeachers` 中「不在 `teachers` 且 `lab==true`」者，
/// 取首个的 `name`（真样本里它已被含在 actTeachers 字面量内，故通常不额外追加）。
String _computeAssistant(_TeacherList? act, _TeacherList? all) {
  if (act == null) return '';
  final List<_Teacher> pool = all?.teachers ?? const <_Teacher>[];
  for (final _Teacher t in act.teachers) {
    if (!t.lab) continue;
    final bool inAll = pool.any((_Teacher s) =>
        s.id == t.id && s.name == t.name && s.lab == t.lab);
    if (!inAll) return t.name;
  }
  return '';
}

List<_TeacherList> _collectTeacherLists(String source, RegExp open) {
  final List<_TeacherList> out = <_TeacherList>[];
  for (final RegExpMatch m in open.allMatches(source)) {
    final int openBracket = m.end - 1; // 正则以 `[` 结尾
    final int close = _matchBracket(source, openBracket, '[', ']');
    if (close < 0) continue;
    out.add(_TeacherList(
      pos: m.start,
      teachers: _parseTeachers(source.substring(openBracket + 1, close)),
    ));
  }
  return out;
}

List<_Teacher> _parseTeachers(String inner) => <_Teacher>[
      for (final RegExpMatch m in _rgxTeacherEntry.allMatches(inner))
        _Teacher(
          id: m.group(1)!,
          name: _unescapeString(m.group(2)!),
          lab: m.group(3) == 'true',
        ),
    ];

_TeacherList? _nearest(List<_TeacherList> lists, int pos) {
  _TeacherList? found;
  for (final _TeacherList l in lists) {
    if (l.pos < pos) {
      found = l;
    } else {
      break;
    }
  }
  return found;
}

String _unescapeString(String s) =>
    s.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');

/// 从 [openIndex]（指向 `open`）找匹配的 [close]，跳过引号内字符。
int _matchBracket(String s, int openIndex, String open, String close) {
  var depth = 0;
  var inQuote = false;
  for (var i = openIndex; i < s.length; i++) {
    final String c = s[i];
    if (inQuote) {
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == '"') inQuote = false;
      continue;
    }
    if (c == '"') {
      inQuote = true;
    } else if (c == open) {
      depth++;
    } else if (c == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

// ---------------------------------------------------------------------------
// 节次合并
// ---------------------------------------------------------------------------

/// 把已排序的节次列表按「连续（差 1）」，合并为 `[start, end]` 段。
List<List<int>> _mergeRuns(List<int> sorted) {
  final List<List<int>> runs = <List<int>>[];
  if (sorted.isEmpty) return runs;
  var start = sorted.first;
  var prev = sorted.first;
  for (var i = 1; i < sorted.length; i++) {
    final int v = sorted[i];
    if (v == prev + 1) {
      prev = v;
    } else {
      runs.add(<int>[start, prev]);
      start = v;
      prev = v;
    }
  }
  runs.add(<int>[start, prev]);
  return runs;
}

// ---------------------------------------------------------------------------
// 正则与内部数据结构
// ---------------------------------------------------------------------------

final RegExp _rgxCourseTable =
    RegExp(r'new\s+CourseTable\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)');
final RegExp _rgxUnitCount = RegExp(r'\bunitCount\s*=\s*(\d+)\s*;');
final RegExp _rgxTaskActivity = RegExp(r'new\s+TaskActivity\s*\(');
final RegExp _rgxActTeachers = RegExp(r'var\s+actTeachers\s*=\s*\[');
final RegExp _rgxTeachers = RegExp(r'var\s+teachers\s*=\s*\[');
final RegExp _rgxIndex =
    RegExp(r'index\s*=\s*(\d+)\s*\*\s*unitCount\s*\+\s*(\d+)\s*;');
final RegExp _rgxTrailingParen = RegExp(r'\([^()]*\)$');
final RegExp _rgxTeacherEntry = RegExp(
    r'id\s*:\s*(\d+)\s*,\s*name\s*:\s*"((?:[^"\\]|\\.)*)"\s*,'
    r'\s*lab\s*:\s*(true|false)');

class _IndexCell {
  const _IndexCell(
      {required this.pos, required this.weekday, required this.period});

  final int pos;
  final int weekday;
  final int period;
}

class _Teacher {
  const _Teacher({required this.id, required this.name, required this.lab});

  final String id;
  final String name;
  final bool lab;
}

class _TeacherList {
  _TeacherList({required this.pos, required this.teachers});

  final int pos;
  final List<_Teacher> teachers;

  List<String> get names => <String>[for (final _Teacher t in teachers) t.name];
}
