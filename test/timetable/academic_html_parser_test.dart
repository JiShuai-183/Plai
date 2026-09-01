import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/features/timetable/academic_html_parser.dart';

/// 构造含单门课（rowspan=2 覆盖第 1-2 节）的教务 HTML。
String _singleCourseHtml({
  String name = '高等数学        (26271.MATH001.001)',
  String teacher = '(张老师)',
  String week = '(1-16  05A101(龙子湖校区))',
  int weekdayCol = 0,
  bool withPeriods = false,
}) {
  final List<String> cols = List<String>.generate(7, (i) {
    if (i == weekdayCol) {
      return '<td rowspan="2" style="...">'
          '$name<br style="mso-data-placement: same-cell">'
          '$teacher<br style="mso-data-placement: same-cell">'
          '$week</td>';
    }
    return '<td rowspan="2"></td>';
  });
  final String periodSection = withPeriods
      ? '''
    <table>
      <tr><td colspan="8">各校区作息时间说明:</td></tr>
      <tr>
        <td rowspan="2">龙子湖校区</td>
        <td>第一节     08:00~
    08:45</td>
        <td>第二节     08:55~
    09:40</td>
        <td>第三节     10:00~
    10:45</td>
        <td>第四节     10:55~
    11:40</td>
        <td>第五节     14:30~
    15:15</td>
        <td>第六节     15:25~
    16:10</td>
        <td>第七节     16:30~
    17:15</td>
      </tr><tr>
        <td>第八节     17:25~
    18:10</td>
        <td>第九节     19:30~
    20:15</td>
        <td>第十节     20:25~
    21:10</td>
        <td></td><td></td><td></td><td></td>
      </tr>
    </table>'''
      : '';

  return '''
<html><body>
    <table>
        <tr><td colspan="8" style="font-weight:bold;text-align:center;">2026-2027学年第一学期</td></tr>
    </table>
    <table id="manualArrangeCourseTable" align="center">
        <thead>
            <tr>
                <th>节次/周次</th>
                <th>星期一</th><th>星期二</th><th>星期三</th>
                <th>星期四</th><th>星期五</th><th>星期六</th><th>星期日</th>
            </tr>
        </thead>
        <tr>
            <td>第一节</td>
            ${cols.join('\n')}
        </tr>
        <tr>
            <td>第二节</td>
        </tr>
    </table>
    $periodSection
</body></html>''';
}

/// 构造含 3-4 节课的教务 HTML（跨多行测试 rowspan 推进）。
String _multiRowHtml() {
  return '''
<html><body>
    <table id="manualArrangeCourseTable">
        <thead>
            <tr>
                <th>节次/周次</th>
                <th>星期一</th><th>星期二</th><th>星期三</th>
                <th>星期四</th><th>星期五</th><th>星期六</th><th>星期日</th>
            </tr>
        </thead>
        <tr>
            <td>第一节</td>
            <td rowspan="2">课程A<br style="mso-data-placement: same-cell">(赵老师)<br style="mso-data-placement: same-cell">(1-2  01A(龙子湖校区))</td>
            <td rowspan="4">课程D<br style="mso-data-placement: same-cell">(钱老师)<br style="mso-data-placement: same-cell">(1-4  04D(龙子湖校区))</td>
            <td rowspan="2"></td>
            <td rowspan="2"></td>
            <td rowspan="2"></td>
            <td></td>
            <td rowspan="2">课程G<br style="mso-data-placement: same-cell">(孙老师)<br style="mso-data-placement: same-cell">(1-2  07G(龙子湖校区))</td>
        </tr>
        <tr>
            <td>第二节</td>
            <td></td>
        </tr>
        <tr>
            <td>第三节</td>
            <td rowspan="2">课程B<br style="mso-data-placement: same-cell">(李老师)<br style="mso-data-placement: same-cell">(3-4  02B(龙子湖校区))</td>
            <td rowspan="2"></td>
            <td rowspan="2"></td>
            <td rowspan="2"></td>
            <td rowspan="2"></td>
            <td rowspan="2">课程E<br style="mso-data-placement: same-cell">(周老师)<br style="mso-data-placement: same-cell">(3-4  05E(龙子湖校区))</td>
        </tr>
        <tr>
            <td>第四节</td>
        </tr>
    </table>
</body></html>''';
}

