/// 数据库 schema：表名常量与建表 DDL。
///
/// V1 含 6 张表（semester/course/period/holiday/task/setting）。
/// V2 新增 task_daily_logs（每日打卡完成记录）并为 task 表补 start_date 列。
/// V3 新增 chat_session / chat_message（AI 对话历史）。
/// point_log/ai_config（积分与 AI 配置表）留待后续版本（AI 配置暂走 setting 表 ai.* 键）。
/// 新增表走 [lib/data/db/app_database.dart] 的 onUpgrade 增量迁移。
library;

/// 表名常量（统一引用，避免拼写错误）。
abstract final class DbTables {
  static const semester = 'semester';
  static const course = 'course';
  static const period = 'period';
  static const holiday = 'holiday';
  static const task = 'task';
  static const taskDailyLog = 'task_daily_logs';
  static const setting = 'setting';
  static const chatSession = 'chat_session';
  static const chatMessage = 'chat_message';
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
  created_at TEXT NOT NULL,
  start_date TEXT
)''';

/// 每日打卡完成记录表 DDL。
///
/// 一行 = 某 daily 任务某天已打卡（`date` 存 `yyyy-MM-dd`）。
/// `(task_id, date)` 唯一，删任务级联清记录。
const String createTaskDailyLogTable = '''
CREATE TABLE task_daily_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  completed_at TEXT,
  UNIQUE(task_id, date)
)''';

/// 键值设置表 DDL。
const String createSettingTable = '''
CREATE TABLE setting (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''';

/// AI 会话表 DDL。
///
/// 一行 = 一个对话历史。`pinned` 存 0/1（1=置顶），历史排序：
/// 置顶优先 → 其余按 `last_active_at` 倒序（活跃会话排前）。
const String createChatSessionTable = '''
CREATE TABLE chat_session (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  last_active_at TEXT NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0
)''';

/// AI 对话消息表 DDL。
///
/// 一行 = 会话内一条消息（role=user/assistant/tool，PRD §8）。
/// - `has_context`：是否附带上下文标记（0/1，默认 0）；
/// - `attachments`：图片本地路径 JSON 数组字符串（可空，`["/a.png"]`）；
/// - `tool_data`：工具调用/结果记录 JSON 数组字符串（可空，供多轮与回放）。
///   工具类消息由 [ChatRole.tool] 承载，`content` 存结果文本。
/// 删会话 → 消息级联删除。
const String createChatMessageTable = '''
CREATE TABLE chat_message (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  has_context INTEGER NOT NULL DEFAULT 0,
  attachments TEXT,
  tool_data TEXT,
  created_at TEXT NOT NULL
)''';

/// 消息按会话查询索引（带 IF NOT EXISTS，迁移幂等）。
const String createChatMessageSessionIndex =
    'CREATE INDEX IF NOT EXISTS idx_chat_message_session '
    'ON chat_message(session_id)';

/// 索引 DDL（查询性能，V1 规模足够）。
const List<String> createIndexStatements = [
  'CREATE INDEX idx_course_semester ON course(semester_id)',
  'CREATE INDEX idx_course_weekday ON course(semester_id, weekday)',
  'CREATE INDEX idx_holiday_date ON holiday(date)',
  'CREATE INDEX idx_task_due_date ON task(due_date)',
  'CREATE INDEX idx_task_completed ON task(completed)',
  'CREATE INDEX idx_task_daily_log_task ON task_daily_logs(task_id)',
  createChatMessageSessionIndex,
];

/// 全部建表 DDL，按外键依赖顺序排列。
const List<String> createTableStatements = [
  createSemesterTable,
  createCourseTable,
  createPeriodTable,
  createHolidayTable,
  createTaskTable,
  createTaskDailyLogTable,
  createSettingTable,
  createChatSessionTable,
  createChatMessageTable,
];
