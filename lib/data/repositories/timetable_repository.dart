import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../db/db_schema.dart';
import '../models/course.dart';
import '../models/holiday.dart';
import '../models/period.dart';
import '../models/semester.dart';

/// 课表域 Repository 接口：semester / course / period / holiday 的 CRUD 契约。
///
/// feature agent 只依赖本接口（编码约定 §4），实现见 [TimetableRepository]。
abstract class ITimetableRepository {
  // ---- 学期 Semester ----

  /// 查询全部学期，按开学日期倒序（最近的在最前）。
  Future<List<Semester>> getSemesters();

  /// 按 id 查询学期，不存在返回 null。
  Future<Semester?> getSemesterById(int id);

  /// 插入学期，返回新行自增 id。
  Future<int> insertSemester(Semester semester);

  /// 更新学期，返回受影响行数（1 表示成功）。
  Future<int> updateSemester(Semester semester);

  /// 删除学期。级联删除其下所有课程（及课程关联的停课记录）；
  /// 关联该学期课程的任务 courseId 置空。
  Future<int> deleteSemester(int id);

  // ---- 课程 Course ----

  /// 查询某学期的全部课程，按星期、起始节次排序。
  Future<List<Course>> getCourses(int semesterId);

  /// 查询全部学期下的全部课程（用于备份导出）。
  Future<List<Course>> getAllCourses();

  /// 查询某学期某星期几（1-7）的课程，按起始节次排序。
  Future<List<Course>> getCoursesByWeekday(int semesterId, int weekday);

  /// 按 id 查询课程，不存在返回 null。
  Future<Course?> getCourseById(int id);

  /// 插入课程，返回新行自增 id。
  Future<int> insertCourse(Course course);

  /// 更新课程，返回受影响行数。
  Future<int> updateCourse(Course course);

  /// 删除课程（其停课记录级联删除；关联任务 courseId 置空）。
  Future<int> deleteCourse(int id);

  // ---- 节次 Period ----

  /// 查询全部节次，按序号排序。
  Future<List<Period>> getPeriods();

  /// 插入节次，返回新行自增 id。
  Future<int> insertPeriod(Period period);

  /// 更新节次，返回受影响行数。
  Future<int> updatePeriod(Period period);

  /// 删除节次，返回受影响行数。
  Future<int> deletePeriod(int id);

  /// 整体替换节次表（事务内清空再批量插入），用于节次模板导入/覆盖。
  Future<void> replacePeriods(List<Period> periods);

  // ---- 停课/节假日 Holiday ----

  /// 查询停课记录；可按课程、日期范围过滤（全空则返回全部）。
  Future<List<Holiday>> getHolidays({int? courseId, DateTime? from, DateTime? to});

  /// 插入停课记录，返回新行自增 id。
  Future<int> insertHoliday(Holiday holiday);

  /// 更新停课记录，返回受影响行数。
  Future<int> updateHoliday(Holiday holiday);

  /// 删除停课记录，返回受影响行数。
  Future<int> deleteHoliday(int id);
}

/// 课表域 Repository 的 sqflite 实现。
class TimetableRepository implements ITimetableRepository {
  TimetableRepository(this._db);

  final AppDatabase _db;

  Future<Database> get _database => _db.database;

  // ---- Semester ----

  @override
  Future<List<Semester>> getSemesters() async {
    final db = await _database;
    final rows = await db.query(DbTables.semester, orderBy: 'start_date DESC');
    return rows.map(Semester.fromDbMap).toList();
  }

