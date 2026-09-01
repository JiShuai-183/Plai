import '../../data/models/course.dart';
import '../../data/models/period.dart';

/// 教务 HTML 课表解析结果。
class AcademicTimetableData {
  const AcademicTimetableData({
    required this.semesterName,
    required this.courses,
    required this.periods,
  });

  /// 学期名（如「2026-2027学年第一学期」），找不到为空。
  final String semesterName;

  /// 课程列表（color 统一置 `''`，导入时再套默认课程颜色）。
  final List<Course> courses;

  /// 作息表节次。
  final List<Period> periods;
}

/// 解析教务网页导出的 HTML 课表。解析失败（找不到主课表、周次非法等）抛
/// [FormatException]，整体失败。
AcademicTimetableData parseAcademicTimetableHtml(String html) {
  final String semesterName = _extractSemesterName(html);
  final String mainTable = _extractMainTable(html);
  final List<Course> courses = _parseCoursesFromTable(mainTable);
  final List<Period> periods = _parsePeriods(html);
  return AcademicTimetableData(
    semesterName: semesterName,
    courses: courses,
    periods: periods,
  );
}

// ---------------------------------------------------------------------------
// 主课表定位 / 学期名
// ---------------------------------------------------------------------------

/// 定位 `id="manualArrangeCourseTable"` 主课表，返回其内部 HTML。
String _extractMainTable(String html) {
  final RegExp start = RegExp(
      r'<table[^>]*id=[\x22\x27]manualArrangeCourseTable[\x22\x27][^>]*>',
      caseSensitive: false);
  final RegExpMatch? match = start.firstMatch(html);
  if (match == null) {
    throw FormatException('未找到主课表（manualArrangeCourseTable）');
  }
  // 主课表结束：取其后第一处 `<table`（教务模板常把主课表闭合标签误写为
  // `<table>`），否则回退找 `</table>`。
  final int nextTable = html.indexOf(
      RegExp(r'<table\b', caseSensitive: false), match.end);
  final int close =
      nextTable >= 0 ? nextTable : html.indexOf('</table>', match.end);
  if (close < match.end) {
    throw FormatException('主课表缺少结束标签');
  }
  return html.substring(match.end, close);
}

/// 取含「学年」或「学期」的第一个单元格文本作为学期名，找不到返回空串。
String _extractSemesterName(String html) {
  final RegExp cell = RegExp(r'<td\b[^>]*>(.*?)</td>', dotAll: true);
  for (final RegExpMatch m in cell.allMatches(html)) {
    final String text =
        _stripTags(m.group(1)!).replaceAll('&nbsp;', ' ').trim();
    if (text.contains('学年') || text.contains('学期')) return text;
  }
  return '';
}

// ---------------------------------------------------------------------------
// 主课表行 / rowspan 解析
// ---------------------------------------------------------------------------

List<Course> _parseCoursesFromTable(String mainTable) {
  final List<Course> courses = <Course>[];
  final RegExp rowRe = RegExp(r'<tr\b[^>]*>(.*?)</tr>', dotAll: true);
  final RegExp cellRe =
      RegExp(r'<t[dh]\b([^>]*)>(.*?)</t[dh]>', dotAll: true);

  // 列（1..7 = 星期一..星期日）剩余被占用的行数（含当前行）。
  final List<int> remaining = List<int>.filled(8, 0);

  for (final RegExpMatch rowMatch in rowRe.allMatches(mainTable)) {
    final String rowInner = rowMatch.group(1)!;
    // 表头行（含 <th>）跳过。
    if (rowInner.contains('<th')) continue;

    final List<({String attrs, String inner})> cells = [];
    for (final RegExpMatch cm in cellRe.allMatches(rowInner)) {
      cells.add((attrs: cm.group(1)!, inner: cm.group(2)!));
    }
    if (cells.isEmpty) continue;

    // 第 0 列 = 节次号。
    final int? periodNumber = _extractPeriodNumber(_cellText(cells.first.inner));
    if (periodNumber == null) {
      throw FormatException('课表数据行缺少节次号（第${cells.first.inner}）');
    }
    final int period = periodNumber;

    var col = 1;
    for (var i = 1; i < cells.length; i++) {
      // 该列被上行 rowspan 占用 → HTML 省略其单元格，直接推进。
      while (col <= 7 && remaining[col] > 0) {
        col++;
      }
      if (col > 7) break;

      final int rowSpan = _rowSpanOf(cells[i].attrs);
      final int startPeriod = period;
      final int endPeriod = period + rowSpan - 1;
      if (_cellLines(cells[i].inner).isNotEmpty) {
        courses.addAll(_parseCellCourses(
          weekday: col,
          startPeriod: startPeriod,
          endPeriod: endPeriod,
          cellInner: cells[i].inner,
        ));
      }
      remaining[col] = rowSpan;
      col++;
    }

    // 行末：把各行剩余占用数递减（当前行已消费一格）。
    for (var c = 1; c <= 7; c++) {
      if (remaining[c] > 0) remaining[c]--;
    }
  }
  return courses;
}

