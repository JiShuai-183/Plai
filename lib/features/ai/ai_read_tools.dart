import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../data/models/task.dart';
import '../../services/ai/models/ai_tool.dart';
import '../schedule/schedule_providers.dart';
import '../timetable/timetable_providers.dart';
import '../timetable/week_rules.dart';

/// AI 只读工具（S6）：模型经 function-calling 查询本机数据。
///
/// 约束：
/// - 只读——任何工具都不产生写入；写操作是 S7（逐条确认 + 门控）；
/// - 本地执行——查询在设备上完成，仅把查询**结果**随对话发给用户自配的
///   第三方服务，此外不外发任何数据；
/// - 执行入口统一由页面兜底 try-catch（未知工具 / 参数非法 / 读取异常
///   都返回错误 JSON，不打断对话）。
class AiReadTool {
  const AiReadTool({
    required this.name,
    required this.label,
    required this.description,
    Map<String, dynamic>? parameters,
    required this.execute,
  }) : parameters = parameters ?? const <String, dynamic>{};

  /// 函数名（wire 上模型看到的名字）。
  final String name;

  /// 中文标签（UI 小字行展示用）。
  final String label;

  /// 给模型看的能力说明。
  final String description;

  /// 参数 JSON Schema。
  final Map<String, dynamic> parameters;

  /// 本地执行：返回回传给模型的结果文本（JSON 字符串）。
  final Future<String> Function(WidgetRef ref, Map<String, dynamic> args)
  execute;

  /// OpenAI tools[] 数组元素。
  Map<String, dynamic> toSchema() => functionTool(
    name: name,
    description: description,
    parameters: parameters,
  );
}

/// 全部只读工具。
///
/// 只有一条：合并成一个 `query` 工具、用 action 区分查询维度（方案 A）。
/// 理由见 [_queryTool] 的注释——每次模型请求都要重发工具说明书，
/// 工具数量直接决定固定开销。
final List<AiReadTool> aiReadTools = <AiReadTool>[_queryTool];

/// 按名查找只读工具；不是只读工具返回 null。
AiReadTool? findAiReadTool(String name) {
  for (final AiReadTool t in aiReadTools) {
    if (t.name == name) return t;
  }
  return null;
}

// ---------------------------------------------------------------- 工具定义

/// 唯一的只读工具：按 `action` 分派到各查询。
///
/// 合并理由（方案 A）：原来 6 个只读工具各带一份 description + parameters，
/// 每轮模型请求都要重发一遍。合并成一条、用 action 表达差异后，每次请求
/// 携带的 schema 明显变短——而一次提问往往要串行发 2~3 轮，收益每轮都吃。
///
/// `action` 缺省（或 `today`）= 今日概览，覆盖「今天有什么课/什么事」这类
/// 最常见的问题；这也是历史上「某日安排」查询不带 date 时的行为。
final AiReadTool _queryTool = AiReadTool(
  name: 'query',
  label: '查询',
  description:
      '查询用户的本地数据（只读）。用 action 指定查什么：'
      'day=某天的课表与当天到期任务（可传 date=yyyy-MM-dd，缺省今天）；'
      'courses=当前学期全部课程（可传 weekday=1~7 只看那一天）；'
      'tasks=日程任务与每日打卡（可传 filter=today/overdue/uncompleted/daily/all，'
      '缺省 uncompleted）；'
      'periods=节次时间表；semester=当前学期起止与周数；'
      'date=今天日期与第几周。'
      '不传 action 等同 day（今日概览），适合「今天有什么课」这类问题。'
      '凡涉及"今天/明天/周几/第几周"的日期推算，先调本工具。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'today',
          'day',
          'courses',
          'tasks',
          'periods',
          'semester',
          'date',
        ],
        'description': '查什么；不传等同 day',
      },
      'date': <String, dynamic>{
        'type': 'string',
        'description': 'action=day 时的目标日期 yyyy-MM-dd，缺省今天',
      },
      'weekday': <String, dynamic>{
        'type': 'integer',
        'description': 'action=courses 时只看该星期几（1=周一 … 7=周日）',
      },
      'filter': <String, dynamic>{
        'type': 'string',
        'enum': <String>['today', 'overdue', 'uncompleted', 'daily', 'all'],
        'description': 'action=tasks 时的过滤维度，缺省 uncompleted',
      },
    },
  },
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
    switch (_queryActionOf(args)) {
      case 'courses':
        return _queryCourses(ref, args);
      case 'tasks':
        return _queryTasks(ref, args);
      case 'periods':
        return _queryPeriods(ref);
      case 'semester':
        return _querySemester(ref);
      case 'date':
        return _queryDateInfo(ref);
      case 'today':
      case 'day':
      default:
        return _queryDay(ref, args);
    }
  },
);

