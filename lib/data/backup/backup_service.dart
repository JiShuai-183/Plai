import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/course.dart';
import '../models/holiday.dart';
import '../models/period.dart';
import '../models/semester.dart';
import '../models/task.dart';
import '../repositories/settings_repository.dart';
import '../repositories/task_repository.dart';
import '../repositories/timetable_repository.dart';

/// 恢复策略（PRD-设置与数据 §2）。
enum RestoreStrategy {
  /// 覆盖：清空现有全部数据后用备份替换（需强确认 + 二次输入确认）。
  overwrite,

  /// 合并：并入现有库，按业务键去重（任务按 标题+日期，学期按 名称）。
  merge,
}

/// `.plai` 备份文件格式常量。
abstract final class PlaiBackupFormat {
  static const String format = 'plai-backup';
  static const int version = 1;
}

/// 备份预览摘要（恢复前展示给用户确认）。
class BackupPreview {
  const BackupPreview({
    this.exportedAt,
    required this.semesterCount,
    required this.courseCount,
    required this.periodCount,
    required this.holidayCount,
    required this.taskCount,
    required this.settingCount,
  });

  final DateTime? exportedAt;
  final int semesterCount;
  final int courseCount;
  final int periodCount;
  final int holidayCount;
  final int taskCount;
  final int settingCount;
}

/// 备份文件格式非法时抛出。
class BackupFormatException implements Exception {
  BackupFormatException(this.message);

  final String message;

  @override
  String toString() => '备份文件格式错误: $message';
}

/// 备份 / 恢复服务。
///
/// `.plai` 备份文件 = JSON 打包数据库全部表 + 设置键值，结构：
/// ```json
/// {
///   "format": "plai-backup", "version": 1, "exportedAt": "...",
///   "data": {
///     "semesters": [...], "courses": [...], "periods": [...],
///     "holidays": [...], "tasks": [...], "settings": {"k": "v"}
///   }
/// }
/// ```
class BackupService {
  BackupService({
    required this.db,
    required this.timetable,
    required this.tasks,
    required this.settings,
  });

  final AppDatabase db;
  final ITimetableRepository timetable;
  final ITaskRepository tasks;
  final ISettingsRepository settings;

  /// 导出当前库为备份 JSON Map。
  Future<Map<String, dynamic>> exportToJson() async {
    final data = <String, dynamic>{
      'semesters': (await timetable.getSemesters()).map((e) => e.toJson()).toList(),
      'courses': (await timetable.getAllCourses()).map((e) => e.toJson()).toList(),
      'periods': (await timetable.getPeriods()).map((e) => e.toJson()).toList(),
      'holidays': (await timetable.getHolidays()).map((e) => e.toJson()).toList(),
      'tasks': (await tasks.getTasks()).map((e) => e.toJson()).toList(),
      'settings': await settings.getAll(),
    };
    return {
      'format': PlaiBackupFormat.format,
      'version': PlaiBackupFormat.version,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': data,
    };
  }

