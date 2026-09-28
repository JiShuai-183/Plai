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

Semester _semester() => Semester(
      name: '2026 秋',
      startDate: DateTime(2026, 9, 1),
      totalWeeks: 16,
    );

/// 两个节次：第 1 节带起止时间，第 2 节起止时间为空串（模拟缺时间导入）。
List<Period> _periods({String start1 = '08:00', String end1 = '08:45'}) =>
    <Period>[
      Period(index: 1, startTime: start1, endTime: end1),
      const Period(index: 2, startTime: '', endTime: ''),
    ];

/// 挂载周视图：全部数据 provider 直接覆盖为内存值，不建库、不发 I/O。
Future<void> _pumpWeekView(
  WidgetTester tester, {
  Map<String, String> settings = const <String, String>{},
  List<Period>? periods,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(_FakeSettings(settings)),
        coursesProvider.overrideWith((ref) => const <Course>[]),
        periodsProvider.overrideWith((ref) => periods ?? _periods()),
        holidaysProvider.overrideWith((ref) => const <Holiday>[]),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: WeekView(semester: _semester()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 卸载以取消 WeekView 的 Timer.periodic，避免收尾报 pending timer。
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

/// 当前树中全部 Text 的非空文本。
List<String> _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text t) => t.data)
    .whereType<String>()
    .toList();

void main() {
  testWidgets('默认（键缺失）→ 节次栏显示该节 startTime / endTime', (
    WidgetTester tester,
  ) async {
    await _pumpWeekView(tester);

    expect(find.text('第1节'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('08:45'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('键为 true → 显示上课时间', (WidgetTester tester) async {
    await _pumpWeekView(
      tester,
      settings: <String, String>{
        TimetableSettingsKeys.weekViewPeriodTime: 'true',
      },
    );

    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('08:45'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('键为 false → 只显示第 N 节，不显示时间', (WidgetTester tester) async {
    await _pumpWeekView(
      tester,
      settings: <String, String>{
        TimetableSettingsKeys.weekViewPeriodTime: 'false',
      },
    );

    expect(find.text('第1节'), findsOneWidget);
    expect(find.text('08:00'), findsNothing);
    expect(find.text('08:45'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('startTime/endTime 为空串 → 只显示节次，不留空行/空文本', (
    WidgetTester tester,
  ) async {
    await _pumpWeekView(tester, periods: _periods(start1: '', end1: ''));

    // 两个节次都只有节次行。
    expect(find.text('第1节'), findsOneWidget);
    expect(find.text('第2节'), findsOneWidget);
    // 无任何空串文本（否则会画出一条空行）。
    expect(_allText(tester).where((String s) => s.trim().isEmpty), isEmpty);

    await _unmount(tester);
  });

  testWidgets('窄屏 + 放大字体 + 开关开：三行不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pumpWeekView(tester);

    expect(find.text('08:00'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _unmount(tester);
  });
}
