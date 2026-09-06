import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/ai/ai_timetable_scan.dart';

/// S9 课表识别：模型输出解析与草稿清洗。
void main() {
  group('parseCoursesFromOcrJson', () {
    test('正常 JSON 解析出课程数组', () {
      const String raw =
          '{"courses":[{"name":"高等数学","weekday":1,"start_period":1,'
          '"end_period":2,"start_week":1,"end_week":16,"week_type":"every",'
          '"location":"教一101","teacher":"张三"}]}';
      final List<Map<String, dynamic>> out = parseCoursesFromOcrJson(raw);
      expect(out, hasLength(1));
      expect(out.single['name'], '高等数学');
    });

    test('markdown 代码块包裹也能解析', () {
      const String raw =
          '```json\n{"courses":[{"name":"英语","weekday":3,"start_period":3}]}'
          '\n```';
      final List<Map<String, dynamic>> out = parseCoursesFromOcrJson(raw);
      expect(out, hasLength(1));
      expect(out.single['name'], '英语');
    });

    test('非 JSON 输出返回空数组（不抛异常）', () {
      expect(parseCoursesFromOcrJson('抱歉我看不懂这张图'), isEmpty);
      expect(parseCoursesFromOcrJson(''), isEmpty);
    });

    test('缺 courses 字段返回空数组', () {
      expect(parseCoursesFromOcrJson('{"result":[]}'), isEmpty);
    });
  });

  group('normalizeCourseDrafts', () {
    test('缺失周次兜底：start_week=1，end_week=学期总周数', () {
      final List<Map<String, dynamic>> out = normalizeCourseDrafts(
        <Map<String, dynamic>>[
          <String, dynamic>{'name': '高数', 'weekday': 1, 'start_period': 1},
        ],
        totalWeeks: 16,
      );
      expect(out.single['start_week'], 1);
      expect(out.single['end_week'], 16);
      expect(out.single['week_type'], 'every');
      expect(out.single['end_period'], 1); // 缺 end_period 退回 start
    });

    test('end_period 小于 start_period 时修正为 start_period', () {
      final List<Map<String, dynamic>> out = normalizeCourseDrafts(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '高数',
            'weekday': 2,
            'start_period': 3,
            'end_period': 2,
          },
        ],
        totalWeeks: 16,
      );
      expect(out.single['end_period'], 3);
    });

    test('无效条目丢弃（无名称/weekday 越界/缺节次）', () {
      final List<Map<String, dynamic>> out = normalizeCourseDrafts(
        <Map<String, dynamic>>[
          <String, dynamic>{'weekday': 1, 'start_period': 1}, // 无名称
          <String, dynamic>{'name': 'x', 'weekday': 9, 'start_period': 1}, // 周越界
          <String, dynamic>{'name': 'y', 'weekday': 2}, // 缺节次
          <String, dynamic>{'name': '体育', 'weekday': 5, 'start_period': 6}, // 有效
        ],
        totalWeeks: 16,
      );
      expect(out, hasLength(1));
      expect(out.single['name'], '体育');
    });

    test('week_type 中文归一（单周/双周）', () {
      final List<Map<String, dynamic>> out = normalizeCourseDrafts(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'a',
            'weekday': 1,
            'start_period': 1,
            'week_type': '单周',
          },
          <String, dynamic>{
            'name': 'b',
            'weekday': 2,
            'start_period': 1,
            'week_type': '双周',
          },
        ],
        totalWeeks: 16,
      );
      expect(out[0]['week_type'], 'odd');
      expect(out[1]['week_type'], 'even');
    });
  });
}
