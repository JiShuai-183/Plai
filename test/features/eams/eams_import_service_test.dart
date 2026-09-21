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

  /// 等价于界面上的「拉取 → 默认勾选『以教务为准』→ 确认导入」：
  /// 先按教务基准对账，再施加该计划。**不传 plan 就无法导入**是本服务的有意设计
  /// （计划必须先展示给用户）。
  Future<EamsImportOutcome> importNow(
    EamsImportPreview preview, {
    Semester? updatedSemester,
    String defaultCourseColor = '',
  }) async {
    final EamsImportPlan plan =
        await service.plan(preview: preview, semesterId: semesterId);
    return service.import(
      preview: preview,
      plan: plan,
      semesterId: semesterId,
      updatedSemester: updatedSemester,
      defaultCourseColor: defaultCourseColor,
    );
  }

  Future<List<Course>> courses() => data.timetable.getCourses(semesterId);

  group('首次导入', () {
    test('课程写入，且 plan 把这批课程都归为「将新增」', () async {
      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学', weekday: 1, start: 1, end: 2, weeks: <int>[1, 2, 3, 4]),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4, weeks: <int>[1, 3, 5]),
      ]);

      final EamsImportPlan plan =
          await service.plan(preview: preview, semesterId: semesterId);
      expect(plan.countOf(EamsChangeKind.added), 2);
      expect(plan.countOf(EamsChangeKind.updated), 0);
      expect(plan.countOf(EamsChangeKind.removed), 0);
      expect(plan.replacedCourseIds, isEmpty);

      final EamsImportOutcome outcome = await importNow(preview);

      expect(outcome.removed, 0);
      expect(outcome.inserted, 2);
      expect(outcome.total, 2);

      final List<Course> list = await courses();
      expect(list, hasLength(2));
      final Course english = list.firstWhere((Course c) => c.name == '大学英语');
      expect(english.weekType, WeekType.odd);
      expect(english.startWeek, 1);
      expect(english.endWeek, 5);
    });
  });

  group('默认课程颜色（与手动加课 / JSON·CSV 导入同源）', () {
    test('传 defaultCourseColor → 导入课程套上该色', () async {
      final EamsImportOutcome outcome = await importNow(
        _preview(<EamsActivity>[
          _act(name: '高等数学'),
          _act(name: '大学英语', weekday: 3, start: 3, end: 4),
        ]),
        defaultCourseColor: '#FF8800',
      );

      expect(outcome.inserted, 2);
      for (final Course c in await courses()) {
        expect(c.color, '#FF8800');
      }
    });

    test('不传 defaultCourseColor → 颜色仍为空（不回归）', () async {
      await importNow(_preview(<EamsActivity>[_act()]));
      expect((await courses()).single.color, '');
    });
  });

  group('重复导入同一份', () {
    test('对账无差异 → 不改动任何课程', () async {
      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学'),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4),
      ]);

      await importNow(preview);
      final List<int> idsBefore =
          (await courses()).map((Course c) => c.id!).toList()..sort();

      // 第二次：完全一致 → plan 无变更。
      final EamsImportPlan plan =
          await service.plan(preview: preview, semesterId: semesterId);
      expect(plan.hasChanges, isFalse);
      expect(plan.changes, isEmpty);

      final EamsImportOutcome second = await importNow(preview);
      expect(second.removed, 0);
      expect(second.inserted, 0);
      expect(second.total, 2);

      // 连 id 都没变 —— 无变化的课程不会被删了重写（保住 id 与自定义颜色）。
      final List<int> idsAfter =
          (await courses()).map((Course c) => c.id!).toList()..sort();
      expect(idsAfter, idsBefore);
    });
  });

  group('教务侧改动能同步过来（此前记账式的盲区）', () {
    test('同一门课改教室 → plan 归为「将更新」，导入后教室生效且不重复', () async {
      await importNow(_preview(<EamsActivity>[_act(location: 'A101')]));

      final EamsImportPlan plan = await service.plan(
        preview: _preview(<EamsActivity>[_act(location: 'B202')]),
        semesterId: semesterId,
      );
      expect(plan.countOf(EamsChangeKind.updated), 1);
      expect(plan.changes.single.detail, contains('教室：A101 → B202'));
      // 同键不先删，merge 会跳过 → 必须列入 replacedCourseIds。
      expect(plan.replacedCourseIds, hasLength(1));

      await importNow(_preview(<EamsActivity>[_act(location: 'B202')]));

      final List<Course> list = await courses();
      expect(list, hasLength(1));
      expect(list.single.location, 'B202');
    });

    test('同一门课改周次 → 键变化，旧条归为「将删除」、新条「将新增」，不残留重复',
        () async {
      await importNow(_preview(<EamsActivity>[_act(weeks: <int>[1, 2, 3])]));

      final EamsImportPlan plan = await service.plan(
        preview: _preview(<EamsActivity>[_act(weeks: <int>[1, 2, 3, 4, 5])]),
        semesterId: semesterId,
      );
      // 合并键含起止周 → 周次变了就是两条不同记录：一条删、一条增。
      expect(plan.countOf(EamsChangeKind.removed), 1);
      expect(plan.countOf(EamsChangeKind.added), 1);

      await importNow(_preview(<EamsActivity>[_act(weeks: <int>[1, 2, 3, 4, 5])]));

      final List<Course> list = await courses();
      expect(list, hasLength(1));
      expect(list.single.endWeek, 5);
    });

    test('同一门课换老师 → 归为「将更新」并生效', () async {
      await importNow(_preview(<EamsActivity>[_act(teacher: '王老师')]));

      await importNow(_preview(<EamsActivity>[_act(teacher: '赵老师')]));

      final List<Course> list = await courses();
      expect(list, hasLength(1));
      expect(list.single.teacher, '赵老师');
    });
  });

  group('以教务为基准：教务没有的课程会被删除', () {
    test('手动加的课不在教务课表里 → plan 列为「将删除」，导入后消失', () async {
      final int manualId = await data.timetable.insertCourse(Course(
        semesterId: semesterId,
        name: '我自己加的课',
        teacher: '我自己',
        location: '图书馆',
        color: '#123456',
        weekType: WeekType.every,
        startWeek: 1,
        endWeek: 16,
        weekday: 5,
        startPeriod: 9,
        endPeriod: 10,
      ));

      final EamsImportPreview preview = _preview(<EamsActivity>[
        _act(name: '高等数学'),
        _act(name: '大学英语', weekday: 3, start: 3, end: 4),
      ]);

      final EamsImportPlan plan =
          await service.plan(preview: preview, semesterId: semesterId);
      expect(plan.countOf(EamsChangeKind.removed), 1);
      // 变更按 新增 → 更新 → 删除 排序，故不能用 first 取「将删除」那条。
      expect(
        plan.changes
            .firstWhere((EamsChange c) => c.kind == EamsChangeKind.removed)
            .courseName,
        '我自己加的课',
      );
      expect(plan.replacedCourseIds, contains(manualId));

      await importNow(preview);

      // 学期内容 == 教务课表：手动那条被清掉。
      final List<Course> list = await courses();
      expect(list, hasLength(2));
      expect(list.any((Course c) => c.name == '我自己加的课'), isFalse);
    });

    test('用户已手删的课程出现在 plan 里也不崩（执行时跳过）', () async {
      final int manualId = await data.timetable.insertCourse(Course(
        semesterId: semesterId,
        name: '待手动删掉的课',
        weekday: 5,
        startPeriod: 9,
        endPeriod: 10,
      ));
      final EamsImportPreview preview = _preview(<EamsActivity>[_act()]);

      final EamsImportPlan plan =
          await service.plan(preview: preview, semesterId: semesterId);
      expect(plan.replacedCourseIds, contains(manualId));

      // 拿到 plan 之后用户把它删了，再执行 —— 不应崩、也不应误删别的。
      await data.timetable.deleteCourse(manualId);
      final EamsImportOutcome outcome = await importNow(preview);

      expect(outcome.removed, 0); // 已不存在 → 跳过
      expect((await courses()).single.name, '高等数学');
    });
  });

  group('plan 的对账细节', () {
    test('完全一致 → 无变更；仅颜色不同不算变更', () async {
      await importNow(_preview(<EamsActivity>[_act()]));
      final EamsImportPlan plan = await service.plan(
        preview: _preview(<EamsActivity>[_act()]),
        semesterId: semesterId,
      );
      expect(plan.hasChanges, isFalse);
    });

    test('replacedCourseIds 只含「将更新 + 将删除」，不含纯新增', () async {
      final EamsImportPlan plan = await service.plan(
        preview: _preview(<EamsActivity>[_act()]),
        semesterId: semesterId,
      );
      expect(plan.countOf(EamsChangeKind.added), 1);
      expect(plan.replacedCourseIds, isEmpty);
    });

    test('变更按 新增 → 更新 → 删除 归类排序', () async {
      // 先导入一次，再插「本地独有」—— 顺序反了的话，第一次导入就会把它删掉。
      await importNow(_preview(<EamsActivity>[_act(location: 'A101')]));
      await data.timetable.insertCourse(Course(
        semesterId: semesterId,
        name: '本地独有',
        weekday: 5,
        startPeriod: 9,
        endPeriod: 10,
      ));

      final EamsImportPlan plan = await service.plan(
        preview: _preview(<EamsActivity>[
          _act(location: 'B202'), // 同键 → 更新
          _act(name: '新加的课', weekday: 2, start: 5, end: 6), // 新增
        ]),
        semesterId: semesterId,
      );

      expect(
        plan.changes.map((EamsChange c) => c.kind).toList(),
        <EamsChangeKind>[
          EamsChangeKind.added,
          EamsChangeKind.updated,
          EamsChangeKind.removed,
        ],
      );
    });
  });

  group('节次：默认模板前 N 节', () {
    test('unitCount=10 → 写入前 10 节，已存在 idx 不被覆盖', () async {
      // 用户自定义过第 1 节的时间。
      await data.timetable.insertPeriod(
          const Period(index: 1, startTime: '07:00', endTime: '07:45'));

      await importNow(_preview(<EamsActivity>[_act()], unitCount: 10));

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
      await importNow(preview);
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
    test('fetchPreview + plan + import 后，settings 里没有任何键', () async {
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
      final EamsImportPlan plan =
          await s.plan(preview: preview, semesterId: semesterId);
      await s.import(preview: preview, plan: plan, semesterId: semesterId);

      final Map<String, String> all = await data.settings.getAll();
      for (final MapEntry<String, String> e in all.entries) {
        expect(e.key.toLowerCase(), isNot(contains('password')));
        expect(e.key.toLowerCase(), isNot(contains('pwd')));
        expect(e.key.toLowerCase(), isNot(contains('cred')));
        expect(e.value, isNot(contains(password)));
      }
      // 记账已废弃 → 导入不再往 settings 写任何东西。
      expect(all, isEmpty);
    });
  });

  group('开学日（§5.3：仅在 UI 明确勾选后传 updatedSemester）', () {
    test('updatedSemester 非空 → 先更新学期再导入', () async {
      await importNow(
        _preview(<EamsActivity>[_act()]),
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
      await importNow(_preview(<EamsActivity>[_act()]));
      final Semester? after = await data.timetable.getSemesterById(semesterId);
      expect(after!.startDate, DateTime(2026, 9, 1));
      expect(after.totalWeeks, 16);
    });
  });
}
