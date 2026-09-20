import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/db/default_periods.dart';
import 'package:plai/data/import_export/timetable_import_export.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/features/timetable/eams/eams_client.dart';
import 'package:plai/features/timetable/eams/eams_import_models.dart';
import 'package:plai/features/timetable/eams/eams_import_service.dart';

import '../../data/test_helpers.dart';

/// 用于免网络的课表响应体（结构精简，等价于解析层单测里的样本片段）。
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

/// 不起网络的假客户端：直接回放给定响应体。
class _FakeEamsClient extends EamsClient {
  _FakeEamsClient(this.html);

  final String html;

  @override
  Future<String> fetchCourseTableHtml({
    required String username,
    required String password,
  }) async =>
      html;
}

EamsActivity _act({
  String name = '高等数学',
  String teacher = '王老师',
  String location = 'A101',
  int weekday = 1,
  int start = 1,
  int end = 2,
  List<int> weeks = const <int>[1, 2, 3, 4],
}) =>
    EamsActivity(
      courseName: name,
      courseCode: 'C.$name',
      teacher: teacher,
      location: location,
      weekday: weekday,
      startPeriod: start,
      endPeriod: end,
      weeks: weeks,
    );

EamsImportPreview _preview(List<EamsActivity> activities, {int unitCount = 10}) =>
    EamsImportPreview.fromTimetable(EamsTimetable(
      year: 2026,
      unitCount: unitCount,
      activities: activities,
    ));

