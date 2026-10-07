import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/data/repositories/timetable_repository.dart';
import 'package:plai/features/ai/ai_write_tools.dart';
import 'package:plai/features/timetable/color_utils.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/services/notifications/notification_providers.dart';

/// 内存版课表仓库：update_course 颜色用例只用读写课程与重排所需空集，
/// 其余接口经 [noSuchMethod] 抛未实现。
class _FakeTimetableRepo implements ITimetableRepository {
  final Map<int, Course> courses = <int, Course>{};

  void seed(Course course) => courses[course.id!] = course;

  @override
  Future<Course?> getCourseById(int id) async => courses[id];

  @override
  Future<int> updateCourse(Course course) async {
    final int? id = course.id;
    if (id == null || !courses.containsKey(id)) return 0;
    courses[id] = course;
    return 1;
  }

  @override
  Future<List<Course>> getAllCourses() async => courses.values.toList();

  @override
  Future<List<Semester>> getSemesters() async => const <Semester>[];

  @override
  Future<List<Period>> getPeriods() async => const <Period>[];

  @override
  Future<List<Holiday>> getHolidays(
          {int? courseId, DateTime? from, DateTime? to}) async =>
      const <Holiday>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('未实现：${invocation.memberName}');
}

/// 最小设置仓库（避免触真数据库）。
class _FakeSettings implements ISettingsRepository {
  final Map<String, String> _map = <String, String>{};

  @override
  Future<String?> getValue(String key) async => _map[key];

  @override
  Future<void> setValue(String key, String value) async => _map[key] = value;

  @override
  Future<void> setAll(Map<String, String> entries) async => _map.addAll(entries);

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(_map);

  @override
  Future<void> remove(String key) async => _map.remove(key);
}

/// 挂一个 Consumer 取出 [WidgetRef]，供 describe/execute 直接调用。
Future<WidgetRef> _pumpRef(WidgetTester tester, _FakeTimetableRepo repo) async {
  late WidgetRef ref;
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        timetableRepositoryProvider.overrideWithValue(repo),
        settingsRepositoryProvider.overrideWithValue(_FakeSettings()),
        // 重排提醒触发读调度器——测试内直接抛错（execute 已吞异常）。
        notificationSchedulerProvider
            .overrideWith((ref) => throw StateError('test: 无调度器')),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext context, WidgetRef r, Widget? child) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return ref;
}

