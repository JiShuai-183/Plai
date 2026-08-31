import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/course.dart';
import '../models/date_utils.dart';
import '../models/period.dart';
import '../models/semester.dart';
import '../repositories/timetable_repository.dart';

/// 课表导入策略（PRD-课表模块 §2.6）。
enum ImportStrategy {
  /// 覆盖：先清空目标学期课程，再用导入数据替换；节次整体替换。
  overwrite,

  /// 合并：新增缺失的课程/节次，已存在的不覆盖。
  merge,
}

/// 单条导入校验错误。
class TimetableImportError {
  TimetableImportError(this.message, {this.row});

  /// 提示信息。
  final String message;

  /// 行号：CSV 为文件行号（从 1 计，含表头行）；JSON 为数组条目序号（从 1 计）。
  /// null 表示整体结构错误。
  final int? row;

  @override
  String toString() => row == null ? message : '第 $row 行：$message';
}

/// 导入失败时抛出。校验失败即整体失败，不做任何部分写入。
class TimetableImportException implements Exception {
  TimetableImportException(this.errors);

  final List<TimetableImportError> errors;

  @override
  String toString() {
    final lines = errors.map((e) => '  - $e').join('\n');
    return '课表导入失败（整体未写入）：\n$lines';
  }
}

/// 导入结果摘要。
class TimetableImportResult {
  const TimetableImportResult({
    required this.semesterId,
    required this.periodsImported,
    required this.coursesImported,
  });

  /// 数据实际写入的学期 id（新建学期时为新建的 id）。
  final int semesterId;

  final int periodsImported;
  final int coursesImported;
}

/// 课表导入导出工具。
///
/// - JSON 结构：`{ "semester": {...}, "periods": [...], "courses": [...] }`
/// - CSV 列（PRD-设置与数据 §2）：
///   `课程名,教师,地点,星期,开始节次,结束节次,周次类型,开始周,结束周,自定义周序列,颜色`
///   必填列：课程名 / 星期 / 开始节次 / 结束节次 / 周次类型 / 开始周 / 结束周。
/// - 周次类型接受 `every/odd/even/custom` 或中文 `每周/单周/双周/自定义`；
///   自定义周序列接受 `1,3,5` 或 `[1,3,5]`。
/// - 严格校验：任一错误即整体失败，不部分写入。
class TimetableImportExport {
  TimetableImportExport({required this.db, required this.timetable});

  final AppDatabase db;
  final ITimetableRepository timetable;

  // ---- 导出 ----