/// 解析 query 的 action；未知值一律按今日概览处理（只读工具，宽容即可）。
String _queryActionOf(Map<String, dynamic> args) {
  final Object? raw = args['action'];
  if (raw is! String) return 'day';
  final String a = raw.trim().toLowerCase();
  return const <String>{
        'today',
        'day',
        'courses',
        'tasks',
        'periods',
        'semester',
        'date',
      }.contains(a)
      ? a
      : 'day';
}

/// 查日期周次：模型做"今天/明天/周几"推算的基准。
Future<String> _queryDateInfo(WidgetRef ref) async {
  final DateTime now = DateTime.now();
  final Map<String, dynamic> result = <String, dynamic>{
    'date': _fmtDate(now),
    'weekday': _weekdayName(now.weekday),
  };
  try {
    final Semester? s = await ref.read(currentSemesterProvider.future);
    if (s != null) {
      final WeekRules rules = WeekRules(
        semesterStart: s.startDate,
        totalWeeks: s.totalWeeks,
      );
      final bool inSemester =
          !now.isBefore(s.startDate) && !now.isAfter(s.endDate);
      result['semester'] = s.name;
      result['semester_start'] = _fmtDate(s.startDate);
      result['semester_end'] = _fmtDate(s.endDate);
      result['in_semester'] = inSemester;
      if (inSemester) {
        result['current_week'] = rules.clampWeek(rules.weekOfDate(now));
      }
    }
  } catch (_) {
    // 学期数据读不到 → 只回日期部分。
  }
  return jsonEncode(result);
}

/// 查当前学期。
Future<String> _querySemester(WidgetRef ref) async {
  final Semester? s = await ref.read(currentSemesterProvider.future);
  if (s == null) {
    return jsonEncode(<String, dynamic>{'semester': null, 'note': '尚未设置学期'});
  }
  return jsonEncode(<String, dynamic>{
    'name': s.name,
    'start_date': _fmtDate(s.startDate),
    'end_date': _fmtDate(s.endDate),
    'total_weeks': s.totalWeeks,
  });
}

/// 查某日安排（今日/明日/任意一天）：周次与停课过滤后实际生效的课 + 当日任务。
Future<String> _queryDay(WidgetRef ref, Map<String, dynamic> args) async {
  final DateTime now = DateTime.now();
  DateTime day = DateTime(now.year, now.month, now.day);
  final Object? raw = args['date'];
  if (raw is String) {
    final DateTime? parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      day = DateTime(parsed.year, parsed.month, parsed.day);
    }
  }

  final List<TodayCourse> courses = await ref.read(
    dayCoursesProvider(day).future,
  );
  final List<Map<String, dynamic>> courseList = <Map<String, dynamic>>[
    for (final TodayCourse c in courses)
      <String, dynamic>{
        'name': c.course.name,
        'time': _courseTime(c),
        if (c.course.location.trim().isNotEmpty) 'location': c.course.location,
        if (c.course.teacher.trim().isNotEmpty) 'teacher': c.course.teacher,
        'week': c.week,
      },
  ];

  final List<Map<String, dynamic>> taskList = <Map<String, dynamic>>[];
  try {
    final List<Task> tasks = await ref.read(tasksProvider.future);
    for (final Task t in tasks) {
      if (t.completed || t.type == TaskType.daily) continue;
      final DateTime d = t.dueDate;
      final bool sameDay =
          d.year == day.year && d.month == day.month && d.day == day.day;
      if (!sameDay) continue;
      taskList.add(<String, dynamic>{
        'title': t.title,
        if (t.dueTime != null && t.dueTime!.isNotEmpty) 'time': t.dueTime,
        'priority': t.priority.label,
      });
    }
  } catch (_) {
    // 任务读不到 → 只回课程部分。
  }

  return jsonEncode(<String, dynamic>{
    'date': _fmtDate(day),
    'weekday': _weekdayName(day.weekday),
    'courses': courseList,
    'tasks': taskList,
  });
}

