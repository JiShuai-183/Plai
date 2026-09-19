import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/features/timetable/eams/eams_import_models.dart';
import 'package:plai/features/timetable/eams/eams_parser.dart';

/// 郑航教务课表解析层单测。
///
/// [fixture] 为**脱敏后的真样本**（`docs/courseTableForStd!courseTable.htm` 剥掉
/// 浏览器插件注入的 `<plasmo-csui>` 节点，学号 / 姓名 / 课程名 / 教师名 / 教室名
/// 替换为等长假值，其余字节原样）。结构、`unitCount`、`year`、0/1 周次串与
/// `index` 行完全一致 —— 因此解析行为与原样本逐位相同（实施期已用未脱敏原始
/// 文件跑同一 parser 复核，两次结果一致：31 条 / 14 门 / unitCount=10 / year=2026）。

const String _fixturePath =
    'test/features/eams/fixtures/course_table_sample.html';

/// 脱敏后的关键串（真值 → 假值见 fixture 生成脚本，此处仅用假值）。
const String kCourseTheoMech = '子课课课'; // 示例课程乙
const String kCourseMarxBasic = '卯课课课课课课课课'; // 示例课程甲
const String kCourseSituation = '己课课课课课课课'; // 示例课程己（3）
const String kCourseMechMat = '癸课课课课课'; // 示例课程丁
const String kTeacherJi = '庚师师'; // 甲老师
const String kTeacherShi = '丁师师'; // 丙老师
const String kTeacherLiu = '乙师师'; // 丁老师
const String kLocTheoMech = '午室室室室室'; // X215