  @override
  Future<Semester?> getSemesterById(int id) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.semester,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Semester.fromDbMap(rows.first);
  }

  @override
  Future<int> insertSemester(Semester semester) async {
    final db = await _database;
    return db.insert(DbTables.semester, semester.toDbMap());
  }

  @override
  Future<int> updateSemester(Semester semester) async {
    final db = await _database;
    return db.update(
      DbTables.semester,
      semester.toDbMap(),
      where: 'id = ?',
      whereArgs: [semester.id],
    );
  }

  @override
  Future<int> deleteSemester(int id) async {
    final db = await _database;
    return db.delete(DbTables.semester, where: 'id = ?', whereArgs: [id]);
  }

  // ---- Course ----

  @override
  Future<List<Course>> getCourses(int semesterId) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.course,
      where: 'semester_id = ?',
      whereArgs: [semesterId],
      orderBy: 'weekday ASC, start_period ASC',
    );
    return rows.map(Course.fromDbMap).toList();
  }

  @override
  Future<List<Course>> getAllCourses() async {
    final db = await _database;
    final rows = await db.query(DbTables.course,
        orderBy: 'semester_id ASC, weekday ASC, start_period ASC');
    return rows.map(Course.fromDbMap).toList();
  }

  @override
  Future<List<Course>> getCoursesByWeekday(int semesterId, int weekday) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.course,
      where: 'semester_id = ? AND weekday = ?',
      whereArgs: [semesterId, weekday],
      orderBy: 'start_period ASC',
    );
    return rows.map(Course.fromDbMap).toList();
  }

  @override
  Future<Course?> getCourseById(int id) async {
    final db = await _database;
    final rows = await db.query(
      DbTables.course,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Course.fromDbMap(rows.first);
  }

  @override
  Future<int> insertCourse(Course course) async {
    final db = await _database;
    return db.insert(DbTables.course, course.toDbMap());
  }

  @override
  Future<int> updateCourse(Course course) async {
    final db = await _database;
    return db.update(
      DbTables.course,
      course.toDbMap(),
      where: 'id = ?',
      whereArgs: [course.id],
    );
  }

  @override
  Future<int> deleteCourse(int id) async {
    final db = await _database;
    return db.delete(DbTables.course, where: 'id = ?', whereArgs: [id]);
  }

  // ---- Period ----

  @override
  Future<List<Period>> getPeriods() async {
    final db = await _database;
    final rows = await db.query(DbTables.period, orderBy: 'idx ASC');
    return rows.map(Period.fromDbMap).toList();
  }

  @override
  Future<int> insertPeriod(Period period) async {
    final db = await _database;
    return db.insert(DbTables.period, period.toDbMap());
  }

  @override
  Future<int> updatePeriod(Period period) async {
    final db = await _database;
    return db.update(
      DbTables.period,
      period.toDbMap(),
      where: 'id = ?',
      whereArgs: [period.id],
    );
  }

  @override
  Future<int> deletePeriod(int id) async {
    final db = await _database;
    return db.delete(DbTables.period, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> replacePeriods(List<Period> periods) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(DbTables.period);
      final batch = txn.batch();
      for (final period in periods) {
        batch.insert(DbTables.period, period.toDbMap());
      }
      await batch.commit(noResult: true);
    });
  }

  // ---- Holiday ----

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await _database;
    final where = <String>[];
    final args = <Object?>[];
    if (courseId != null) {
      where.add('course_id = ?');
      args.add(courseId);
    }
    if (from != null) {
      where.add('date >= ?');
      args.add(_dateOnly(from));
    }
    if (to != null) {
      where.add('date <= ?');
      args.add(_dateOnly(to));
    }
    final rows = await db.query(
      DbTables.holiday,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date ASC',
    );
    return rows.map(Holiday.fromDbMap).toList();
  }

  @override
  Future<int> insertHoliday(Holiday holiday) async {
    final db = await _database;
    return db.insert(DbTables.holiday, holiday.toDbMap());
  }

  @override
  Future<int> updateHoliday(Holiday holiday) async {
    final db = await _database;
    return db.update(
      DbTables.holiday,
      holiday.toDbMap(),
      where: 'id = ?',
      whereArgs: [holiday.id],
    );
  }

  @override
  Future<int> deleteHoliday(int id) async {
    final db = await _database;
    return db.delete(DbTables.holiday, where: 'id = ?', whereArgs: [id]);
  }

  static String _dateOnly(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}