/// 查课程表：当前学期排下的全部课程（可按星期几过滤）。
Future<String> _queryCourses(WidgetRef ref, Map<String, dynamic> args) async {
  final Semester? s = await ref.read(currentSemesterProvider.future);
  if (s == null) {
    return jsonEncode(<String, dynamic>{
      'courses': <Map<String, dynamic>>[],
      'note': '尚未设置学期',
    });
  }
  List<Course> courses = await ref.read(coursesProvider.future);
  final Object? wd = args['weekday'];
  if (wd is num && wd.round() >= 1 && wd.round() <= 7) {
    final int w = wd.round();
    courses = courses.where((Course c) => c.weekday == w).toList();
  }
  final Map<int, Period> periodByIndex = <int, Period>{
    for (final Period p in await ref.read(periodsProvider.future)) p.index: p,
  };
  courses.sort((Course a, Course b) {
    final int byDay = a.weekday.compareTo(b.weekday);
    return byDay != 0 ? byDay : a.startPeriod.compareTo(b.startPeriod);
  });
  return jsonEncode(<String, dynamic>{
    'semester': s.name,
    'courses': <Map<String, dynamic>>[
      for (final Course c in courses)
        <String, dynamic>{
          'id': c.id,
          'name': c.name,
          'weekday': _weekdayName(c.weekday),
          'periods': '${c.startPeriod}-${c.endPeriod}节',
          'time': _periodTime(c, periodByIndex),
          if (c.location.trim().isNotEmpty) 'location': c.location,
          if (c.teacher.trim().isNotEmpty) 'teacher': c.teacher,
          'weeks': _weeksDesc(c),
        },
    ],
  });
}

/// 查任务：按过滤维度返回日程任务 / 每日打卡。
Future<String> _queryTasks(WidgetRef ref, Map<String, dynamic> args) async {
  final List<Task> tasks = await ref.read(tasksProvider.future);
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final String filter = args['filter'] is String
      ? args['filter'] as String
      : 'uncompleted';

  Map<int, Set<DateTime>>? dailyDone;
  Future<bool> doneToday(Task t) async {
    if (t.id == null) return false;
    dailyDone ??= await ref.read(dailyDoneMapProvider.future);
    return dailyDone![t.id]!.contains(today);
  }

  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final Task t in tasks) {
    switch (filter) {
      case 'today':
        if (t.completed ||
            t.type == TaskType.daily ||
            !_sameDay(t.dueDate, today)) {
          continue;
        }
      case 'overdue':
        if (t.completed ||
            t.type == TaskType.daily ||
            !t.dueDate.isBefore(today)) {
          continue;
        }
      case 'uncompleted':
        if (t.completed || t.type == TaskType.daily) continue;
      case 'daily':
        if (t.type != TaskType.daily) continue;
      default: // all
        break;
    }
    out.add(<String, dynamic>{
      'id': t.id,
      'title': t.title,
      'type': t.type.label,
      'due': _fmtDate(t.dueDate),
      if (t.dueTime != null && t.dueTime!.isNotEmpty) 'time': t.dueTime,
      'priority': t.priority.label,
      'done': t.completed,
      if (t.type == TaskType.daily) 'done_today': await doneToday(t),
      // 提醒现状：模型改 / 清提醒前必须先知道当前是什么（否则用户说
      // 「把提醒取消掉」它无从判断本来是什么）。一句自然语言，没有就不写键。
      if (_remindOf(t) != null) 'remind': _remindOf(t),
    });
  }
  return jsonEncode(<String, dynamic>{'filter': filter, 'tasks': out});
}

