import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/db/app_database.dart';
import 'package:plai/data/import_export/timetable_import_export.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/eams_credentials_repository.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/timetable/eams/eams_client.dart';
import 'package:plai/features/timetable/eams/eams_import_page.dart';
import 'package:plai/features/timetable/eams/eams_import_service.dart';
import 'package:plai/features/timetable/eams/eams_sync_reminder.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/main.dart';

/// 跨模块端到端验收：「AppShell 冷启动检查 → 弹同步提醒 → 立即同步 →
/// 落到教务导入页 → **自动拉取恰好一次** → 写入节流键与同步打点」。
///
/// 与分模块用例的区别：这里**不替换提醒本身**（走真实 `eamsSyncReminderProvider`、
/// 真实判定 / 节流 / 弹窗 / 路由跳转），只替换三类外部依赖：
/// 1. 设置仓库（内存 KV，用来摆布四个 `eams.sync.*` 键）；
/// 2. 课表仓库（内存学期，让 `currentSemesterProvider` 非 null）；
/// 3. 教务客户端与凭据（假实现，记录 `fetchPreview` 调用次数，不发真网络）。
///
/// 说明：不用 sqflite —— 本文件若调 `sqfliteFfiInit()` 会把**全局**默认工厂换成
/// 后台 isolate 版，AppShell 启动预热里那些没被覆盖的 provider（日程 / AI 直连
/// `AppDatabase.instance`）就会在测试假时钟下挂死。内存假仓库与
/// `test/features/eams/eams_import_page_test.dart` 同款，已证明稳定。

/// 回放固定响应体的假客户端（**不发真网络**）；2 条安排 / 2 门课。
const String _sampleHtml = '''
var table0 = new CourseTable(2026, 70);
var unitCount = 10;
var actTeachers = [{id:1,name:"王老师",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"1(26271.MK00001A.050)","高等数学(26271.MK00001A.050)","1","A101","01111000000000000000000000000000000000000000000000000",null,null,assistantName,"","");
index =0*unitCount+0;
table0.activities[index][table0.activities[index].length]=activity;
''';

class _FakeClient extends EamsClient {
  @override
  Future<String> fetchCourseTableHtml({
    required String username,
    required String password,
  }) async => _sampleHtml;
}

/// 记录 `fetchPreview` 调用次数的假教务服务：计数后**委托真实实现**
/// （真解析 + 真对账），保证「恰好 1 次」的断言看的是真链路。
class _CountingImportService extends EamsImportService {
  _CountingImportService({
    required super.timetable,
    required super.settings,
    required super.importExport,
  }) : super(client: _FakeClient());

  int previewCalls = 0;

  @override
  Future<EamsImportPreview> fetchPreview({
    required String username,
    required String password,
  }) {
    previewCalls++;
    return super.fetchPreview(username: username, password: password);
  }
}

/// 内存设置仓库（无 sqflite）。
class _FakeSettings implements ISettingsRepository {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async => values[key] = value;

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      values.addAll(entries);

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(values);

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// 内存课表仓库：只需满足 `currentSemesterProvider` 与导入页对账链路。
class _FakeTimetable implements ITimetableRepository {
  _FakeTimetable(this.semester);

  final Semester? semester;

  @override
  Future<List<Semester>> getSemesters() async =>
      semester == null ? <Semester>[] : <Semester>[semester!];

  @override
  Future<Semester?> getSemesterById(int id) async =>
      semester?.id == id ? semester : null;

  @override
  Future<List<Course>> getCourses(int semesterId) async => const <Course>[];

  @override
  Future<List<Course>> getAllCourses() async => const <Course>[];

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<List<Holiday>> getHolidays({
    int? courseId,
    DateTime? from,
    DateTime? to,
  }) async => const <Holiday>[];

  /// 其余方法本链路不用；显式失败好过静默返回空。
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 未在本端到端用例中使用');
}

/// 假凭据仓库：已保存账号密码 → 自动同步应能直接拉取（无需手输）。
class _FakeCredentials implements IEamsCredentialsRepository {
  _FakeCredentials({this.saved});

  EamsCredentials? saved;

  @override
  Future<EamsCredentials?> read() async => saved;

  @override
  Future<void> save(EamsCredentials credentials) async => saved = credentials;

  @override
  Future<void> clear() async => saved = null;
}

Semester _semester({int id = 7}) =>
    Semester(id: id, name: '2026 秋', startDate: DateTime(2026, 9, 1), totalWeeks: 16);

/// 装配整条链：`PlaiApp`（真路由表 / 真 AppShell / 真提醒）+ 假外部依赖。
Future<void> _pumpApp(
  WidgetTester tester, {
  required _FakeSettings settings,
  required _FakeTimetable timetable,
  required _CountingImportService service,
  IEamsCredentialsRepository? credentials,
}) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(settings),
        timetableRepositoryProvider.overrideWithValue(timetable),
        eamsCredentialsRepositoryProvider.overrideWithValue(
          credentials ?? _FakeCredentials(),
        ),
        eamsImportServiceProvider.overrideWithValue(service),
      ],
      child: const PlaiApp(),
    ),
  );
  await tester.pumpAndSettle();
}

