import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/course.dart';
import '../../data/models/period.dart';
import '../../data/models/semester.dart';
import '../../data/models/task.dart';
import '../../services/ai/models/ai_tool.dart';
import '../schedule/schedule_providers.dart';
import '../timetable/timetable_providers.dart' hide settingsRepositoryProvider;
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

/// 全部只读工具（顺序即发给模型的顺序）。
final List<AiReadTool> aiReadTools = <AiReadTool>[
  _dateInfoTool,
  _currentSemesterTool,
  _dayScheduleTool,
  _coursesTool,
  _tasksTool,
  _periodsTool,
];

/// 工具英文名 → 中文标签（未知名回退原名）。
String aiToolLabel(String name) {
  for (final AiReadTool t in aiReadTools) {
    if (t.name == name) return t.label;
  }
  return name;
}

/// 按名查找只读工具；不是只读工具返回 null。
AiReadTool? findAiReadTool(String name) {
  for (final AiReadTool t in aiReadTools) {
    if (t.name == name) return t;
  }
  return null;
}

// ---------------------------------------------------------------- 工具定义

/// 查日期周次：模型做"今天/明天/周几"推算的基准。
final AiReadTool _dateInfoTool = AiReadTool(
  name: 'get_date_info',
  label: '日期周次',
  description:
      '查询今天的日期、星期几，以及当前学期与处于第几周。'
      '凡涉及"今天/明天/周几/第几周"的日期推算，应先调用本工具。',
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
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
  },
);

/// 查当前学期。
final AiReadTool _currentSemesterTool = AiReadTool(
  name: 'get_current_semester',
  label: '当前学期',
  description: '查询当前学期的名称、开学/结束日期与总周数。',
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
    final Semester? s = await ref.read(currentSemesterProvider.future);
    if (s == null) {
      return jsonEncode(<String, dynamic>{
        'semester': null,
        'note': '尚未设置学期',
      });
    }
    return jsonEncode(<String, dynamic>{
      'name': s.name,
      'start_date': _fmtDate(s.startDate),
      'end_date': _fmtDate(s.endDate),
      'total_weeks': s.totalWeeks,
    });
  },
);

/// 查某日安排（今日/明日/任意一天）：周次与停课过滤后实际生效的课 + 当日任务。
final AiReadTool _dayScheduleTool = AiReadTool(
  name: 'get_day_schedule',
  label: '某日安排',
  description:
      '查询某一天实际生效的课程（已按周次与停课过滤，含上课时间/教室/教师）'
      '与当天到期的未完成任务。date 传 yyyy-MM-dd；查"今天"可省略 date。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'date': <String, dynamic>{
        'type': 'string',
        'description': '目标日期，格式 yyyy-MM-dd，缺省为今天',
      },
    },
  },
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
    final DateTime now = DateTime.now();
    DateTime day = DateTime(now.year, now.month, now.day);
    final Object? raw = args['date'];
    if (raw is String) {
      final DateTime? parsed = DateTime.tryParse(raw);
      if (parsed != null) {
        day = DateTime(parsed.year, parsed.month, parsed.day);
      }
    }

    final List<TodayCourse> courses =
        await ref.read(dayCoursesProvider(day).future);
    final List<Map<String, dynamic>> courseList = <Map<String, dynamic>>[
      for (final TodayCourse c in courses)
        <String, dynamic>{
          'name': c.course.name,
          'time': _courseTime(c),
          if (c.course.location.trim().isNotEmpty)
            'location': c.course.location,
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
        final bool sameDay = d.year == day.year &&
            d.month == day.month &&
            d.day == day.day;
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
  },
);

/// 查课程表：当前学期排下的全部课程（可按星期几过滤）。
final AiReadTool _coursesTool = AiReadTool(
  name: 'get_courses',
  label: '课程表',
  description:
      '查询当前学期排下的全部课程（不按具体某天过滤，周次/单双周规则一并返回）。'
      '可传 weekday（1=周一 … 7=周日）只看每周那一天。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'weekday': <String, dynamic>{
        'type': 'integer',
        'description': '1=周一 … 7=周日，可选',
      },
    },
  },
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
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
      for (final Period p in await ref.read(periodsProvider.future))
        p.index: p,
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
  },
);

/// 查任务：按过滤维度返回日程任务 / 每日打卡。
final AiReadTool _tasksTool = AiReadTool(
  name: 'get_tasks',
  label: '任务',
  description:
      '查询用户的日程任务与每日打卡。filter 取值：'
      'today=今天到期未完成 / overdue=已逾期未完成 / uncompleted=全部未完成 / '
      'daily=每日打卡任务（含今天是否已打卡）/ all=全部。缺省 uncompleted。',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'filter': <String, dynamic>{
        'type': 'string',
        'enum': <String>['today', 'overdue', 'uncompleted', 'daily', 'all'],
      },
    },
  },
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
    final List<Task> tasks = await ref.read(tasksProvider.future);
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final String filter =
        args['filter'] is String ? args['filter'] as String : 'uncompleted';

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
      });
    }
    return jsonEncode(<String, dynamic>{'filter': filter, 'tasks': out});
  },
);

/// 查节次时间表。
final AiReadTool _periodsTool = AiReadTool(
  name: 'get_periods',
  label: '节次时间',
  description: '查询节次时间表（第几节课对应几点到几点）。',
  execute: (WidgetRef ref, Map<String, dynamic> args) async {
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
  },
);

// ---------------------------------------------------------------- 辅助

String _fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _weekdayName(int weekday) =>
    const <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1];

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

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