void main() {
  late EamsTimetable table;

  setUpAll(() {
    table = parseEamsCourseTable(File(_fixturePath).readAsStringSync());
  });

  group('真样本（脱敏 fixture）整体解析', () {
    test('年份 / 每天节数 / 活动条数 / 去重课程数', () {
      expect(table.year, 2026);
      expect(table.unitCount, 10);
      expect(table.activities, hasLength(31));
      expect(table.distinctCourseNames, hasLength(14));
    });

    test('真样本无解析告警（含无合并键冲突）', () {
      expect(table.warnings, isEmpty);
    });
  });

  group('逐位对账：0/1 周次串 → 周次集合', () {
    test('示例课程乙 单双周：串里第 10/12/14 位为 0、11/13/15 位为 1', () {
      // 渲染文字为「1-3 8-9 单11-15」。
      final EamsActivity a = table.activities.firstWhere(
        (EamsActivity e) =>
            e.courseName == kCourseTheoMech &&
            e.weekday == 4 &&
            e.startPeriod == 1,
      );
      expect(a.weeks, <int>[1, 2, 3, 8, 9, 11, 13, 15]);
      expect(a.teacher, kTeacherJi);
      expect(a.location, kLocTheoMech);
    });

    test('示例课程甲（周二 1-2 节）：2-3 + 8-15', () {
      final EamsActivity a = table.activities.firstWhere(
        (EamsActivity e) =>
            e.courseName == kCourseMarxBasic &&
            e.weekday == 2 &&
            e.startPeriod == 1,
      );
      expect(a.weeks, <int>[2, 3, 8, 9, 10, 11, 12, 13, 14, 15]);
    });

    test('示例课程己（周六 3-4 节）：7-10', () {
      final EamsActivity a = table.activities.firstWhere(
        (EamsActivity e) =>
            e.courseName == kCourseSituation &&
            e.weekday == 6 &&
            e.startPeriod == 3,
      );
      expect(a.weeks, <int>[7, 8, 9, 10]);
    });

    test('多教师：实验课追加辅导老师，且不重复', () {
      final EamsActivity a = table.activities.firstWhere(
        (EamsActivity e) =>
            e.courseName == kCourseMechMat &&
            e.weekday == 7 &&
            e.startPeriod == 1,
      );
      expect(a.teacher, '$kTeacherShi,$kTeacherLiu');
      expect(a.weeks, <int>[7]);
    });

    test('连续节次合并：示例课程戊 4–7 节并为一条 5-8', () {
      // 真样本「示例课程戊」有 6*unitCount+4..7 四行 → 合并为第 5-8 节。
      final Iterable<EamsActivity> runs = table.activities.where(
          (EamsActivity e) =>
              e.weekday == 6 && e.startPeriod == 5 && e.endPeriod == 8);
      expect(runs, hasLength(1));
    });
  });

  group('周次集合归类（边界锁死）', () {
    test('连续区间（起点任意）→ every', () {
      expect(classifyWeeks(<int>[1, 2, 3, 4, 5, 6]).weekType, WeekType.every);
      expect(classifyWeeks(<int>[1, 2, 3, 4, 5, 6]),
          const WeekClassification(weekType: WeekType.every, startWeek: 1, endWeek: 6));
      expect(classifyWeeks(<int>[5, 6, 7]),
          const WeekClassification(weekType: WeekType.every, startWeek: 5, endWeek: 7));
      expect(classifyWeeks(<int>[8, 9]),
          const WeekClassification(weekType: WeekType.every, startWeek: 8, endWeek: 9));
      expect(classifyWeeks(<int>[3]),
          const WeekClassification(weekType: WeekType.every, startWeek: 3, endWeek: 3));
    });

    test('步长 2 连续的全奇数 → odd', () {
      expect(classifyWeeks(<int>[1, 3, 5]),
          const WeekClassification(weekType: WeekType.odd, startWeek: 1, endWeek: 5));
      expect(classifyWeeks(<int>[11, 13, 15]),
          const WeekClassification(weekType: WeekType.odd, startWeek: 11, endWeek: 15));
      expect(classifyWeeks(<int>[1, 3]).weekType, WeekType.odd);
    });

    test('步长 2 连续的全偶数 → even', () {
      expect(classifyWeeks(<int>[2, 4, 6]),
          const WeekClassification(weekType: WeekType.even, startWeek: 2, endWeek: 6));
      expect(classifyWeeks(<int>[10, 12, 14]),
          const WeekClassification(weekType: WeekType.even, startWeek: 10, endWeek: 14));
    });

    test('其余 → custom（weekList = 完整集合）', () {
      final WeekClassification c =
          classifyWeeks(<int>[1, 2, 3, 8, 9, 11, 13, 15]);
      expect(c.weekType, WeekType.custom);
      expect(c.startWeek, 1);
      expect(c.endWeek, 15);
      expect(c.weekList, <int>[1, 2, 3, 8, 9, 11, 13, 15]);
      // 有洞的连续段也归 custom。
      expect(classifyWeeks(<int>[1, 6, 7]).weekType, WeekType.custom);
    });

    test('输入先排序去重', () {
      expect(classifyWeeks(<int>[3, 1, 1, 2]),
          const WeekClassification(weekType: WeekType.every, startWeek: 1, endWeek: 3));
    });

    test('示例课程乙那条真实周次归 custom 且完整保留', () {
      final EamsActivity a = table.activities.firstWhere((EamsActivity e) =>
          e.courseName == kCourseTheoMech && e.weekday == 4 && e.startPeriod == 1);
      final WeekClassification c = classifyWeeks(a.weeks);
      expect(c.weekType, WeekType.custom);
      expect(c.weekList, a.weeks);
    });
  });

  group('归入 importJson 的 courses 数组', () {
    test('形状为 Course.toJson()，周次归类正确填充', () {
      final EamsActivity a = table.activities.firstWhere((EamsActivity e) =>
          e.courseName == kCourseTheoMech && e.weekday == 4 && e.startPeriod == 1);
      final Map<String, Object?> json = table
          .toCourseJsonList(color: '#112233')
          .firstWhere((Map<String, Object?> m) => m['location'] == a.location
              && m['weekday'] == a.weekday
              && m['startPeriod'] == a.startPeriod);

      expect(json.keys, containsAll(<String>[
        'id', 'semesterId', 'name', 'teacher', 'location', 'color',
        'weekType', 'weekList', 'startWeek', 'endWeek',
        'weekday', 'startPeriod', 'endPeriod',
      ]));
      expect(json['name'], kCourseTheoMech);
      expect(json['teacher'], kTeacherJi);
      expect(json['color'], '#112233');
      expect(json['weekType'], 'custom');
      expect(json['weekList'], <int>[1, 2, 3, 8, 9, 11, 13, 15]);
      expect(json['startWeek'], 1);
      expect(json['endWeek'], 15);
      expect(json['weekday'], 4);
      expect(json['startPeriod'], 1);
      expect(json['endPeriod'], 2);
    });

    test('every 归类不带 weekList', () {
      final Map<String, Object?> json = table.toCourseJsonList().firstWhere(
          (Map<String, Object?> m) => m['weekType'] == 'every');
      expect(json['weekList'], isEmpty);
    });
  });

  group('合并键冲突检测（绝不静默丢课）', () {
    test('两条键相同的课程产出告警', () {
      const String src = '''
var table0 = new CourseTable(2026, 70);
var unitCount = 10;
var actTeachers = [{id:1,name:"A",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"1(X.Y)","C(X.Y)","1","R1","01110000000000000000000000000000000000000000000000000",null,null,null,"","");
index =0*unitCount+0;
table0.activities[index][table0.activities[index].length]=activity;
var actTeachers = [{id:1,name:"A",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"2(X.Y)","C(X.Y)","2","R2","01110000000000000000000000000000000000000000000000000",null,null,null,"","");
index =0*unitCount+0;
table0.activities[index][table0.activities[index].length]=activity;
''';
      final EamsTimetable t = parseEamsCourseTable(src);
      expect(t.activities, hasLength(2));
      // 房间 / 代码不同不影响 merge 去重键 → 必须告警。
      expect(t.warnings.where((String w) => w.contains('合并键冲突')), hasLength(1));
    });

    test('键不同（星期不同）不告警', () {
      const String src = '''
var table0 = new CourseTable(2026, 70);
var unitCount = 10;
var actTeachers = [{id:1,name:"A",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"1(X.Y)","C(X.Y)","1","R1","01110000000000000000000000000000000000000000000000000",null,null,null,"","");
index =0*unitCount+0;
table0.activities[index][table0.activities[index].length]=activity;
var actTeachers = [{id:1,name:"A",lab:false}];
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"1(X.Y)","C(X.Y)","1","R1","01110000000000000000000000000000000000000000000000000",null,null,null,"","");
index =1*unitCount+0;
table0.activities[index][table0.activities[index].length]=activity;
''';
      final EamsTimetable t = parseEamsCourseTable(src);
      expect(t.activities, hasLength(2));
      expect(t.warnings.where((String w) => w.contains('合并键冲突')), isEmpty);
    });
  });

  group('异常输入不崩（返回空结果 + warning）', () {
    test('空串', () {
      final EamsTimetable t = parseEamsCourseTable('');
      expect(t.activities, isEmpty);
      expect(t.warnings, isNotEmpty);
    });

    test('缺 CourseTable', () {
      final EamsTimetable t = parseEamsCourseTable('var unitCount = 10;');
      expect(t.activities, isEmpty);
      expect(t.year, 0);
      expect(t.warnings.single, contains('CourseTable'));
    });

    test('缺 unitCount', () {
      final EamsTimetable t =
          parseEamsCourseTable('var table0 = new CourseTable(2026,70);');
      expect(t.activities, isEmpty);
      expect(t.year, 2026);
      expect(t.unitCount, 0);
      expect(t.warnings.single, contains('unitCount'));
    });

    test('截断（TaskActivity 参数未闭合）', () {
      const String src = '''
var table0 = new CourseTable(2026, 70);
var unitCount = 10;
activity = new TaskActivity(actTeacherId.join(','),actTeacherName.join(','),"1(X.Y)","C(X.Y)","1","R1"
''';
      final EamsTimetable t = parseEamsCourseTable(src);
      expect(t.activities, isEmpty);
      expect(t.year, 2026);
      expect(t.unitCount, 10);
      expect(t.warnings, isNotEmpty);
    });

    test('无任何 TaskActivity', () {
      final EamsTimetable t = parseEamsCourseTable(
          'var table0 = new CourseTable(2026, 70);\nvar unitCount = 10;');
      expect(t.activities, isEmpty);
      expect(t.year, 2026);
      expect(t.unitCount, 10);
      expect(t.warnings.single, contains('TaskActivity'));
    });
  });
}