void main() {
  final AiWriteTool tool = findAiWriteTool('update_course')!;

  group('update_course 颜色 - 色名映射单一来源', () {
    test('色名表的值全部来自 kCourseColorPalette（防色板漂移）', () {
      expect(kCourseColorNames.length, 11);
      for (final MapEntry<String, String> e in kCourseColorNames.entries) {
        expect(
          kCourseColorPalette,
          contains(e.value),
          reason: '色名「${e.key}」的值 ${e.value} 不在公共色板内',
        );
      }
      // 11 个色名与 11 个色板色一一对应，无重复。
      expect(kCourseColorNames.values.toSet().length, kCourseColorPalette.length);
    });
  });

  group('update_course 颜色 - 校验与归一化', () {
    test('接受的三形式均通过校验且归一化正确', () {
      const List<(Object?, String)> cases = <(Object?, String)>[
        ('#FF0000', '#FF0000'),
        ('FF0000', '#FF0000'),
        ('ff0000', '#FF0000'),
        ('  #64b5f6  ', '#64B5F6'),
        ('蓝', '#64B5F6'),
        ('蓝色', '#64B5F6'),
        ('浅蓝色', '#4FC3F7'),
        ('红色', '#E57373'),
        ('无色', ''),
        ('透明', ''),
        ('清除', ''),
        ('   ', ''),
      ];
      for (final (Object? input, String expected) in cases) {
        expect(
          tool.validate(<String, dynamic>{'course_id': 1, 'color': input}),
          isNull,
          reason: '$input 应通过校验',
        );
        expect(parseAiCourseColor(input), expected, reason: '$input 归一化');
      }
    });

    test('非法输入返回明确错误且不可归一化', () {
      const List<Object?> bad = <Object?>[
        '#GGG', '#12345', '#12 45', '深红', '红绿', 123, true,
      ];
      for (final Object? input in bad) {
        final String? err = tool.validate(
          <String, dynamic>{'course_id': 1, 'color': input},
        );
        expect(err, isNotNull, reason: '$input 应被拒绝');
        expect(err, contains('color'), reason: '$input 错误文案应点名 color');
        expect(parseAiCourseColor(input), isNull, reason: '$input 不可归一化');
      }
    });

    test('仅颜色字段也算一次有效修改', () {
      expect(
        tool.validate(<String, dynamic>{'course_id': 1, 'color': '蓝'}),
        isNull,
      );
    });
  });

  group('update_course 颜色 - intentKey', () {
    test('同 course_id、仅颜色不同 → 意图键不同', () {
      final String a = tool.intentKey(
        <String, dynamic>{'course_id': 1, 'color': '蓝'},
      );
      final String b = tool.intentKey(
        <String, dynamic>{'course_id': 1, 'color': '红'},
      );
      expect(a, isNot(b));
      expect(
        a,
        tool.intentKey(<String, dynamic>{'course_id': 1, 'color': '蓝'}),
      );
    });
  });

  group('update_course 颜色 - describe 文案', () {
    testWidgets('色名 / hex / 清除 三种文案可读', (WidgetTester tester) async {
      final _FakeTimetableRepo repo = _FakeTimetableRepo();
      repo.seed(const Course(
        id: 1,
        semesterId: 1,
        name: '高等数学',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        endWeek: 14,
      ));
      final WidgetRef ref = await _pumpRef(tester, repo);

      expect(
        await tool.describe(ref, <String, dynamic>{'course_id': 1, 'color': '蓝色'}),
        contains('颜色：蓝色（#64B5F6）'),
      );
      expect(
        await tool.describe(
            ref, <String, dynamic>{'course_id': 1, 'color': '#123456'}),
        contains('颜色：#123456'),
      );

      repo.seed(const Course(
        id: 2,
        semesterId: 1,
        name: '大学英语',
        weekday: 3,
        startPeriod: 3,
        endPeriod: 4,
        endWeek: 14,
        color: '#E57373',
      ));
      expect(
        await tool.describe(ref, <String, dynamic>{'course_id': 2, 'color': '无色'}),
        contains('清除颜色'),
      );
    });
  });

  group('update_course 颜色 - execute 落库', () {
    testWidgets('传色名 → 写库为大写带 # 的对应色板色值',
        (WidgetTester tester) async {
      final _FakeTimetableRepo repo = _FakeTimetableRepo();
      repo.seed(const Course(
        id: 1,
        semesterId: 1,
        name: '高等数学',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        endWeek: 14,
      ));
      final WidgetRef ref = await _pumpRef(tester, repo);

      await tool.execute(ref, <String, dynamic>{'course_id': 1, 'color': '蓝色'});
      expect((await repo.getCourseById(1))!.color, '#64B5F6');
    });

    testWidgets('传「无色」→ 写库为空串', (WidgetTester tester) async {
      final _FakeTimetableRepo repo = _FakeTimetableRepo();
      repo.seed(const Course(
        id: 1,
        semesterId: 1,
        name: '高等数学',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        endWeek: 14,
        color: '#E57373',
      ));
      final WidgetRef ref = await _pumpRef(tester, repo);

      await tool.execute(ref, <String, dynamic>{'course_id': 1, 'color': '无色'});
      expect((await repo.getCourseById(1))!.color, '');
    });

    testWidgets('未传 color → 保持原色不变', (WidgetTester tester) async {
      final _FakeTimetableRepo repo = _FakeTimetableRepo();
      repo.seed(const Course(
        id: 1,
        semesterId: 1,
        name: '高等数学',
        weekday: 2,
        startPeriod: 1,
        endPeriod: 2,
        endWeek: 14,
        color: '#E57373',
      ));
      final WidgetRef ref = await _pumpRef(tester, repo);

      await tool.execute(
          ref, <String, dynamic>{'course_id': 1, 'location': '教二202'});
      final Course updated = (await repo.getCourseById(1))!;
      expect(updated.color, '#E57373');
      expect(updated.location, '教二202');
    });
  });
}