_CountingImportService _service(_FakeTimetable timetable, _FakeSettings settings) =>
    _CountingImportService(
      timetable: timetable,
      settings: settings,
      // 自动同步路径不触发导入（不自动导入），此工具只需可构造。
      importExport: TimetableImportExport(
        db: AppDatabase(),
        timetable: timetable,
      ),
    );

int _msOf(DateTime at) => at.add(const Duration(days: 7)).millisecondsSinceEpoch;

void main() {
  testWidgets('端到端：冷启动弹提醒 → 立即同步 → 落教务导入页并自动拉取恰好 1 次', (
    WidgetTester tester,
  ) async {
    final _FakeSettings settings = _FakeSettings();
    final _FakeTimetable timetable = _FakeTimetable(_semester());
    final _CountingImportService service = _service(timetable, settings);

    // 触发时刻的下界：本学期从未同步（四个键全缺）→ should = true。
    final DateTime t0 = DateTime.now();
    await _pumpApp(
      tester,
      settings: settings,
      timetable: timetable,
      service: service,
      credentials: _FakeCredentials(
        saved: const EamsCredentials(
          username: '20240001',
          password: 'SuperSecret123',
        ),
      ),
    );

    // 1) 弹窗出现，文案逐字精确。
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(EamsSyncReminder.dialogTitle), findsOneWidget);
    expect(find.text(EamsSyncReminder.dialogBody), findsOneWidget);
    expect(find.text(EamsSyncReminder.laterButtonLabel), findsOneWidget);
    expect(find.text(EamsSyncReminder.syncNowButtonLabel), findsOneWidget);
    // 尚未确认前不得拉取。
    expect(service.previewCalls, 0);

    final DateTime t1 = DateTime.now();

    // 2) 点「立即同步」→ 落到教务导入页，且自动拉取恰好 1 次。
    await tester.tap(find.text(EamsSyncReminder.syncNowButtonLabel));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(EamsImportPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, '从教务导入课表'), findsOneWidget);
    expect(service.previewCalls, 1);

    // 3) 节流键已写 = 弹窗触发时刻 + 7 天（触发时刻必落在 [t0, t1] 内）。
    final int? written = int.tryParse(
      settings.values[EamsSyncKeys.nextRemindAt] ?? '',
    );
    expect(written, isNotNull);
    expect(written, greaterThanOrEqualTo(_msOf(t0)));
    expect(written, lessThanOrEqualTo(_msOf(t1)));

    // 4) 本轮拉取成功已打点：nextRemindAt 之外还写了 lastAt / lastSemesterId，
    //    这样下一次判定 should = false，7 天后才再提醒。
    expect(settings.values[EamsSyncKeys.lastSemesterId], '7');
    expect(int.tryParse(settings.values[EamsSyncKeys.lastAt] ?? ''), isNotNull);
  });

  testWidgets('端到端反向：设置键 enabled=0 → 同一场景不弹、不拉取、不写节流', (
    WidgetTester tester,
  ) async {
    final _FakeSettings settings = _FakeSettings()
      ..values[EamsSyncKeys.enabled] = '0';
    final _FakeTimetable timetable = _FakeTimetable(_semester());
    final _CountingImportService service = _service(timetable, settings);

    await _pumpApp(
      tester,
      settings: settings,
      timetable: timetable,
      service: service,
      credentials: _FakeCredentials(
        saved: const EamsCredentials(username: '20240001', password: 'pw'),
      ),
    );

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(EamsImportPage), findsNothing);
    expect(service.previewCalls, 0);
    expect(settings.values.containsKey(EamsSyncKeys.nextRemindAt), isFalse);
  });

  testWidgets('端到端：点「下次提醒」计一次，7 天内回前台不再弹', (
    WidgetTester tester,
  ) async {
    final _FakeSettings settings = _FakeSettings();
    final _FakeTimetable timetable = _FakeTimetable(_semester());
    final _CountingImportService service = _service(timetable, settings);

    await _pumpApp(
      tester,
      settings: settings,
      timetable: timetable,
      service: service,
    );
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(EamsSyncReminder.laterButtonLabel));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    // 点了「下次提醒」也计一次，且不跳转、不拉取。
    expect(find.byType(EamsImportPage), findsNothing);
    expect(service.previewCalls, 0);
    expect(settings.values[EamsSyncKeys.nextRemindAt], isNotNull);

    // 回前台（同一场景、本学期仍未同步）→ 节流生效，不再弹。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.previewCalls, 0);
  });
}