/// 从单元格属性解析 rowspan，无则 1。
int _rowSpanOf(String attrs) {
  final RegExpMatch? m = RegExp(
          r'rowspan\s*=\s*[\x22\x27]?(\d+)[\x22\x27]?',
          caseSensitive: false)
      .firstMatch(attrs);
  return m == null ? 1 : int.parse(m.group(1)!);
}

/// 单元格去标签后的纯文本（`<br>` 替换为换行）。
String _cellText(String inner) {
  final String noBr = inner.replaceAll(RegExp(r'<br\b[^>]*>'), '\n');
  return _stripTags(noBr).replaceAll('&nbsp;', ' ');
}

/// 按 `<br>` 拆块并逐行 trim，返回非空行序列。
List<String> _cellLines(String inner) {
  final List<String> lines = <String>[];
  for (final String chunk in inner.split(RegExp(r'<br\b[^>]*>'))) {
    final String text = _stripTags(chunk).replaceAll('&nbsp;', ' ');
    for (final String line in text.split('\n')) {
      final String t = line.trim();
      if (t.isNotEmpty) lines.add(t);
    }
  }
  return lines;
}

String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '');

// ---------------------------------------------------------------------------
// 课程块拆分与字段
// ---------------------------------------------------------------------------

/// 单个课程 td 的文本块（一行一类）。
class _CourseBlock {
  String? name;
  String? teacher;
  String? weekRaw;
}

List<Course> _parseCellCourses({
  required int weekday,
  required int startPeriod,
  required int endPeriod,
  required String cellInner,
}) {
  final List<_CourseBlock> blocks = _buildBlocks(cellInner);
  final List<Course> courses = <Course>[];
  for (final _CourseBlock b in blocks) {
    final String name = b.name ?? '';
    if (name.isEmpty) {
      throw FormatException('课程块缺少课程名（星期$weekday 第$startPeriod-$endPeriod节）');
    }
    final String weekRaw = b.weekRaw?.trim() ?? '';
    if (weekRaw.isEmpty) {
      throw FormatException('课程 "$name" 缺少周次信息');
    }
    final _WeekInfo weeks = _parseWeeks(weekRaw);
    courses.add(Course(
      semesterId: 0,
      name: name,
      teacher: b.teacher ?? '',
      location: weeks.location,
      color: '',
      weekType: weeks.weekType,
      weekList: weeks.weekList,
      startWeek: weeks.startWeek,
      endWeek: weeks.endWeek,
      weekday: weekday,
      startPeriod: startPeriod,
      endPeriod: endPeriod,
    ));
  }
  return courses;
}

List<_CourseBlock> _buildBlocks(String cellInner) {
  final List<_CourseBlock> blocks = <_CourseBlock>[];
  _CourseBlock? current;
  for (final String line in _cellLines(cellInner)) {
    if (_isTeacherLine(line)) {
      current ??= _CourseBlock();
      current.teacher ??= _innerParens(line).trim();
    } else if (_isWeekLine(line)) {
      current ??= _CourseBlock();
      current.weekRaw ??= _innerParens(line).trim();
    } else {
      // 课程名行：新块。
      if (current != null && current.name != null) {
        blocks.add(current);
        current = _CourseBlock();
      }
      current ??= _CourseBlock();
      current.name = _extractCourseName(line);
    }
  }
  if (current != null && current.name != null) blocks.add(current);
  return blocks;
}

