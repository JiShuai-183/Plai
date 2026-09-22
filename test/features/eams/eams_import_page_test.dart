import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/import_export/timetable_import_export.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/timetable/eams/eams_client.dart';
import 'package:plai/features/timetable/eams/eams_import_page.dart';
import 'package:plai/features/timetable/eams/eams_import_service.dart';
import 'package:plai/features/timetable/timetable_settings_keys.dart';
import 'package:plai/features/timetable/timetable_providers.dart';

/// 免网络课表样本：2 条安排 / 2 门课 / 第 1–4 周（结构同解析层单测样本）。
const String _sampleHtml = '''
var table0 = new CourseTable(2026, 70);
var unitCount = 10;
var actTeachers = [{id:1,name:"王老师",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"1(26271.MK00001A.050)","高等数学(26271.MK00001A.050)","1","A101","01111000000000000000000000000000000000000000000000000",null,null,assistantName,"","");
index =0*unitCount+0;
table0.activities[index][table0.activities[index].length]=activity;
var actTeachers = [{id:2,name:"李老师",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"2(26271.MK00002A.050)","大学英语(26271.MK00002A.050)","2","B202","01010000000000000000000000000000000000000000000000000",null,null,assistantName,"","");
index =2*unitCount+2;
table0.activities[index][table0.activities[index].length]=activity;
''';

/// 真样本 fixture：31 条安排 / 14 门课 / 第 1–18 周（用于「超出学期总周数」用例）。
String _fixtureHtml() => File(
      'test/features/eams/fixtures/course_table_sample.html',
    ).readAsStringSync();

/// 回放固定响应体的假客户端（**不发真网络**）。
class _FakeClient extends EamsClient {
  _FakeClient(this.html) : _error = null;

  /// 非空时直接抛出（驱动错误分支）。
  _FakeClient.failing(EamsException error)
      : html = '',
        _error = error;

  final String html;
  final EamsException? _error;

  /// 记录 UI 传入的凭据（用于断言密码只走内存、不进 settings）。
  String? lastUsername;
  String? lastPassword;

  @override
  Future<String> fetchCourseTableHtml({
    required String username,
    required String password,
  }) async {
    lastUsername = username;
    lastPassword = password;
    final EamsException? error = _error;
    if (error != null) throw error;
    return html;
  }
}

/// 内存学期 / 课程仓库（不碰 sqflite）。
class _FakeRepository implements ITimetableRepository {
  _FakeRepository(this.semester);

  Semester? semester;
  final List<Course> courses = <Course>[];
  int _nextCourseId = 1000;

  int addCourse(Course course) {
    final Course stored = course.copyWith(id: _nextCourseId++);
    courses.add(stored);
    return stored.id!;
  }

  @override
  Future<List<Semester>> getSemesters() async =>
      semester == null ? <Semester>[] : <Semester>[semester!];

  @override
  Future<Semester?> getSemesterById(int id) async =>
      semester?.id == id ? semester : null;

  @override
  Future<int> updateSemester(Semester value) async {
    if (semester?.id != value.id) return 0;
    semester = value;
    return 1;
  }

  @override
  Future<List<Course>> getCourses(int semesterId) async => <Course>[
        for (final Course c in courses)
          if (c.semesterId == semesterId) c,
      ];

  @override
  Future<List<Course>> getAllCourses() async => List<Course>.of(courses);

  @override
  Future<int> deleteCourse(int id) async {
    final int before = courses.length;
    courses.removeWhere((Course c) => c.id == id);
    return before - courses.length;
  }

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async =>
      const <Holiday>[];

  // ---- 以下页面 / 编排层用不到 ----

  @override
  Future<int> insertSemester(Semester value) => throw UnimplementedError();

  @override
  Future<int> deleteSemester(int id) => throw UnimplementedError();

  @override
  Future<List<Course>> getCoursesByWeekday(int semesterId, int weekday) =>
      throw UnimplementedError();

  @override
  Future<Course?> getCourseById(int id) => throw UnimplementedError();

  @override
  Future<int> insertCourse(Course course) => throw UnimplementedError();

  @override
  Future<int> updateCourse(Course course) => throw UnimplementedError();