/// 查节次时间表。
Future<String> _queryPeriods(WidgetRef ref) async {
  final List<Period> periods = await ref.read(periodsProvider.future);
  return jsonEncode(<String, dynamic>{
    'periods': <Map<String, dynamic>>[
      for (final Period p in periods)
        <String, dynamic>{
          'index': p.index,
          'start': p.startTime,
          'end': p.endTime,
        },
    ],
  });
}

// ---------------------------------------------------------------- 状态快照

/// 本次发送前**一次性**预取的本地状态摘要，随 system 消息带给模型。
///
/// 目的（方案 B）：绝大多数「今天有什么课」「我有哪些没做完的事」这类
/// 问题，模型本来要额外发一整轮请求去查某日安排 / 任务列表，
/// 每轮都要重发约 5 万字符的工具说明书、再等十几秒。把当天与未完成
/// 的关键事实先摆在它面前，它就能直接回答，把 2~3 次请求压成 1 次。
///
/// 约束：
/// - 只读，不产生任何写入；
/// - 任何一块读失败都只是缺这一块，**绝不抛异常**阻断发送；
/// - 体积有上限（见各 `_snapshotLimit`），避免把上下文撑爆反而变慢；
/// - 内容是「事实快照」而非「指令」：数据改动后模型仍应以工具查询为准，
///   提示词里已写明这一点。
///
/// 返回空串表示一条都没取到（此时不注入，行为与改造前一致）。
Future<String> buildAppStateSnapshot(WidgetRef ref) async {
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final StringBuffer out = StringBuffer();

  // ① 日期 / 学期 / 周次。
  try {
    final Map<String, dynamic> dateInfo =
        jsonDecode(await _queryDateInfo(ref)) as Map<String, dynamic>;
    out.writeln('日期：${dateInfo['date']}（${dateInfo['weekday']}）');
    final Object? semester = dateInfo['semester'];
    if (semester is String && semester.isNotEmpty) {
      out.writeln(
        '学期：$semester ${dateInfo['semester_start']} 至 '
        '${dateInfo['semester_end']}（共 ${dateInfo['total_weeks'] ?? '-'} 周）',
      );
      final Object? week = dateInfo['current_week'];
      out.writeln(week is int ? '当前第 $week 周' : '当前不在学期内');
    } else {
      out.writeln('学期：尚未设置');
    }
  } catch (_) {
    // 日期块读不到 → 跳过（system 里另有 _systemPromptWithNow 兜底）。
  }

  // ② 今天实际生效的课与到期任务。
  try {
    final Map<String, dynamic> day = jsonDecode(
      await _queryDay(ref, <String, dynamic>{'date': _fmtDate(today)}),
    ) as Map<String, dynamic>;
    final List<Object?> courses = day['courses'] as List<Object?>? ?? const [];
    if (courses.isEmpty) {
      out.writeln('今天没有课');
    } else {
      out.writeln('今天的课（已按周次/停课过滤）：');
      int n = 0;
      for (final Object? c in courses) {
        if (n++ >= _snapshotCourseLimit) break;
        if (c is! Map) continue;
        final StringBuffer line = StringBuffer(
          '· ${c['name']} ${c['time'] ?? ''}',
        );
        if (c['location'] != null) line.write(' @${c['location']}');
        if (c['teacher'] != null) line.write('（${c['teacher']}）');
        out.writeln(line);
      }
      if (courses.length > _snapshotCourseLimit) {
        out.writeln('…今天还有 ${courses.length - _snapshotCourseLimit} 门课未列出');
      }
    }
    final List<Object?> dayTasks = day['tasks'] as List<Object?>? ?? const [];
    if (dayTasks.isNotEmpty) {
      out.writeln('今天到期且未完成：');
      int n = 0;
      for (final Object? t in dayTasks) {
        if (n++ >= _snapshotTaskLimit) break;
        if (t is! Map) continue;
        out.writeln(
          '· ${t['title']}${t['time'] != null ? ' ${t['time']}' : ''}'
          '（${t['priority']}）',
        );
      }
    }
  } catch (_) {
    // 当日课表读不到 → 跳过。
  }

  // ③ 未完成的日程（含 id，模型改/删时不必再查一遍）。
  try {
    final Map<String, dynamic> un = jsonDecode(
      await _queryTasks(ref, <String, dynamic>{'filter': 'uncompleted'}),
    ) as Map<String, dynamic>;
    final List<Object?> tasks = un['tasks'] as List<Object?>? ?? const [];
    if (tasks.isEmpty) {
      out.writeln('没有未完成的日程');
    } else {
      final int shown = tasks.length > _snapshotTaskLimit
          ? _snapshotTaskLimit
          : tasks.length;
      out.writeln('未完成的日程（全部，不限时间；共 ${tasks.length} 条，列前 $shown 条）：');
      // 2026-11-02 真机：用户问「我这个月还有什么没做完的」，模型看到这段
      // 「未完成的日程」就当成已经答完，直接回了两个字「这个」。列表只给
      // 全部未完成项，**不含任何时间范围过滤**，必须把这点说清楚，否则
      // 模型会拿它冒充「本月」「本周」这类带范围的答案。
      for (int i = 0; i < shown; i++) {
        final Object? t = tasks[i];
        if (t is! Map) continue;
        final StringBuffer line = StringBuffer(
          '· #${t['id']} ${t['title']} ${t['due'] ?? ''}',
        );
        if (t['time'] != null) line.write(' ${t['time']}');
        if (t['remind'] != null) line.write('，提醒：${t['remind']}');
        out.writeln(line);
      }
    }
  } catch (_) {
    // 任务读不到 → 跳过。
  }

  final String text = out.toString().trim();
  return text.isEmpty ? '' : text;
}

