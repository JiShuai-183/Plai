import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/ai/ai_task_photos.dart';
import 'package:plai/features/ai/ai_write_confirm_sheet.dart';
import 'package:plai/features/ai/ai_write_tools.dart';

AiWriteConfirmItem _item({
  List<String> source = const ['/new0.png', '/new1.png'],
  List<String> base = const [],
  List<String> selected = const ['new:0', 'new:1'],
  bool needs = false,
}) => AiWriteConfirmItem(
  tool: findAiWriteTool('save_task')!,
  args: {
    'action': base.isEmpty ? 'create' : 'update',
    'task_id': 1,
    'title': '交作业',
    'due_date': '2030-01-02',
    aiTaskPhotoDraftKey: {
      'version': 1,
      'requestId': 'entry1',
      'sourcePaths': source,
      'basePaths': base,
      'selected': selected,
      'needsSelection': needs,
    },
  },
  description: '保存作业',
);

Future<void> _open(
  WidgetTester tester,
  List<AiWriteConfirmItem> items, {
  Future<void> Function(int, Map<String, dynamic>)? persist,
  ValueChanged<List<Map<String, dynamic>?>>? done,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final result = await showAiWriteConfirmSheet(
                context,
                items: items,
                allowLater: true,
                onDraftChanged: persist,
              );
              done?.call(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

FilledButton _execute(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, '执行选中项（1）'));

void main() {
  testWidgets(
    'photo edits persist before later and can be reselected after reopening',
    (tester) async {
      final item = _item();
      final saved = <Map<String, dynamic>>[];
      await _open(tester, [
        item,
      ], persist: (index, args) async => saved.add(args));
      await tester.tap(find.byKey(const ValueKey('ai_photo_select_0_new:0')));
      await tester.pumpAndSettle();
      expect(AiTaskPhotoDraft.fromArgs(saved.single)!.selectedIds, ['new:1']);
      await tester.tap(find.text('稍后确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('ai_photo_select_0_new:0')),
            )
            .value,
        false,
      );
      await tester.tap(find.byKey(const ValueKey('ai_photo_select_0_new:0')));
      await tester.pumpAndSettle();
      expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds, [
        'new:0',
        'new:1',
      ]);
    },
  );

  testWidgets(
    'persistence failure keeps original selection and reports retry',
    (tester) async {
      final item = _item();
      await _open(tester, [
        item,
      ], persist: (_, _) async => throw StateError('disk'));
      await tester.tap(find.byKey(const ValueKey('ai_photo_select_0_new:0')));
      await tester.pumpAndSettle();
      expect(find.text('草稿保存失败，请重试'), findsOneWidget);
      expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds, [
        'new:0',
        'new:1',
      ]);
    },
  );

  testWidgets(
    'ambiguous photo allocation requires explicit choice including none',
    (tester) async {
      final item = _item(selected: [], needs: true);
      await _open(tester, [item]);
      expect(_execute(tester).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('ai_photo_clear_0')));
      await tester.pumpAndSettle();
      expect(_execute(tester).onPressed, isNotNull);
      expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds, isEmpty);
      expect(AiTaskPhotoDraft.fromArgs(item.args)!.needsSelection, false);
      expect(find.text('未附照片'), findsOneWidget);
    },
  );

  testWidgets(
    'overflow is never truncated and deselecting restores execution',
    (tester) async {
      final item = _item(
        base: ['/old.png', '/old1.png', '/old2.png'],
        selected: ['old:0', 'old:1', 'old:2', 'new:0', 'new:1'],
      );
      await _open(tester, [item]);
      expect(find.text('保存后的照片（5/4）'), findsOneWidget);
      expect(_execute(tester).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('ai_photo_select_0_old:0')));
      await tester.pumpAndSettle();
      expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds.length, 4);
      expect(_execute(tester).onPressed, isNotNull);
    },
  );

  testWidgets('busy draft saving blocks execution later and back', (
    tester,
  ) async {
    final gate = Completer<void>();
    final item = _item();
    await _open(tester, [item], persist: (_, _) => gate.future);
    await tester.tap(find.byKey(const ValueKey('ai_photo_clear_0')));
    await tester.pump();
    expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds, [
      'new:0',
      'new:1',
    ]);
    expect(_execute(tester).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '稍后确认'))
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('AI 请求修改数据'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds, isEmpty);
    expect(_execute(tester).onPressed, isNotNull);
  });

  testWidgets(
    'skipping an unresolved photo card allows another valid operation',
    (tester) async {
      await _open(tester, [_item(selected: [], needs: true), _item()]);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '执行选中项（2）'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      expect(_execute(tester).onPressed, isNotNull);
    },
  );

  testWidgets(
    'photo tap opens corresponding local preview without changing selection',
    (tester) async {
      final item = _item();
      await _open(tester, [item]);
      await tester.tap(find.byKey(const ValueKey('ai_photo_view_0_new:1')));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(AiTaskPhotoDraft.fromArgs(item.args)!.selectedIds.length, 2);
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'narrow screen and large text remain scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, [_item()]);
      expect(tester.takeException(), isNull);
      expect(find.text('稍后确认'), findsOneWidget);
    },
  );
}