  @override
  Future<int> insertPeriod(Period period) => throw UnimplementedError();

  @override
  Future<int> updatePeriod(Period period) => throw UnimplementedError();

  @override
  Future<int> deletePeriod(int id) => throw UnimplementedError();

  @override
  Future<void> replacePeriods(List<Period> periods) =>
      throw UnimplementedError();

  @override
  Future<int> insertHoliday(Holiday holiday) => throw UnimplementedError();

  @override
  Future<int> updateHoliday(Holiday holiday) => throw UnimplementedError();

  @override
  Future<int> deleteHoliday(int id) => throw UnimplementedError();
}

/// 内存设置仓库。
class _FakeSettings implements ISettingsRepository {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    values.addAll(entries);
  }

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(values);

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

/// 假导入器：把 JSON 里的课程按 merge 语义写进内存仓库（不碰 sqflite）。
class _FakeImportExport extends TimetableImportExport {
  _FakeImportExport(this.repo)
      : super(db: AppDatabase(), timetable: repo);

  final _FakeRepository repo;

  @override
  Future<TimetableImportResult> importJson(
    String content, {
    int? targetSemesterId,
    required ImportStrategy strategy,
  }) async {
    final Map<String, dynamic> json =
        jsonDecode(content) as Map<String, dynamic>;
    final List<dynamic> rawCourses = json['courses'] as List<dynamic>;
    var imported = 0;
    for (final dynamic raw in rawCourses) {
      final Map<String, dynamic> m = raw as Map<String, dynamic>;
      final Course course = Course(
        semesterId: targetSemesterId ?? 0,
        name: m['name'] as String,
        teacher: (m['teacher'] as String?) ?? '',
        location: (m['location'] as String?) ?? '',
        color: (m['color'] as String?) ?? '',
        weekType: WeekType.values.firstWhere(
          (WeekType t) => t.code == m['weekType'],
        ),
        weekList: <int>[
          for (final dynamic w in (m['weekList'] as List<dynamic>? ?? <dynamic>[]))
            w as int,
        ],
        startWeek: m['startWeek'] as int,
        endWeek: m['endWeek'] as int,
        weekday: m['weekday'] as int,
        startPeriod: m['startPeriod'] as int,
        endPeriod: m['endPeriod'] as int,
      );
      if (repo.courses.any((Course c) => _sameMergeKey(c, course))) continue;
      repo.addCourse(course);
      imported++;
    }
    return TimetableImportResult(
      semesterId: targetSemesterId ?? 0,
      periodsImported: 0,
      coursesImported: imported,
    );
  }

  /// 数据层 merge 的去重键（不含教师 / 教室 / 颜色 / weekList）。
  static bool _sameMergeKey(Course a, Course b) =>
      a.semesterId == b.semesterId &&
      a.name == b.name &&
      a.weekday == b.weekday &&
      a.startWeek == b.startWeek &&
      a.endWeek == b.endWeek &&
      a.startPeriod == b.startPeriod &&
      a.endPeriod == b.endPeriod;
}

/// 统一的装配：内存仓库 + 假客户端 + 假导入器 + 可选假日期选择器。
Future<void> _pumpPage(
  WidgetTester tester, {
  required _FakeRepository repo,
  required _FakeSettings settings,
  required EamsClient client,
  EamsStartDatePicker? picker,
  String? rememberedUsername = '20240001',
}) async {
  if (rememberedUsername != null) {
    settings.values[EamsImportPage.usernameSettingKey] = rememberedUsername;
  }
  final TimetableImportExport importExport = _FakeImportExport(repo);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        timetableRepositoryProvider.overrideWithValue(repo),
        settingsRepositoryProvider.overrideWithValue(settings),
        eamsImportServiceProvider.overrideWith(
          (Ref ref) => EamsImportService(
            timetable: repo,
            settings: settings,
            importExport: importExport,
            client: client,
          ),
        ),
      ],
      child: MaterialApp(home: EamsImportPage(pickStartDate: picker)),
    ),
  );
  await tester.pumpAndSettle();
}

/// 输入密码并点「拉取课表」。
Future<void> _fetch(WidgetTester tester, {String password = 'SuperSecret123'}) async {
  await tester.enterText(find.byType(TextField).at(1), password);
  await tester.tap(find.text('拉取课表'));
  await tester.pumpAndSettle();
}

