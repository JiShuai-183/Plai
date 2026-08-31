/// 数据库 schema：表名常量与建表 DDL。
///
/// V1 含 6 张表（semester/course/period/holiday/task/setting），
/// V2 将新增 point_log/ai_config/chat_session/chat_message（积分与 AI）。
/// 新增表走 [lib/data/db/app_database.dart] 的 onUpgrade 增量迁移。
library;

/// 表名常量（统一引用，避免拼写错误）。
abstract final class DbTables {
  static const semester = 'semester';
  static const course = 'course';
  static const period = 'period';
  static const holiday = 'holiday';
  static const task = 'task';
  static const setting = 'setting';
}

/// 学期表 DDL。
const String createSemesterTable = '''
CREATE TABLE semester (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  start_date TEXT NOT NULL,
  total_weeks INTEGER NOT NULL
)''';

/// 课程表 DDL（week_list 存 JSON 数组字符串）。
const String createCourseTable = '''
CREATE TABLE course (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  semester_id INTEGER NOT NULL REFERENCES semester(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  teacher TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '',
  color TEXT NOT NULL DEFAULT '',
  week_type TEXT NOT NULL,
  week_list TEXT NOT NULL DEFAULT '[]',
  start_week INTEGER NOT NULL,
  end_week INTEGER NOT NULL,
  weekday INTEGER NOT NULL,
  start_period INTEGER NOT NULL,
  end_period INTEGER NOT NULL
)''';

/// 节次表 DDL（`idx` 为节次序号，避免与 SQL 关键字 `index` 冲突）。
const String createPeriodTable = '''
CREATE TABLE period (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  idx INTEGER NOT NULL UNIQUE,
  start_time TEXT NOT NULL,
  end_time TEXT NOT NULL
)''';

/// 停课/节假日表 DDL。
const String createHolidayTable = '''
CREATE TABLE holiday (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,
  course_id INTEGER REFERENCES course(id) ON DELETE CASCADE,
  reason TEXT NOT NULL DEFAULT ''
)''';

/// 日程/任务表 DDL。
const String createTaskTable = '''
CREATE TABLE task (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL,
  due_date TEXT NOT NULL,
  due_time TEXT,
  priority TEXT NOT NULL DEFAULT 'normal',
  course_id INTEGER REFERENCES course(id) ON DELETE SET NULL,
  remind_offset_min INTEGER,
  remind_date TEXT,
  completed INTEGER NOT NULL DEFAULT 0,
  completed_at TEXT,
  created_at TEXT NOT NULL
)''';

/// 键值设置表 DDL。
const String createSettingTable = '''
CREATE TABLE setting (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''';

/// 索引 DDL（查询性能，V1 规模足够）。
const List<String> createIndexStatements = [
  'CREATE INDEX idx_course_semester ON course(semester_id)',
  'CREATE INDEX idx_course_weekday ON course(semester_id, weekday)',
  'CREATE INDEX idx_holiday_date ON holiday(date)',
  'CREATE INDEX idx_task_due_date ON task(due_date)',
  'CREATE INDEX idx_task_completed ON task(completed)',
];

/// 全部建表 DDL，按外键依赖顺序排列。
const List<String> createTableStatements = [
  createSemesterTable,
  createCourseTable,
  createPeriodTable,
  createHolidayTable,
  createTaskTable,
  createSettingTable,
];