  /// 导出为 `.plai` 文件（UTF-8 格式化 JSON）。
  Future<void> exportToFile(String path) async {
    final json = await exportToJson();
    final file = File(path);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      encoding: utf8,
    );
  }

  /// 读取 `.plai` 文件并解析为 JSON Map（仅读取，不写库）。
  Future<Map<String, dynamic>> readFile(String path) async {
    final content = await File(path).readAsString(encoding: utf8);
    return jsonDecode(content) as Map<String, dynamic>;
  }

  /// 校验备份文件格式并返回预览摘要；格式非法抛 [BackupFormatException]。
  BackupPreview preview(Map<String, dynamic> json) {
    _validateHeader(json);
    final data = _requireData(json);
    return BackupPreview(
      exportedAt: DateTime.tryParse((json['exportedAt'] as String?) ?? ''),
      semesterCount: _listLength(data['semesters']),
      courseCount: _listLength(data['courses']),
      periodCount: _listLength(data['periods']),
      holidayCount: _listLength(data['holidays']),
      taskCount: _listLength(data['tasks']),
      settingCount: _mapLength(data['settings']),
    );
  }

  /// 按策略恢复备份 JSON 到当前库。
  Future<void> restore(
    Map<String, dynamic> json, {
    required RestoreStrategy strategy,
  }) async {
    _validateHeader(json);
    final data = _requireData(json);
    final semesters = _parseList(data['semesters'], Semester.fromJson);
    final courses = _parseList(data['courses'], Course.fromJson);
    final periods = _parseList(data['periods'], Period.fromJson);
    final holidays = _parseList(data['holidays'], Holiday.fromJson);
    final taskList = _parseList(data['tasks'], Task.fromJson);
    final settingsMap = _parseSettings(data['settings']);

    final database = await db.database;
    if (strategy == RestoreStrategy.overwrite) {
      await _restoreOverwrite(database, semesters, courses, periods, holidays,
          taskList, settingsMap);
    } else {
      await _restoreMerge(database, semesters, courses, periods, holidays,
          taskList, settingsMap);
    }
  }

  // ---- 覆盖恢复 ----

  Future<void> _restoreOverwrite(
    Database database,
    List<Semester> semesters,
    List<Course> courses,
    List<Period> periods,
    List<Holiday> holidays,
    List<Task> taskList,
    Map<String, String> settingsMap,
  ) async {
    await database.transaction((txn) async {
      // 先删子表再删父表，避免外键约束冲突。
      await txn.delete(DbTables.task);
      await txn.delete(DbTables.holiday);
      await txn.delete(DbTables.course);
      await txn.delete(DbTables.period);
      await txn.delete(DbTables.semester);
      await txn.delete(DbTables.setting);

      final batch = txn.batch();
      for (final s in semesters) {
        batch.insert(DbTables.semester, _withoutId(s.toDbMap()));
      }
      for (final c in courses) {
        batch.insert(DbTables.course, _withoutId(c.toDbMap()));
      }
      for (final p in periods) {
        batch.insert(DbTables.period, _withoutId(p.toDbMap()));
      }
      for (final h in holidays) {
        batch.insert(DbTables.holiday, _withoutId(h.toDbMap()));
      }
      for (final t in taskList) {
        batch.insert(DbTables.task, _withoutId(t.toDbMap()));
      }
      settingsMap.forEach((k, v) {
        batch.insert(
          DbTables.setting,
          {'key': k, 'value': v},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
      await batch.commit(noResult: true);
    });
  }

  // ---- 合并恢复 ----

  Future<void> _restoreMerge(
    Database database,
    List<Semester> semesters,
    List<Course> courses,
    List<Period> periods,
    List<Holiday> holidays,
    List<Task> taskList,
    Map<String, String> settingsMap,
  ) async {
    await database.transaction((txn) async {
      // 1) 学期：按名称去重；记录 备份id -> 库里id。
      final semesterIdMap = <int, int>{};
      for (final s in semesters) {
        final existing = await _findSemesterIdByName(txn, s.name);
        if (existing != null) {
          if (s.id != null) semesterIdMap[s.id!] = existing;
        } else {
          final newId =
              await txn.insert(DbTables.semester, _withoutId(s.toDbMap()));
          if (s.id != null) semesterIdMap[s.id!] = newId;
        }
      }

      // 2) 课程：重映射 semesterId，按业务键去重；记录 备份id -> 库里id。
      final courseIdMap = <int, int>{};
      for (final c in courses) {
        final newSemesterId = semesterIdMap[c.semesterId];
        if (newSemesterId == null) continue; // 备份里学期丢失，跳过该课程。
        final existing = await _findCourseId(
          txn,
          semesterId: newSemesterId,
          name: c.name,
          weekday: c.weekday,
          startWeek: c.startWeek,
          endWeek: c.endWeek,
          startPeriod: c.startPeriod,
          endPeriod: c.endPeriod,
        );
        if (existing != null) {
          if (c.id != null) courseIdMap[c.id!] = existing;
        } else {
          final newId = await txn.insert(
              DbTables.course,
              _withoutId(c.copyWith(semesterId: newSemesterId).toDbMap()));
          if (c.id != null) courseIdMap[c.id!] = newId;
        }
      }

      // 3) 节次：按序号去重。
      for (final p in periods) {
        final exists = await _periodIndexExists(txn, p.index);
        if (!exists) {
          await txn.insert(DbTables.period, _withoutId(p.toDbMap()));
        }
      }

      // 4) 停课：重映射 courseId，按 (日期,课程,原因) 去重。
      for (final h in holidays) {
        final newCourseId = h.courseId == null
            ? null
            : courseIdMap[h.courseId!] ?? h.courseId;
        final exists = await _holidayExists(
          txn,
          date: h.date,
          courseId: newCourseId,
          reason: h.reason,
        );
        if (!exists) {
          await txn.insert(
              DbTables.holiday,
              _withoutId(h.copyWith(courseId: newCourseId).toDbMap()));
        }
      }

      // 5) 任务：按 (标题+截止日期) 去重，重映射 courseId。
      for (final t in taskList) {
        final exists = await _taskExists(txn, title: t.title, dueDate: t.dueDate);
        if (exists) continue;
        final newCourseId = t.courseId == null
            ? null
            : courseIdMap[t.courseId!] ?? t.courseId;
        await txn.insert(
            DbTables.task,
            _withoutId(t.copyWith(courseId: newCourseId).toDbMap()));
      }

      // 6) 设置：备份覆盖库中值。
      settingsMap.forEach((k, v) {
        txn.insert(
          DbTables.setting,
          {'key': k, 'value': v},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    });
  }

  // ---- 合并用查询 ----

  Future<int?> _findSemesterIdByName(Transaction txn, String name) async {
    final rows = await txn.query(
      DbTables.semester,
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
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

  Future<bool> _holidayExists(
    Transaction txn, {
    required DateTime date,
    int? courseId,
    required String reason,
  }) async {
    final dateStr = dateOnlyString(date);
    final rows = await txn.query(
      DbTables.holiday,
      columns: ['id'],
      where:
          'date = ? AND COALESCE(course_id, 0) = COALESCE(?, 0) AND reason = ?',
      whereArgs: [dateStr, courseId, reason],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> _taskExists(
    Transaction txn, {
    required String title,
    required DateTime dueDate,
  }) async {
    final dateStr = dateOnlyString(dueDate);
    final rows = await txn.query(
      DbTables.task,
      columns: ['id'],
      where: 'title = ? AND due_date = ?',
      whereArgs: [title, dateStr],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ---- 解析辅助 ----

  void _validateHeader(Map<String, dynamic> json) {
    if (json['format'] != PlaiBackupFormat.format) {
      throw BackupFormatException('"format" 字段缺失或不匹配');
    }
    final version = json['version'];
    if (version is! int || version < 1 || version > PlaiBackupFormat.version) {
      throw BackupFormatException('不支持的备份版本: $version');
    }
    if (json['data'] is! Map) {
      throw BackupFormatException('缺少 "data" 数据块');
    }
  }

  Map<String, dynamic> _requireData(Map<String, dynamic> json) =>
      (json['data'] as Map).cast<String, dynamic>();

  static List<T> _parseList<T>(
    dynamic raw,
    T Function(Map<String, Object?>) fromJson,
  ) {
    if (raw == null) return <T>[];
    if (raw is! List) throw BackupFormatException('数组字段应为数组');
    return raw.map((e) {
      if (e is! Map) throw BackupFormatException('数组元素应为对象');
      return fromJson(e.cast<String, Object?>());
    }).toList();
  }

  static Map<String, String> _parseSettings(dynamic raw) {
    if (raw == null) return <String, String>{};
    if (raw is! Map) throw BackupFormatException('"settings" 应为对象');
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// 返回去除 `id` 键的行映射，让 SQLite 自增分配主键（恢复时不沿用旧 id）。
  static Map<String, Object?> _withoutId(Map<String, Object?> map) {
    if (!map.containsKey('id')) return map;
    return Map<String, Object?>.from(map)..remove('id');
  }

  static int _listLength(dynamic raw) => raw is List ? raw.length : 0;

  static int _mapLength(dynamic raw) => raw is Map ? raw.length : 0;

  static String dateOnlyString(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
