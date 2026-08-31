import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/main.dart';

void main() {
  testWidgets('骨架：App 可启动，底部导航含三个 Tab', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlaiApp()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.byType(IndexedStack), findsOneWidget);
  });
}
