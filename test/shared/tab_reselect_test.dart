import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/shared/tab_reselect.dart';

void main() {
  test('tabReselectProvider 初值 0，bump 每次自增', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(tabReselectProvider(kTimetableTabIndex)), 0);

    container.read(tabReselectProvider(kTimetableTabIndex).notifier).bump();
    expect(container.read(tabReselectProvider(kTimetableTabIndex)), 1);

    container.read(tabReselectProvider(kTimetableTabIndex).notifier).bump();
    expect(container.read(tabReselectProvider(kTimetableTabIndex)), 2);
  });

  test('不同 tab 的信号互相独立', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(tabReselectProvider(kTimetableTabIndex).notifier).bump();

    expect(container.read(tabReselectProvider(kTimetableTabIndex)), 1);
    expect(container.read(tabReselectProvider(kTodayTabIndex)), 0);
    expect(container.read(tabReselectProvider(kAiTabIndex)), 0);
  });

  test('listen 能逐次收到每次 bump（连按多次不丢通知）', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    final List<int> seen = <int>[];
    container.listen<int>(
      tabReselectProvider(kTodayTabIndex),
      (int? previous, int next) => seen.add(next),
    );

    final notifier = container.read(
      tabReselectProvider(kTodayTabIndex).notifier,
    );
    notifier.bump();
    notifier.bump();

    expect(seen, <int>[1, 2]);
  });
}