void main() {
  late TestData data;
  late EamsImportService service;
  late int semesterId;

  setUp(() async {
    data = await TestData.create();
    service = EamsImportService(
      timetable: data.timetable,
      settings: data.settings,
      importExport:
          TimetableImportExport(db: data.db, timetable: data.timetable),
      client: _FakeEamsClient(_sampleHtml),
    );
    semesterId = await data.timetable.insertSemester(Semester(
      name: '2026 秋',
      startDate: DateTime(2026, 9, 1),
      totalWeeks: 16,
    ));
  });

  tearDown(() async {
    await data.db.close();
  });

  Future<Set<int>> ledger() async {
    final String? raw =
        await data.settings.getValue(EamsImportService.ledgerKey(semesterId));
    if (raw == null) return <int>{};
    return <int>{for (final dynamic e in jsonDecode(raw)) e as int};
  }

  group('首次导入', () {
    test('课程写入 + 记账键写入', () async {
      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学', weekday: 1, start: 1, end: 2, weeks: <int>[1, 2, 3, 4]),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4, weeks: <int>[1, 3, 5]),
      ]);

      final EamsImportOutcome outcome =
          await service.import(preview: preview, semesterId: semesterId);

      expect(outcome.removed, 0);
      expect(outcome.inserted, 2);
      expect(outcome.total, 2);

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(2));
      final Course english = courses.firstWhere((Course c) => c.name == '大学英语');
      expect(english.weekType, WeekType.odd);
      expect(english.startWeek, 1);
      expect(english.endWeek, 5);

      // 记账 = 本次新增的两条 id。
      expect(await ledger(), courses.map((Course c) => c.id).toSet());
    });
  });

  group('默认课程颜色（与手动加课 / JSON·CSV 导入同源）', () {
    test('传 defaultCourseColor → 导入课程套上该色', () async {
      final EamsImportOutcome outcome = await service.import(
        preview: _preview(<EamsActivity>[
          _act(name: '高等数学'),
          _act(name: '大学英语', weekday: 3, start: 3, end: 4),
        ]),
        semesterId: semesterId,
        defaultCourseColor: '#FF8800',
      );

      expect(outcome.inserted, 2);
      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(2));
      for (final Course c in courses) {
        expect(c.color, '#FF8800');
      }
    });

    test('不传 defaultCourseColor → 颜色仍为空（不回归）', () async {
      await service.import(
        preview: _preview(<EamsActivity>[_act()]),
        semesterId: semesterId,
      );

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses.single.color, '');
    });
  });

  group('重复导入同一份', () {
    test('课程数不变，不产生重复', () async {
      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学'),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4),
      ]);

      await service.import(preview: preview, semesterId: semesterId);
      final EamsImportOutcome second =
          await service.import(preview: preview, semesterId: semesterId);

      // 先清掉上次的 2 条，再写回 2 条。
      expect(second.removed, 2);
      expect(second.inserted, 2);
      expect(second.total, 2);

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(2));
      expect(courses.where((Course c) => c.name == '高等数学'), hasLength(1));
    });
  });

  group('教务侧换教室（记账式优于纯 merge 的关键）', () {
    test('同一门课改教室后重导 → 教室确实更新', () async {
      await service.import(
        preview: _preview(<EamsActivity>[_act(location: 'A101')]),
        semesterId: semesterId,
      );
      // 纯 merge 的去重键不含 location → 不删旧的就会永远看不到新教室。
      await service.import(
        preview: _preview(<EamsActivity>[_act(location: 'B202')]),
        semesterId: semesterId,
      );

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(1));
      expect(courses.single.location, 'B202');
    });

    test('教务侧改周次 → 不残留旧周次的重复课', () async {
      await service.import(
        preview: _preview(<EamsActivity>[_act(weeks: <int>[1, 2, 3])]),
        semesterId: semesterId,
      );
      await service.import(
        preview: _preview(<EamsActivity>[_act(weeks: <int>[1, 2, 3, 4, 5])]),
        semesterId: semesterId,
      );

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(1));
      expect(courses.single.endWeek, 5);
    });
  });

  group('手动课程不被触碰（最关键）', () {
    test('先手工插一条课，导入两次后仍在且字段逐一未变', () async {
      final Course manual = Course(
        semesterId: semesterId,
        name: '手动加的课',
        teacher: '我自己',
        location: '图书馆',
        color: '#123456',
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 16,
        weekday: 5,
        startPeriod: 9,
        endPeriod: 10,
      );
      final int manualId = await data.timetable.insertCourse(manual);

      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学'),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4),
      ]);
      await service.import(preview: preview, semesterId: semesterId);
      await service.import(preview: preview, semesterId: semesterId);

      final Course? after = await data.timetable.getCourseById(manualId);
      expect(after, isNotNull);
      expect(after, manual.copyWith(id: manualId));
      // 手动课未进记账。
      expect(await ledger(), isNot(contains(manualId)));
      // 总数 = 2 导入 + 1 手动。
      expect(await data.timetable.getCourses(semesterId), hasLength(3));
    });
  });

  group('记账含过期 id（用户已手删）', () {
    test('再导入不崩、不误删手动课', () async {
      final Course manual = Course(
        semesterId: semesterId,
        name: '手动加的课',
        weekday: 5,
        startPeriod: 9,
        endPeriod: 10,
      );
      final int manualId = await data.timetable.insertCourse(manual);

      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学'),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4),
      ]);
      await service.import(preview: preview, semesterId: semesterId);

      final List<Course> imported = await data.timetable.getCourses(semesterId);
      final int deletedId =
          imported.firstWhere((Course c) => c.name == '高等数学').id!;
      final int survivingId =
          imported.firstWhere((Course c) => c.name == '大学英语').id!;
      // 用户手删了一条导入课。
      await data.timetable.deleteCourse(deletedId);
      // 记账里此刻是 [deletedId, survivingId]；再塞一个根本不存在的 id。
      await data.settings.setValue(EamsImportService.ledgerKey(semesterId),
          jsonEncode(<int>[deletedId, survivingId, 999999]));

      final EamsImportOutcome outcome =
          await service.import(preview: preview, semesterId: semesterId);

      // 只删掉真正还在的那一条（deletedId / 999999 跳过）。
      expect(outcome.removed, 1);
      expect(outcome.inserted, 2);
      expect(outcome.total, 3); // 2 导入 + 1 手动
      expect(await data.timetable.getCourseById(manualId), isNotNull);
      expect(await ledger(), isNot(contains(999999)));
    });

    test('记账值损坏（非 JSON）→ 当作空集合，不崩', () async {
      await data.settings
          .setValue(EamsImportService.ledgerKey(semesterId), 'not json');
      final EamsImportOutcome outcome = await service.import(
        preview: _preview(<EamsActivity>[_act()]),
        semesterId: semesterId,
      );
      expect(outcome.inserted, 1);
    });
  });

  group('节次：默认模板前 N 节', () {
    test('unitCount=10 → 写入前 10 节，已存在 idx 不被覆盖', () async {
      // 用户自定义过第 1 节的时间。
      await data.timetable.insertPeriod(
          const Period(index: 1, startTime: '07:00', endTime: '07:45'));

      await service.import(
        preview: _preview(<EamsActivity>[_act()], unitCount: 10),
        semesterId: semesterId,
      );

      final List<Period> periods = await data.timetable.getPeriods();
      expect(periods, hasLength(10));
      expect(periods.first.index, 1);
      // 用户自定义保留（merge 跳过已存在 idx）。
      expect(periods.first.startTime, '07:00');
      expect(periods.first.endTime, '07:45');
      // 其余为默认模板值。
      final Period p2 = periods.firstWhere((Period p) => p.index == 2);
      expect(p2.startTime, defaultPeriods[1].startTime);
      expect(p2.endTime, defaultPeriods[1].endTime);
    });

    test('unitCount 超过模板长度 → 取满并产 warning', () async {
      final EamsImportPreview preview =
          _preview(<EamsActivity>[_act()], unitCount: 99);
      await service.import(preview: preview, semesterId: semesterId);
      expect(await data.timetable.getPeriods(),
          hasLength(defaultPeriods.length));
    });
  });

  group('fetchPreview（拉取 + 解析，不写库）', () {
    test('真样本 fixture → 统计量与解析层一致，且不写库', () async {
      final EamsImportService fixtureService = EamsImportService(
        timetable: data.timetable,
        settings: data.settings,
        importExport:
            TimetableImportExport(db: data.db, timetable: data.timetable),
        client: _FakeEamsClient(
            File('test/features/eams/fixtures/course_table_sample.html')
                .readAsStringSync()),
      );

      final EamsImportPreview preview = await fixtureService.fetchPreview(
          username: '20240001', password: 'SuperSecret123');

      expect(preview.entryCount, 31);
      expect(preview.courseCount, 14);
      expect(preview.minWeek, 1);
      expect(preview.maxWeek, 18);
      // 解析层无告警，节次 10 ≤ 模板 12 → 不追加告警。
      expect(preview.warnings, isEmpty);

      // 不写库。
      expect(await data.timetable.getCourses(semesterId), isEmpty);
      expect(await data.timetable.getPeriods(), isEmpty);
    });

    test('unitCount 超模板 → preview 追加节次告警', () async {
      final EamsImportService s = EamsImportService(
        timetable: data.timetable,
        settings: data.settings,
        importExport:
            TimetableImportExport(db: data.db, timetable: data.timetable),
        client: _FakeEamsClient(
            _sampleHtml.replaceFirst('var unitCount = 10;', 'var unitCount = 99;')),
      );
      final EamsImportPreview preview =
          await s.fetchPreview(username: 'u', password: 'p');
      expect(preview.warnings.where((String w) => w.contains('超过')), hasLength(1));
    });
  });

  group('密码不落盘', () {
    test('fetchPreview + import 后，settings 里没有密码/凭据', () async {
      const String password = 'SuperSecret123';
      final EamsImportService s = EamsImportService(
        timetable: data.timetable,
        settings: data.settings,
        importExport:
            TimetableImportExport(db: data.db, timetable: data.timetable),
        client: _FakeEamsClient(
            File('test/features/eams/fixtures/course_table_sample.html')
                .readAsStringSync()),
      );

      final EamsImportPreview preview =
          await s.fetchPreview(username: '20240001', password: password);
      await s.import(preview: preview, semesterId: semesterId);

      final Map<String, String> all = await data.settings.getAll();
      for (final MapEntry<String, String> e in all.entries) {
        expect(e.key.toLowerCase(), isNot(contains('password')));
        expect(e.key.toLowerCase(), isNot(contains('pwd')));
        expect(e.key.toLowerCase(), isNot(contains('cred')));
        expect(e.value, isNot(contains(password)));
      }
      // 只应存在记账键。
      expect(all.keys, everyElement(contains('eams.imported_ids')));
    });
  });

  group('开学日（§5.3：仅在 UI 明确勾选后传 updatedSemester）', () {
    test('updatedSemester 非空 → 先更新学期再导入', () async {
      await service.import(
        preview: _preview(<EamsActivity>[_act()]),
        semesterId: semesterId,
        updatedSemester: Semester(
          name: '2026 秋',
          startDate: DateTime(2026, 9, 7),
          totalWeeks: 18,
        ),
      );
      final Semester? after = await data.timetable.getSemesterById(semesterId);
      expect(after!.startDate, DateTime(2026, 9, 7));
      expect(after.totalWeeks, 18);
    });

    test('updatedSemester 为空 → 学期不动', () async {
      await service.import(
        preview: _preview(<EamsActivity>[_act()]),
        semesterId: semesterId,
      );
      final Semester? after = await data.timetable.getSemesterById(semesterId);
      expect(after!.startDate, DateTime(2026, 9, 1));
      expect(after.totalWeeks, 16);
    });
  });

  group('撞键课程裁决（findKeyCollisions / replaceCourseIds）', () {
    /// 手工插一条与教务同键的课（模拟「用户在本功能之前自己加的」）。
    Future<int> insertManual({
      String location = '旧教室',
      String teacher = '旧老师',
    }) =>
        data.timetable.insertCourse(Course(
          semesterId: semesterId,
          name: '高等数学',
          teacher: teacher,
          location: location,
          weekType: WeekType.every,
          startWeek: 1,
          endWeek: 4,
          weekday: 1,
          startPeriod: 1,
          endPeriod: 2,
        ));

    test('findKeyCollisions：手动同键课程被列出，并标出教室差异', () async {
      await insertManual();

      final List<EamsKeyCollision> hits = await service.findKeyCollisions(
        preview: _preview(<EamsActivity>[_act(location: 'A101')]),
        semesterId: semesterId,
      );

      expect(hits, hasLength(1));
      expect(hits.single.courseName, '高等数学');
      expect(hits.single.existingLocation, '旧教室');
      expect(hits.single.incomingLocation, 'A101');
      expect(hits.single.hasDifference, isTrue);
    });

    test('findKeyCollisions：已记账的课程不算撞键（它们会被删掉重导）', () async {
      await service.import(
        preview: _preview(<EamsActivity>[_act(location: 'A101')]),
        semesterId: semesterId,
      );

      final List<EamsKeyCollision> hits = await service.findKeyCollisions(
        preview: _preview(<EamsActivity>[_act(location: 'B202')]),
        semesterId: semesterId,
      );

      expect(hits, isEmpty);
    });

    test('findKeyCollisions：键不同的现有课程不算撞键', () async {
      await insertManual();
      // 教务侧换到星期三 → 键不同。
      final List<EamsKeyCollision> hits = await service.findKeyCollisions(
        preview: _preview(<EamsActivity>[_act(weekday: 3)]),
        semesterId: semesterId,
      );
      expect(hits, isEmpty);
    });

    test('默认不传 replaceCourseIds → 撞键课程原样保留（不回归）', () async {
      await insertManual();

      await service.import(
        preview: _preview(<EamsActivity>[_act(location: 'A101')]),
        semesterId: semesterId,
      );

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(1));
      expect(courses.single.location, '旧教室'); // 未被教务侧覆盖
    });

    test('replaceCourseIds 传入 → 该课程被教务版本覆盖（教室更新）', () async {
      final int manualId = await insertManual();
      final EamsImportPreview preview =
          _preview(<EamsActivity>[_act(location: 'A101')]);

      // 先按 UI 的流程拿到撞键清单，再把它作为「以教务为准」传回。
      final List<EamsKeyCollision> hits = await service.findKeyCollisions(
        preview: preview,
        semesterId: semesterId,
      );
      expect(hits.single.existingCourseId, manualId);

      await service.import(
        preview: preview,
        semesterId: semesterId,
        replaceCourseIds: <int>{manualId},
      );

      final List<Course> courses = await data.timetable.getCourses(semesterId);
      expect(courses, hasLength(1));
      expect(courses.single.location, 'A101');
    });
  });
}