  /// 导出某学期为 JSON 字符串（含学期、节次、课程）。
  Future<String> exportJson(int semesterId) async {
    final semester = await timetable.getSemesterById(semesterId);
    if (semester == null) throw StateError('学期不存在: $semesterId');
    final periods = await timetable.getPeriods();
    final courses = await timetable.getCourses(semesterId);
    final json = <String, Object?>{
      'semester': semester.toJson(),
      'periods': periods.map((e) => e.toJson()).toList(),
      'courses': courses.map((e) => e.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// 导出某学期为 CSV 字符串。
  Future<String> exportCsv(int semesterId) async {
    final courses = await timetable.getCourses(semesterId);
    final buffer = StringBuffer();
    buffer.write('课程名,教师,地点,星期,开始节次,结束节次,周次类型,开始周,结束周,自定义周序列,颜色\n');
    for (final c in courses) {
      final row = <String>[
        c.name,
        c.teacher,
        c.location,
        '${c.weekday}',
        '${c.startPeriod}',
        '${c.endPeriod}',
        c.weekType.code,
        '${c.startWeek}',
        '${c.endWeek}',
        c.weekList.join(','),
        c.color,
      ];
      buffer.write(row.map(_csvField).join(','));
      buffer.write('\n');
    }
    return buffer.toString();
  }

  /// 导出 JSON 到文件。
  Future<void> exportJsonToFile(int semesterId, String path) async {
    final content = await exportJson(semesterId);
    await File(path).writeAsString(content, encoding: utf8);
  }

  /// 导出 CSV 到文件。
  Future<void> exportCsvToFile(int semesterId, String path) async {
    final content = await exportCsv(semesterId);
    await File(path).writeAsString(content, encoding: utf8);
  }

  // ---- 导入 ----

  /// 从 JSON 导入课表。
  ///
  /// [targetSemesterId] 为 null 时按文件内 `semester` 新建学期；否则写入指定学期
  /// （此时文件内 semester 仅做结构校验，不更新现有学期信息）。
  Future<TimetableImportResult> importJson(
    String content, {
    int? targetSemesterId,
    required ImportStrategy strategy,
  }) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw TimetableImportException([TimetableImportError('JSON 解析失败')]);
    }
    if (decoded is! Map) {
      throw TimetableImportException([TimetableImportError('JSON 根节点应为对象')]);
    }
    final root = decoded.cast<String, dynamic>();
    final errors = <TimetableImportError>[];

    final semester = _parseSemester(root['semester'], errors);
    final periods = _parsePeriods(root['periods'], errors);
    final courses = _parseCourses(root['courses'], errors);

    if (errors.isNotEmpty) throw TimetableImportException(errors);

    return _apply(
      semesterId: targetSemesterId ?? -1,
      newSemester: targetSemesterId == null ? semester! : null,
      periods: periods,
      courses: courses,
      strategy: strategy,
      includePeriods: true,
    );
  }

  /// 从 CSV 导入课表（CSV 不含节次时间，导入不改变节次表）。
  Future<TimetableImportResult> importCsv(
    String content, {
    required int semesterId,
    required ImportStrategy strategy,
  }) async {
    var text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.startsWith('﻿')) text = text.substring(1);
    final lines = text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (lines.isEmpty) {
      throw TimetableImportException([TimetableImportError('CSV 内容为空')]);
    }

    final headers = _parseCsvLine(lines.first).map((e) => e.trim()).toList();
    final colIndex = <String, int>{};
    for (var i = 0; i < headers.length; i++) {
      colIndex[headers[i]] = i;
    }

    const requiredHeaders = <String>[
      '课程名', '星期', '开始节次', '结束节次', '周次类型', '开始周', '结束周',
    ];
    final missing = requiredHeaders.where((h) => !colIndex.containsKey(h)).toList();
    if (missing.isNotEmpty) {
      throw TimetableImportException(
        missing.map((h) => TimetableImportError('缺少必填列: $h')).toList(),
      );
    }

    final errors = <TimetableImportError>[];
    final courses = <Course>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final row = i + 1; // 文件行号（含表头行）。
      final cells = _parseCsvLine(lines[i]);
      if (cells.length != headers.length) {
        errors.add(TimetableImportError('列数与表头不一致', row: row));
        continue;
      }
      String cell(String header) => cells[colIndex[header]!].trim();
      final m = <String, Object?>{
        'name': cell('课程名'),
        'weekType': cell('周次类型'),
        'startWeek': cell('开始周'),
        'endWeek': cell('结束周'),
        'weekday': cell('星期'),
        'startPeriod': cell('开始节次'),
        'endPeriod': cell('结束节次'),
        if (colIndex.containsKey('自定义周序列')) 'weekList': cell('自定义周序列'),
        if (colIndex.containsKey('教师')) 'teacher': cell('教师'),
        if (colIndex.containsKey('地点')) 'location': cell('地点'),
        if (colIndex.containsKey('颜色')) 'color': cell('颜色'),
      };
      final course = _parseCourse(m, row, errors);
      if (course != null) courses.add(course);
    }

    if (errors.isNotEmpty) throw TimetableImportException(errors);