/// 课程名行：去掉末尾 ` (代码)` 括号部分。
String _extractCourseName(String line) =>
    line.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();

/// 以半角圆括号包裹的整行。
bool _hasOuterParens(String line) {
  final String t = line.trim();
  return t.startsWith('(') && t.endsWith(')');
}

/// 取首尾圆括号之间的内容。
String _innerParens(String line) =>
    line.substring(line.indexOf('(') + 1, line.lastIndexOf(')'));

/// 教师行：括号内仅中文/逗号等姓名，无数字、无周次字、无教室。
bool _isTeacherLine(String line) {
  if (!_hasOuterParens(line)) return false;
  final String inner = _innerParens(line);
  if (inner.isEmpty) return false;
  if (RegExp(r'\d|[单双]').hasMatch(inner)) return false;
  return RegExp(r'^[一-龥，,、\s]+$').hasMatch(inner);
}

/// 周次/教室行：括号内含数字或单双标记。
bool _isWeekLine(String line) {
  if (!_hasOuterParens(line)) return false;
  return RegExp(r'\d|[单双]').hasMatch(_innerParens(line));
}

// ---------------------------------------------------------------------------
// 周次解析
// ---------------------------------------------------------------------------

class _WeekInfo {
  const _WeekInfo({
    required this.weekType,
    required this.startWeek,
    required this.endWeek,
    required this.weekList,
    required this.location,
  });

  final WeekType weekType;
  final int startWeek;
  final int endWeek;
  final List<int> weekList;
  final String location;
}

/// 解析周次/教室行（已剥外层括号）为 [Course] 周次字段。
///
/// 例：`4-7`、`1-3,8-16  07C105(龙子湖校区)`、`2,8-12双  05B102(...)`、
/// `7  08A202(硬度实验室)(龙子湖校区)`。
_WeekInfo _parseWeeks(String weekInner) {
  final String trimmed = weekInner.trim();
  final List<String> parts = trimmed.split(RegExp(r'\s+'));
  final String weekSeg = parts.first.trim();
  if (weekSeg.isEmpty) {
    throw FormatException('周次段为空: "$weekInner"');
  }
  final String location = _cleanLocation(parts.skip(1).join(' '));

  final List<int> list = _expandWeeks(weekSeg);
  final int min = list.first;
  final int max = list.last;
  final bool hasMarker = RegExp(r'[单双]$').hasMatch(weekSeg);
  final bool singleRange = RegExp(r'^\d+-\d+[单双]?$').hasMatch(weekSeg);

  if (singleRange) {
    final WeekType type =
        hasMarker ? (weekSeg.endsWith('单') ? WeekType.odd : WeekType.even) : WeekType.every;
    return _WeekInfo(
      weekType: type,
      startWeek: min,
      endWeek: max,
      weekList: const [],
      location: location,
    );
  }
  return _WeekInfo(
    weekType: WeekType.custom,
    startWeek: min,
    endWeek: max,
    weekList: list,
    location: location,
  );
}

/// 展开周次段为升序去重的周次集合。末尾 `单`/`双` 作用于整段；非末段也支持
/// 段级 `单`/`双`（如 `1-3单,9-15单,16-18`）。无任何合法周次抛 [FormatException]。
List<int> _expandWeeks(String seg) {
  final List<String> parts =
      seg.split(',').map((e) => e.trim()).toList();
  if (parts.isEmpty || parts.any((p) => p.isEmpty)) {
    throw FormatException('周次段格式非法: "$seg"');
  }

  // 整段标记：取末段末尾的单/双。
  WeekType wholeParity = WeekType.every;
  final String last = parts.last;
  if (last.endsWith('单') || last.endsWith('双')) {
    wholeParity = last.endsWith('单') ? WeekType.odd : WeekType.even;
    parts[parts.length - 1] = last.substring(0, last.length - 1).trim();
  }

  final List<int> expanded = <int>[];
  for (var i = 0; i < parts.length; i++) {
    String part = parts[i];
    WeekType partParity = WeekType.every;
    if (i != parts.length - 1 &&
        (part.endsWith('单') || part.endsWith('双'))) {
      partParity = part.endsWith('单') ? WeekType.odd : WeekType.even;
      part = part.substring(0, part.length - 1).trim();
    }
    if (part.isEmpty) {
      throw FormatException('周次段格式非法: "$seg"');
    }
    final List<int> nums = _parseWeekPart(part);
    final WeekType filter =
        wholeParity != WeekType.every ? wholeParity : partParity;
    for (final int w in nums) {
      if (filter == WeekType.every ||
          (filter == WeekType.odd ? w.isOdd : w.isEven)) {
        expanded.add(w);
      }
    }
  }

  if (expanded.isEmpty) {
    throw FormatException('周次无有效数值: "$seg"');
  }
  final List<int> list = expanded.toSet().toList()..sort();
  return list;
}