Semester _semester({int totalWeeks = 16, DateTime? startDate}) => Semester(
      id: 7,
      name: '2026 秋',
      startDate: startDate ?? DateTime(2026, 9, 1),
      totalWeeks: totalWeeks,
    );

void main() {
  // 高视口：预览 / 警告 / 按钮一次性全部构建，避免 ListView 懒加载漏查。
  void useTallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('初始态：学号预填、密码为空且隐藏', (WidgetTester tester) async {
    useTallView(tester);
    final _FakeSettings settings = _FakeSettings();
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester()),
      settings: settings,
      client: _FakeClient(_sampleHtml),
    );

    final List<EditableText> fields =
        tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    expect(fields, hasLength(2));
    expect(fields.first.controller.text, '20240001');
    expect(fields[1].controller.text, isEmpty);
    expect(fields[1].obscureText, isTrue);
    expect(find.text('连接为明文 http，密码不会保存在本机。'), findsOneWidget);
  });

  testWidgets('拉取成功 → 预览区数字与 EamsImportPreview 一致', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester()),
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);

    expect(find.textContaining('共 2 门课'), findsOneWidget);
    expect(find.textContaining('2 条安排'), findsOneWidget);
    expect(find.textContaining('第 1–4 周'), findsOneWidget);
    expect(find.textContaining('当前学期：2026 秋'), findsOneWidget);
    expect(find.textContaining('开学日 2026-09-01'), findsOneWidget);
    expect(find.textContaining('共 16 周'), findsOneWidget);
    expect(find.textContaining('确认导入（'), findsOneWidget);
  });

  testWidgets('登录被拒 → 显示服务端「账号或密码异常」文案', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester()),
      settings: _FakeSettings(),
      client: _FakeClient.failing(const EamsLoginException('账号或密码异常')),
    );
    await _fetch(tester);

    expect(find.textContaining('账号或密码异常'), findsWidgets);
    // 失败后不出现预览区与确认按钮。
    expect(find.textContaining('确认导入（'), findsNothing);
  });

  testWidgets('验证码 → 提示去浏览器/稍后重试，不硬闯', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester()),
      settings: _FakeSettings(),
      client: _FakeClient.failing(const EamsCaptchaException(
        '教务系统要求输入验证码，本应用不代为识别。请先在浏览器登录学校门户确认账号正常，'
        '再稍后重试；若持续出现，请手动导入课表文件。',
      )),
    );
    await _fetch(tester);

    expect(find.textContaining('验证码'), findsWidgets);
    expect(find.textContaining('浏览器'), findsWidgets);
    expect(find.textContaining('确认导入（'), findsNothing);
  });

  testWidgets('maxWeek > totalWeeks → 警告出现且勾选框默认未勾', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester(totalWeeks: 16)),
      settings: _FakeSettings(),
      client: _FakeClient(_fixtureHtml()),
    );
    await _fetch(tester);

    expect(find.textContaining('用到第 18 周'), findsOneWidget);
    expect(find.textContaining('超出当前学期的 16 周'), findsOneWidget);
    expect(find.textContaining('同时把本学期总周数改为 18'), findsOneWidget);

    // 勾选框顺序：周数溢出卡在变更卡**之前**，故第一个即溢出勾选框，
    // 且默认未勾（见 §5.3）；其余为变更清单的「全选 + 逐项」，默认全勾。
    final List<Checkbox> boxes =
        tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes.length, greaterThan(1));
    expect(boxes.first.value, isFalse);
    expect(
      boxes.skip(1).every((Checkbox b) => b.value == true),
      isTrue,
    );
  });

  testWidgets('maxWeek <= totalWeeks → 无周数溢出警告', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester(totalWeeks: 16)),
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);

    expect(find.textContaining('超出当前学期'), findsNothing);
    expect(find.textContaining('同时把本学期总周数改为'), findsNothing);
    // 首次导入天然全是「将新增」→ 变更卡仍在（那不是周数溢出的勾选框）。
    expect(find.textContaining('与当前学期的差异'), findsOneWidget);
  });

  testWidgets('点「确认导入」→ 调用 service 并展示结果', (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);
    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    expect(find.text('已更新 0 条、新增 2 条、该学期现有 2 条'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(repo.courses, hasLength(2));
  });

  testWidgets('设置里有默认课程颜色 → 导入的课套上该色', (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    final _FakeSettings settings = _FakeSettings();
    settings.values[TimetableSettingsKeys.defaultCourseColor] = '#FF8800';
    await _pumpPage(
      tester,
      repo: repo,
      settings: settings,
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);
    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    expect(repo.courses, hasLength(2));
    for (final Course c in repo.courses) {
      expect(c.color, '#FF8800');
    }
  });

  testWidgets('修改开学日 → 二次确认；取消则学期不动', (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
      picker: (_, _) async => DateTime(2026, 9, 7),
    );
    await _fetch(tester);

    await tester.tap(find.text('修改开学日'));
    await tester.pumpAndSettle();
    expect(
      find.text('修改开学日会改变本学期的全部课程日期，包括你手动添加的课程。确定？'),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 显示值未变。
    expect(find.textContaining('开学日 2026-09-01'), findsOneWidget);

    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    // updatedSemester 未传 → 学期原样不动。
    expect(repo.semester!.startDate, DateTime(2026, 9, 1));
    expect(repo.semester!.totalWeeks, 16);
  });

  testWidgets('修改开学日 → 确认后按 updatedSemester 写回学期', (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
      picker: (_, _) async => DateTime(2026, 9, 7),
    );
    await _fetch(tester);

    await tester.tap(find.text('修改开学日'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('开学日 2026-09-07'), findsOneWidget);

    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    expect(repo.semester!.startDate, DateTime(2026, 9, 7));
    expect(repo.semester!.totalWeeks, 16);
  });

  testWidgets('密码不落盘：一轮拉取 + 导入后 settings 里没有密码', (WidgetTester tester) async {
    useTallView(tester);
    const String password = 'SuperSecret123';
    final _FakeSettings settings = _FakeSettings();
    final _FakeClient client = _FakeClient(_sampleHtml);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester()),
      settings: settings,
      client: client,
    );
    await _fetch(tester, password: password);
    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    // 页面把凭据传给了网络层（仅内存）。
    expect(client.lastPassword, password);

    final Map<String, String> all = settings.values;
    for (final MapEntry<String, String> e in all.entries) {
      expect(e.key.toLowerCase(), isNot(contains('password')));
      expect(e.key.toLowerCase(), isNot(contains('pwd')));
      expect(e.value, isNot(contains(password)));
    }
    // 只记住学号；记账式已废弃 → 编排层不再往 settings 写任何键。
    expect(all.keys.toSet(), <String>{EamsImportPage.usernameSettingKey});
    expect(all[EamsImportPage.usernameSettingKey], '20240001');
  });

  testWidgets('当前无学期 → 提示且禁用拉取', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(null),
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );

    expect(find.textContaining('当前没有学期'), findsOneWidget);
    final FilledButton button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '拉取课表'),
    );
    expect(button.onPressed, isNull);
  });

  // ---- 以教务为准的变更清单（见 EamsImportPlan） ----

  /// 手工插一条与 `_sampleHtml` 里「高等数学」同键的课（只有教室不同）。
  ///
  /// 键必须与解析结果逐一对应：该活动只有**一条** `index` 行（`0*unitCount+0`）
  /// → 星期 1、**单节（第 1-1 节）**、周次 {1,2,3,4}（every 1-4）。
  int addCollidingManual(_FakeRepository repo, {String location = '旧教室'}) =>
      repo.addCourse(Course(
        semesterId: 7,
        name: '高等数学',
        teacher: '旧老师',
        location: location,
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 4,
        weekday: 1,
        startPeriod: 1,
        endPeriod: 1,
      ));

  /// 插一条教务课表里**没有**的课（触发「将删除」）。
  int addExtraManual(_FakeRepository repo) => repo.addCourse(Course(
        semesterId: 7,
        name: '我自己加的课',
        teacher: '我自己',
        location: '图书馆',
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 16,
        weekday: 5,
        startPeriod: 9,
        endPeriod: 10,
      ));

  testWidgets('有差异 → 出现变更清单、默认勾选「以教务为准」',
      (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    addCollidingManual(repo);
    addExtraManual(repo);
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);

    expect(
      find.textContaining('与当前学期的差异（以教务课表为准）'),
      findsOneWidget,
    );
    expect(find.textContaining('［将更新］高等数学'), findsOneWidget);
    expect(find.textContaining('教室：旧教室 → A101'), findsOneWidget);
    expect(find.textContaining('［将删除］我自己加的课'), findsOneWidget);

    // 勾选框 = 全选 + 逐项（3 条变更：新增 大学英语 / 更新 高等数学 /
    // 删除 我自己加的课），**默认全勾** = 以教务为准。
    final List<Checkbox> boxes =
        tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes, hasLength(4));
    expect(boxes.every((Checkbox b) => b.value == true), isTrue);
    expect(find.text('全选（已全部勾选）'), findsOneWidget);
    expect(find.textContaining('确认导入（3 项）'), findsOneWidget);
  });

  testWidgets('无差异 → 不出现变更清单', (WidgetTester tester) async {
    useTallView(tester);
    await _pumpPage(
      tester,
      repo: _FakeRepository(_semester()),
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );

    // 首次导入天然全是「将新增」→ 有变更卡。
    await _fetch(tester);
    expect(find.textContaining('与当前学期的差异'), findsOneWidget);

    // 导入后学期内容已与教务一致 → 再拉取应当无差异、不再出现变更卡。
    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();
    await _fetch(tester);

    expect(find.textContaining('与当前学期的差异'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('全不选 → 按钮变成禁用的「未选择任何变更」，不改动任何课程',
      (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    final int manualId = addCollidingManual(repo);
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);

    // 第一个勾选框是全选（在变更清单顶部）。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    final FilledButton button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '未选择任何变更'),
    );
    expect(button.onPressed, isNull);

    // 原有课程分毫未动。
    final Course math = (await repo.getCourses(7))
        .firstWhere((Course c) => c.name == '高等数学');
    expect(math.id, manualId);
    expect(math.location, '旧教室');
  });

  testWidgets('逐项取消：只勾一条 → 只有那一条被施加（其余原样）',
      (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    final int manualId = addCollidingManual(repo);
    addExtraManual(repo);
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);

    // 勾选框顺序：0=全选；变更按 新增 → 更新 → 删除 排序，故
    // 1=将新增 大学英语，2=将更新 高等数学，3=将删除 我自己加的课。
    // 取消第 3 条 → 「我自己加的课」应当保留。
    await tester.tap(find.byType(Checkbox).at(3));
    await tester.pumpAndSettle();
    expect(find.textContaining('确认导入（2 项）'), findsOneWidget);

    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    final List<Course> after = await repo.getCourses(7);
    // 「将删除」未被勾选 → 保留；「将更新」被勾选 → 更新为教务版本。
    expect(after.any((Course c) => c.name == '我自己加的课'), isTrue);
    final Course math = after.firstWhere((Course c) => c.name == '高等数学');
    expect(math.location, 'A101');
    expect(math.id, isNot(manualId));
  });

  testWidgets('默认全选 → 确认导入后按教务更新，并删除教务没有的课程',
      (WidgetTester tester) async {
    useTallView(tester);
    final _FakeRepository repo = _FakeRepository(_semester());
    final int manualId = addCollidingManual(repo);
    addExtraManual(repo);
    await _pumpPage(
      tester,
      repo: repo,
      settings: _FakeSettings(),
      client: _FakeClient(_sampleHtml),
    );
    await _fetch(tester);

    await tester.tap(find.textContaining('确认导入'));
    await tester.pumpAndSettle();

    final List<Course> after = await repo.getCourses(7);
    // 学期内容 == 教务课表：手动那条被清掉，同键那条更新成教务版本。
    expect(after.any((Course c) => c.name == '我自己加的课'), isFalse);
    final Course math = after.firstWhere((Course c) => c.name == '高等数学');
    expect(math.location, 'A101');
    expect(math.teacher, '王老师');
    expect(math.id, isNot(manualId)); // 旧行已删，是重新写入的
    expect(after, hasLength(2));
  });
}

