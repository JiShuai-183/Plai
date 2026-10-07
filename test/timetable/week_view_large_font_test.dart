import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/data/models/holiday.dart';
import 'package:plai/data/models/period.dart';
import 'package:plai/data/models/semester.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/features/timetable/timetable_providers.dart';
import 'package:plai/features/timetable/timetable_settings_keys.dart';
import 'package:plai/features/timetable/week_view.dart';

/// 回归防线：周视图在放大的系统字体下不得自身溢出（黄黑条纹）。
///
/// 这曾是既有缺陷：表头日期格是非空的 Column（「周几」+「日期」两行），表头
/// 高度固定 46（含 1px 底边线 → 内容区 45）。1.5× 字号下两行各约 24px、合计
/// 48px → 超出 3.0px（2026-10-07 跨模块联调由 plai-review 侧实测报出，实测
/// 溢出原文「A RenderFlex overflowed by 3.0 pixels on the bottom」）。大字体
/// 下「周几」还可能折成两行把溢出放大到 ~30px。修复见 week_view._buildDayHeader。
///
/// 默认字号与常见手机宽度下不触发任何缩放（FittedBox/Flexible 均为 no-op），
/// 视觉零变化。

/// 内存版设置仓库：只实现本用例需要的 [getAll]，其余抛未实现。
class _FakeSettings implements ISettingsRepository {
  _FakeSettings(this._values);

  final Map<String, String> _values;

  @override
  Future<Map<String, String>> getAll() async => _values;

  @override
  Future<String?> getValue(String key) async => _values[key];

  @override
  Future<void> setValue(String key, String value) async =>
      throw UnimplementedError();

  @override
  Future<void> setAll(Map<String, String> entries) async =>
      throw UnimplementedError();

  @override
  Future<void> remove(String key) async => throw UnimplementedError();
}

/// 开学日固定在 9 月，保证当前周落在学期内、日期列有内容。
Semester _semester() => Semester(
      name: '2026 秋',
      startDate: DateTime(2026, 9, 1),
      totalWeeks: 16,
    );

/// 12 节，每节都带起止时间（复现「节次栏三行」）。
List<Period> _periods() => <Period>[
      for (int i = 1; i <= 12; i++)
        Period(index: i, startTime: '08:00', endTime: '08:45'),
    ];

/// 前 [dayCount] 天各排一门课（周次/星期固定），其余天为空。
///
/// [dayCount] = 1 时该天列变宽、日期格不再被列宽压扁 → 复现最初的 3px 溢出。
List<Course> _courses(int dayCount) => <Course>[
      for (int d = 1; d <= dayCount; d++)
        Course(
          id: d,
          semesterId: 1,
          name: '高等数学$d',
          location: 'A101',
          color: '#2196F3',
          startWeek: 1,
          endWeek: 16,
          weekday: d,
          startPeriod: 1,
          endPeriod: 2,
        ),
    ];

Future<void> _pumpWeekView(
  WidgetTester tester, {
  Map<String, String> settings = const <String, String>{},
  int courseDays = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(_FakeSettings(settings)),
        coursesProvider.overrideWith((ref) => _courses(courseDays)),
        periodsProvider.overrideWith((ref) => _periods()),
        holidaysProvider.overrideWith((ref) => const <Holiday>[]),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeekView(semester: _semester())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 卸载以取消 WeekView 的 Timer.periodic，避免收尾报 pending timer。
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

/// 设定窄屏 + 系统大字体。
void _useNarrowLargeFont(WidgetTester tester, double scale) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  // 这一档（1.5× + 仅一天有课 → 日期列宽）正是联调实测的 3.0px 溢出场景。
  testWidgets('窄屏 + 1.5x 大字体 + 单天有课（开关开）：表头不溢出', (
    WidgetTester tester,
  ) async {
    _useNarrowLargeFont(tester, 1.5);

    await _pumpWeekView(tester, courseDays: 1);

    expect(find.text('第1节'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('窄屏 + 1.5x 大字体 + 单天有课（开关关）：表头不溢出', (
    WidgetTester tester,
  ) async {
    _useNarrowLargeFont(tester, 1.5);

    await _pumpWeekView(
      tester,
      settings: <String, String>{
        TimetableSettingsKeys.weekViewPeriodTime: 'false',
      },
      courseDays: 1,
    );

    expect(find.text('第1节'), findsOneWidget);
    expect(find.text('08:00'), findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  // 2.0×：「周几」在窄列下会折行、空天竖排两字也变高，溢出更明显。
  testWidgets('窄屏 + 2.0x 大字体 + 每天有课（开关开）：表头不溢出', (
    WidgetTester tester,
  ) async {
    _useNarrowLargeFont(tester, 2.0);

    await _pumpWeekView(tester, courseDays: 7);

    expect(find.text('第1节'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('窄屏 + 2.0x 大字体 + 单天有课（含竖排空天表头）：不溢出', (
    WidgetTester tester,
  ) async {
    _useNarrowLargeFont(tester, 2.0);

    await _pumpWeekView(tester, courseDays: 1);

    expect(find.text('第1节'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
}