/// 单段 `a-b` 范围或 `a` 单点。
List<int> _parseWeekPart(String part) {
  final int? point = int.tryParse(part);
  if (point != null) {
    if (point < 1) throw FormatException('周次必须为正整数: "$part"');
    return <int>[point];
  }
  final RegExpMatch? m = RegExp(r'^(\d+)-(\d+)$').firstMatch(part);
  if (m == null) throw FormatException('周次段格式非法: "$part"');
  final int a = int.parse(m.group(1)!);
  final int b = int.parse(m.group(2)!);
  if (a < 1 || b < 1 || a > b) {
    throw FormatException('周次范围非法: "$part"');
  }
  return List<int>.generate(b - a + 1, (i) => a + i);
}

/// 去掉教室末尾的 `(…校区)` 多层后缀，保留内部括号如 `08A202(硬度实验室)`。
String _cleanLocation(String raw) {
  String loc = raw.trim();
  while (true) {
    final RegExpMatch? m =
        RegExp(r'\([^()]*校区\)$').firstMatch(loc);
    if (m == null) break;
    loc = loc.substring(0, m.start).trim();
  }
  return loc;
}

// ---------------------------------------------------------------------------
// 节次号 / 作息表
// ---------------------------------------------------------------------------

/// 从「第X节」提取节次号（支持 一…十 及 十一 等），失败返回 null。
int? _extractPeriodNumber(String text) {
  final RegExpMatch? m =
      RegExp(r'第([一二三四五六七八九十]+)节').firstMatch(text);
  if (m == null) return null;
  return _chineseToInt(m.group(1)!);
}

/// 解析「各校区作息时间说明」附近第一个校区的节次（10 节）。找不到则空列表。
List<Period> _parsePeriods(String html) {
  final int marker = html.indexOf('各校区作息时间说明');
  if (marker < 0) return const <Period>[];
  final String section = html.substring(marker);
  final RegExp re = RegExp(
      r'第([一二三四五六七八九十]+)节\s*(\d{1,2}:\d{2})\s*~\s*(\d{1,2}:\d{2})');
  final Map<int, Period> byIndex = <int, Period>{};
  for (final RegExpMatch m in re.allMatches(section)) {
    final int index = _chineseToInt(m.group(1)!);
    final String start = _padTime(m.group(2)!);
    final String end = _padTime(m.group(3)!);
    byIndex.putIfAbsent(
      index,
      () => Period(index: index, startTime: start, endTime: end),
    );
  }
  final List<int> keys = byIndex.keys.toList()..sort();
  return keys.map((k) => byIndex[k]!).toList();
}

/// 中文数字（一…十，及 十一、二十 等）→ 整数。
int _chineseToInt(String s) {
  const Map<String, int> digits = <String, int>{
    '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  if (s == '十') return 10;
  if (s.contains('十')) {
    final List<String> parts = s.split('十');
    final int tens = parts[0].isEmpty ? 1 : digits[parts[0]] ?? 0;
    final int ones =
        parts.length > 1 && parts[1].isNotEmpty ? digits[parts[1]] ?? 0 : 0;
    return tens * 10 + ones;
  }
  return digits[s] ?? 0;
}

/// `H:mm` / `HH:mm` → 补零 `HH:mm`。
String _padTime(String t) {
  final List<String> parts = t.split(':');
  return '${parts[0].padLeft(2, '0')}:${parts[1].padLeft(2, '0')}';
}