void main() {
  group('parseAcademicTimetableHtml 基础', () {
    test('学期名从含「学年」单元格提取', () {
      final data = parseAcademicTimetableHtml(_singleCourseHtml());
      expect(data.semesterName, '2026-2027学年第一学期');
    });

    test('找不到学期名返回空串', () {
      final html = _singleCourseHtml().replaceAll('2026-2027学年第一学期', '课表标题');
      final data = parseAcademicTimetableHtml(html);
      expect(data.semesterName, '');
    });

    test('缺主课表抛 FormatException', () {
      expect(
        () => parseAcademicTimetableHtml('<html><body><table>无主课表</table></body></html>'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('课程字段', () {
    test('rowspan=2 覆盖第 1-2 节：name/teacher/weekday/节次/location', () {
      final data = parseAcademicTimetableHtml(
        _singleCourseHtml(
          name: '高等数学        (26271.MATH001.001)',
          teacher: '(张老师)',
          week: '(1-16  05A101(龙子湖校区))',
          weekdayCol: 0,
        ),
      );
      expect(data.courses, hasLength(1));
      final Course c = data.courses.first;
      expect(c.name, '高等数学');
      expect(c.teacher, '张老师');
      expect(c.weekday, 1);
      expect(c.startPeriod, 1);
      expect(c.endPeriod, 2);
      expect(c.location, '05A101');
      expect(c.color, '');
    });

    test('课程名去掉半角代码括号，保留全角括号', () {
      final data = parseAcademicTimetableHtml(
        _singleCourseHtml(
          name: '大学英语I（三）        (26271.GB003D.056)',
          week: '(1-16  05B102(龙子湖校区))',
        ),
      );
      expect(data.courses.single.name, '大学英语I（三）');
    });

    test('同 td 多块拆多门课', () {
      final html = _singleCourseHtml().replaceFirst(
        '高等数学        (26271.MATH001.001)'
            '<br style="mso-data-placement: same-cell">'
            '(张老师)<br style="mso-data-placement: same-cell">'
            '(1-16  05A101(龙子湖校区))',
        '工程训练A        (26271.9600901A.016)'
            '<br style="mso-data-placement: same-cell">'
            '(王影)<br style="mso-data-placement: same-cell">'
            '(4-7  )'
            '<br style="mso-data-placement: same-cell">'
            '理论力学        (26271.FB201A.003)'
            '<br style="mso-data-placement: same-cell">'
            '(姬振华)<br style="mso-data-placement: same-cell">'
            '(1-3,8-16  07C105(龙子湖校区))',
      );
      final data = parseAcademicTimetableHtml(html);
      expect(data.courses, hasLength(2));
      expect(data.courses[0].name, '工程训练A');
      expect(data.courses[0].teacher, '王影');
      expect(data.courses[0].weekType, WeekType.every);
      expect(data.courses[0].startWeek, 4);
      expect(data.courses[0].endWeek, 7);
      expect(data.courses[0].location, '');
      expect(data.courses[1].name, '理论力学');
      expect(data.courses[1].teacher, '姬振华');
      expect(data.courses[1].weekType, WeekType.custom);
      expect(data.courses[1].weekList, [1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
      expect(data.courses[1].location, '07C105');
    });

    test('教室去校区后缀且保留内部括号', () {
      final data = parseAcademicTimetableHtml(
        _singleCourseHtml(
          name: '机械工程材料        (26271.FB424A.003)',
          week: '(7  08A202(硬度实验室)(龙子湖校区))',
        ),
      );
      expect(data.courses.single.weekType, WeekType.custom);
      expect(data.courses.single.weekList, [7]);
      expect(data.courses.single.startWeek, 7);
      expect(data.courses.single.endWeek, 7);
      expect(data.courses.single.location, '08A202(硬度实验室)');
    });

    test('听力教室保留内部括号', () {
      final data = parseAcademicTimetableHtml(
        _singleCourseHtml(week: '(1-16  02A502(听力)(龙子湖校区))'),
      );
      expect(data.courses.single.location, '02A502(听力)');
    });

    test('无教室周次行为空 location', () {
      final data =
          parseAcademicTimetableHtml(_singleCourseHtml(week: '(4-7  )'));
      expect(data.courses.single.location, '');
      expect(data.courses.single.weekType, WeekType.every);
      expect(data.courses.single.startWeek, 4);
      expect(data.courses.single.endWeek, 7);
      expect(data.courses.single.weekList, isEmpty);
    });
  });

  group('周次类型', () {
    test('(4-7) → every 4-7', () {
      final c =
          parseAcademicTimetableHtml(_singleCourseHtml(week: '(4-7  )'))
              .courses
              .single;
      expect(c.weekType, WeekType.every);
      expect(c.startWeek, 4);
      expect(c.endWeek, 7);
      expect(c.weekList, isEmpty);
    });

    test('(1-3,8-16) → custom 全量展开', () {
      final c = parseAcademicTimetableHtml(
              _singleCourseHtml(week: '(1-3,8-16  07C105)'))
          .courses
          .single;
      expect(c.weekType, WeekType.custom);
      expect(c.weekList, [1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
      expect(c.startWeek, 1);
      expect(c.endWeek, 16);
    });

    test('(2,8-12双) → custom 偶数过滤', () {
      final c = parseAcademicTimetableHtml(
              _singleCourseHtml(week: '(2,8-12双  05B102)'))
          .courses
          .single;
      expect(c.weekType, WeekType.custom);
      expect(c.weekList, [2, 8, 10, 12]);
    });

    test('(1-3单,9-15单,16-18) → custom 段级奇偶', () {
      final c = parseAcademicTimetableHtml(
              _singleCourseHtml(week: '(1-3单,9-15单,16-18  02A502(听力)(龙子湖校区))'))
          .courses
          .single;
      expect(c.weekType, WeekType.custom);
      expect(c.weekList, [1, 3, 9, 11, 13, 15, 16, 17, 18]);
      expect(c.location, '02A502(听力)');
    });

    test('(2-18双) → even 2-18', () {
      final c = parseAcademicTimetableHtml(_singleCourseHtml(week: '(2-18双)'))
          .courses
          .single;
      expect(c.weekType, WeekType.even);
      expect(c.startWeek, 2);
      expect(c.endWeek, 18);
      expect(c.weekList, isEmpty);
    });

    test('(1-3单) → odd 1-3', () {
      final c = parseAcademicTimetableHtml(_singleCourseHtml(week: '(1-3单)'))
          .courses
          .single;
      expect(c.weekType, WeekType.odd);
      expect(c.startWeek, 1);
      expect(c.endWeek, 3);
      expect(c.weekList, isEmpty);
    });

    test('(8-10双) → even 8-10', () {
      final c = parseAcademicTimetableHtml(_singleCourseHtml(week: '(8-10双  07B106)'))
          .courses
          .single;
      expect(c.weekType, WeekType.even);
      expect(c.startWeek, 8);
      expect(c.endWeek, 10);
      expect(c.weekList, isEmpty);
    });
  });

  group('rowspan 多行推进', () {
    test('跨行占用 + 周次区间正确', () {
      final data = parseAcademicTimetableHtml(_multiRowHtml());
      Course byName(String n) => data.courses.firstWhere((c) => c.name == n);
      // rowspan=2 → 1-2 节；rowspan=4 → 1-4 节。
      expect(byName('课程A').startPeriod, 1);
      expect(byName('课程A').endPeriod, 2);
      expect(byName('课程A').weekday, 1);
      expect(byName('课程D').startPeriod, 1);
      expect(byName('课程D').endPeriod, 4);
      expect(byName('课程D').weekday, 2);
      expect(byName('课程G').weekday, 7);
      expect(byName('课程G').startPeriod, 1);
      expect(byName('课程G').endPeriod, 2);
      expect(byName('课程B').startPeriod, 3);
      expect(byName('课程B').endPeriod, 4);
      expect(byName('课程B').weekday, 1);
      expect(byName('课程E').weekday, 7);
      expect(byName('课程E').startPeriod, 3);
      expect(byName('课程E').endPeriod, 4);
      expect(data.courses, hasLength(5));
    });
  });

  group('作息表', () {
    test('解析出 10 节且时间补零', () {
      final data =
          parseAcademicTimetableHtml(_singleCourseHtml(withPeriods: true));
      expect(data.periods, hasLength(10));
      expect(data.periods.first.index, 1);
      expect(data.periods.first.startTime, '08:00');
      expect(data.periods.first.endTime, '08:45');
      expect(data.periods.last.index, 10);
      expect(data.periods.last.startTime, '20:25');
      expect(data.periods.last.endTime, '21:10');
    });

    test('无作息说明节次为空列表', () {
      final data = parseAcademicTimetableHtml(_singleCourseHtml());
      expect(data.periods, isEmpty);
    });
  });

  group('严格失败', () {
    test('课程块缺周次抛 FormatException', () {
      final html = _singleCourseHtml(
        name: '坏课        (26271.BAD001.001)',
        week: '没有周次括号',
      );
      // 无括号的行会被当课程名 → 缺少周次 → 抛错。
      expect(
        () => parseAcademicTimetableHtml(html),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