/// 快照里今天课程的最多条数。
const int _snapshotCourseLimit = 12;

/// 快照里任务列表的最多条数（当日任务与未完成日程各自适用）。
const int _snapshotTaskLimit = 15;

// ---------------------------------------------------------------- 辅助

String _fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _weekdayName(int weekday) =>
    const <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1];

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 任务的提醒现状（给模型看的自然语言）；没有任何提醒返回 null。
///
/// 与详情页 / 确认卡片 `_describeTaskReminder` 同口径：一次性优先，其次
/// 每日，最后旧版 offset。输出 `每天 08:00` / `2099-01-02 14:30 提醒一次` /
/// `提前 30 分钟`。
String? _remindOf(Task t) {
  if (t.reminderRepeat == ReminderRepeat.once) {
    final DateTime? at = t.remindOnceAt;
    if (at == null) return null;
    return '${_fmtDate(at)} ${_hhmm(at.hour, at.minute)} 提醒一次';
  }
  final String? daily = t.dailyRemindTime;
  if (daily != null && daily.isNotEmpty) return '每天 $daily';
  final int? offset = t.remindOffsetMin;
  if (offset == null) return null;
  return offset == -1 ? '准时提醒' : '提前 $offset 分钟';
}

String _hhmm(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

String? _timeStr(TimeOfDay? t) => t == null
    ? null
    : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 某日课程的展示时间段：有节次表用时刻，否则退回节次序号。
String? _courseTime(TodayCourse c) {
  final String? start = _timeStr(c.startTime);
  final String? end = _timeStr(c.endTime);
  if (start != null && end != null) return '$start–$end';
  return '${c.course.startPeriod}-${c.course.endPeriod}节';
}

/// 课程起始节次的开始时刻 → 结束节次的结束时刻（节次表缺失返回 null）。
String? _periodTime(Course c, Map<int, Period> periodByIndex) {
  final Period? start = periodByIndex[c.startPeriod];
  final Period? end = periodByIndex[c.endPeriod];
  if (start == null || end == null) return null;
  return '${start.startTime}–${end.endTime}';
}

/// 周次描述：范围 + 单双周/自定义说明。
String _weeksDesc(Course c) {
  final String base = c.startWeek == c.endWeek
      ? '第${c.startWeek}周'
      : '第${c.startWeek}-${c.endWeek}周';
  switch (c.weekType) {
    case WeekType.every:
      return base;
    case WeekType.odd:
      return '$base（单周）';
    case WeekType.even:
      return '$base（双周）';
    case WeekType.custom:
      if (c.weekList.isEmpty) return base;
      return '$base（第${c.weekList.join(',')}周）';
  }
}