    return _apply(
      semesterId: semesterId,
      newSemester: null,
      periods: const [],
      courses: courses,
      strategy: strategy,
      includePeriods: false,
    );
  }

  /// 从 JSON 文件导入。
  Future<TimetableImportResult> importJsonFromFile(
    String path, {
    int? targetSemesterId,
    required ImportStrategy strategy,
  }) async {
    final content = await File(path).readAsString(encoding: utf8);
    return importJson(content, targetSemesterId: targetSemesterId, strategy: strategy);
  }

  /// 从 CSV 文件导入。
  Future<TimetableImportResult> importCsvFromFile(
    String path, {
    required int semesterId,
    required ImportStrategy strategy,
  }) async {
    final content = await File(path).readAsString(encoding: utf8);
    return importCsv(content, semesterId: semesterId, strategy: strategy);
  }

  // ---- 校验 ----

  Semester? _parseSemester(dynamic raw, List<TimetableImportError> errors) {
    final before = errors.length;
    if (raw is! Map) {
      errors.add(TimetableImportError('缺少 "semester" 学期信息'));
      return null;
    }
    final m = raw.cast<String, Object?>();
    final name = (m['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) errors.add(TimetableImportError('学期名称不能为空'));
    final startDateStr = (m['startDate'] as String?)?.trim() ?? '';
    DateTime? startDate;
    try {
      startDate = stringToDateOnly(startDateStr);
    } on FormatException {
      errors.add(TimetableImportError('开学日期格式应为 yyyy-MM-dd: "$startDateStr"'));
    }
    final totalWeeks = _asInt(m['totalWeeks']);
    if (totalWeeks == null || totalWeeks < 1) {
      errors.add(TimetableImportError('总周数必须为正整数'));
    }
    if (errors.length != before) return null;
    return Semester(name: name, startDate: startDate!, totalWeeks: totalWeeks!);
  }

  List<Period> _parsePeriods(dynamic raw, List<TimetableImportError> errors) {
    final periods = <Period>[];
    if (raw == null) return periods;
    if (raw is! List) {
      errors.add(TimetableImportError('"periods" 应为数组'));
      return periods;
    }
    final seenIndex = <int>{};
    for (var i = 0; i < raw.length; i++) {
      final row = i + 1;
      final e = raw[i];
      if (e is! Map) {
        errors.add(TimetableImportError('节次项应为对象', row: row));
        continue;
      }
      final m = e.cast<String, Object?>();
      final before = errors.length;

      final index = _asInt(m['index']);
      if (index == null || index < 1) {
        errors.add(TimetableImportError('节次序号必须为正整数: ${m['index']}', row: row));
      } else {
        if (!seenIndex.add(index)) {
          errors.add(TimetableImportError('节次序号重复: $index', row: row));
        }
      }

      final start = (m['startTime'] as String?)?.trim() ?? '';
      final end = (m['endTime'] as String?)?.trim() ?? '';
      if (!isValidTime24h(start) || !isValidTime24h(end)) {
        errors.add(TimetableImportError('节次时间格式应为 HH:mm: "$start"-"$end"', row: row));
      } else if (start.compareTo(end) >= 0) {
        errors.add(TimetableImportError('节次开始时间必须早于结束时间', row: row));
      }

      if (errors.length == before) {
        periods.add(Period(index: index!, startTime: start, endTime: end));
      }
    }
    return periods;
  }

  List<Course> _parseCourses(dynamic raw, List<TimetableImportError> errors) {
    final courses = <Course>[];
    if (raw == null) return courses;
    if (raw is! List) {
      errors.add(TimetableImportError('"courses" 应为数组'));
      return courses;
    }
    for (var i = 0; i < raw.length; i++) {
      final row = i + 1;
      final e = raw[i];
      if (e is! Map) {
        errors.add(TimetableImportError('课程项应为对象', row: row));
        continue;
      }
      final course = _parseCourse(e.cast<String, Object?>(), row, errors);
      if (course != null) courses.add(course);
    }
    return courses;
  }

  Course? _parseCourse(Map<String, Object?> m, int row, List<TimetableImportError> errors) {
    final before = errors.length;

    final name = (m['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) errors.add(TimetableImportError('课程名不能为空', row: row));

    final teacher = (m['teacher'] as String?) ?? '';
    final location = (m['location'] as String?) ?? '';

    var color = (m['color'] as String?)?.trim() ?? '';
    if (color.isNotEmpty && !_isColorHex(color)) {
      errors.add(TimetableImportError('颜色格式应为 #RRGGBB: "$color"', row: row));
    }
    color = _normalizeColor(color);

    WeekType weekType;
    try {
      weekType = WeekType.fromCodeLenient((m['weekType'] as String?) ?? '');
    } on FormatException {
      weekType = WeekType.every;
      errors.add(TimetableImportError('周次类型非法: ${m['weekType']}', row: row));
    }

    var weekList = const <int>[];
    if (weekType == WeekType.custom) {
      final parsed = _parseWeekList(m['weekList'], row, errors);
      if (parsed == null) return null;
      if (parsed.isEmpty) {
        errors.add(TimetableImportError('自定义周次必须提供自定义周序列', row: row));
      }
      weekList = parsed;
    }

    final startWeek = _asInt(m['startWeek']);
    final endWeek = _asInt(m['endWeek']);
    if (startWeek == null || startWeek < 1 || startWeek > 99) {
      errors.add(TimetableImportError('开始周非法: ${m['startWeek']}', row: row));
    }
    if (endWeek == null || endWeek < 1 || endWeek > 99) {
      errors.add(TimetableImportError('结束周非法: ${m['endWeek']}', row: row));
    }
    if (startWeek != null && endWeek != null && startWeek > endWeek) {
      errors.add(TimetableImportError('开始周不能大于结束周', row: row));
    }

    final weekday = _asInt(m['weekday']);
    if (weekday == null || weekday < 1 || weekday > 7) {
      errors.add(TimetableImportError('星期越界: ${m['weekday']}（应为 1-7）', row: row));
    }

    final startPeriod = _asInt(m['startPeriod']);
    final endPeriod = _asInt(m['endPeriod']);
    if (startPeriod == null || startPeriod < 1) {
      errors.add(TimetableImportError('开始节次越界: ${m['startPeriod']}', row: row));
    }
    if (endPeriod == null || endPeriod < 1) {
      errors.add(TimetableImportError('结束节次越界: ${m['endPeriod']}', row: row));
    }
    if (startPeriod != null && endPeriod != null && startPeriod > endPeriod) {
      errors.add(TimetableImportError('开始节次不能大于结束节次', row: row));
    }

    if (errors.length != before) return null;
    return Course(
      // semesterId 由 _apply 在写入时回填。
      semesterId: 0,
      name: name,
      teacher: teacher,
      location: location,
      color: color,
      weekType: weekType,
      weekList: weekList,
      startWeek: startWeek!,
      endWeek: endWeek!,
      weekday: weekday!,
      startPeriod: startPeriod!,
      endPeriod: endPeriod!,
    );
  }

  List<int>? _parseWeekList(dynamic raw, int row, List<TimetableImportError> errors) {
    if (raw == null) return const [];
    if (raw is List) {
      final result = <int>[];
      for (final e in raw) {
        final v = _asInt(e);
        if (v == null || v < 1 || v > 99) {
          errors.add(TimetableImportError('自定义周序列含非法周次: $e', row: row));
          return null;
        }
        result.add(v);
      }
      return result;
    }
    if (raw is String) {
      var s = raw.trim();
      if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
      if (s.isEmpty) return const [];
      final parts = s.split(RegExp(r'[,，;；\s]+'));
      final result = <int>[];
      for (final p in parts) {
        if (p.isEmpty) continue;
        final v = int.tryParse(p.trim());
        if (v == null || v < 1 || v > 99) {
          errors.add(TimetableImportError('自定义周序列含非法周次: "$p"', row: row));
          return null;
        }
        result.add(v);
      }
      return result;
    }
    errors.add(TimetableImportError('自定义周序列格式非法', row: row));
    return null;
  }

  // ---- 写入（事务，整体成功/失败） ----

  Future<TimetableImportResult> _apply({
    required int semesterId,
    Semester? newSemester,
    required List<Period> periods,
    required List<Course> courses,
    required ImportStrategy strategy,
    required bool includePeriods,
  }) async {
    final database = await db.database;
    var finalSemesterId = semesterId;
    var periodsImported = 0;
    var coursesImported = 0;

    await database.transaction((txn) async {
      if (newSemester != null) {
        finalSemesterId = await txn.insert(DbTables.semester, newSemester.toDbMap());
      }

      if (includePeriods) {
        if (strategy == ImportStrategy.overwrite) {
          await txn.delete(DbTables.period);
          for (final p in periods) {
            await txn.insert(DbTables.period, p.toDbMap());
          }
          periodsImported = periods.length;
        } else {
          for (final p in periods) {
            final exists = await _periodIndexExists(txn, p.index);
            if (!exists) {
              await txn.insert(DbTables.period, p.toDbMap());
              periodsImported++;
            }
          }
        }
      }

      if (strategy == ImportStrategy.overwrite) {
        await txn.delete(
          DbTables.course,
          where: 'semester_id = ?',
          whereArgs: [finalSemesterId],
        );
      }

      for (final c in courses) {
        if (strategy == ImportStrategy.merge) {
          final existing = await _findCourseId(
            txn,
            semesterId: finalSemesterId,
            name: c.name,
            weekday: c.weekday,
            startWeek: c.startWeek,
            endWeek: c.endWeek,
            startPeriod: c.startPeriod,
            endPeriod: c.endPeriod,
          );
          if (existing != null) continue;
        }
        await txn.insert(
          DbTables.course,
          c.copyWith(semesterId: finalSemesterId).toDbMap(),
        );
        coursesImported++;
      }
    });

    return TimetableImportResult(
      semesterId: finalSemesterId,
      periodsImported: periodsImported,
      coursesImported: coursesImported,
    );
  }

  Future<bool> _periodIndexExists(Transaction txn, int index) async {
    final rows = await txn.query(
      DbTables.period,
      columns: ['id'],
      where: 'idx = ?',
      whereArgs: [index],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<int?> _findCourseId(
    Transaction txn, {
    required int semesterId,
    required String name,
    required int weekday,
    required int startWeek,
    required int endWeek,
    required int startPeriod,
    required int endPeriod,
  }) async {
    final rows = await txn.query(
      DbTables.course,
      columns: ['id'],
      where: 'semester_id = ? AND name = ? AND weekday = ? '
          'AND start_week = ? AND end_week = ? '
          'AND start_period = ? AND end_period = ?',
      whereArgs: [
        semesterId,
        name,
        weekday,
        startWeek,
        endWeek,
        startPeriod,
        endPeriod,
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  // ---- 基础工具 ----

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static bool _isColorHex(String value) =>
      RegExp(r'^#?[0-9A-Fa-f]{6}$').hasMatch(value);

  static String _normalizeColor(String value) {
    if (value.isEmpty) return '';
    final withoutHash = value.startsWith('#') ? value.substring(1) : value;
    return '#${withoutHash.toUpperCase()}';
  }

  static String _csvField(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  static List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var i = 0;
    while (i < line.length) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.write(ch);
        i++;
      } else {
        if (ch == '"') {
          inQuotes = true;
          i++;
        } else if (ch == ',') {
          result.add(field.toString());
          field.clear();
          i++;
        } else {
          field.write(ch);
          i++;
        }
      }
    }
    result.add(field.toString());
    return result;
  }
}
