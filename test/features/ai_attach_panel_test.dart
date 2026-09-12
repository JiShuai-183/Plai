import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plai/features/ai/ai_attach_panel.dart';

/// 「+」面板：功能排渲染、占位提示、相册三态、网格多选与确认回调。
///
/// 相册数据源注入假实现（1x1 PNG 缩略图），覆盖网格渲染与多选链路；
/// photo_manager 生产实现的行为（真实相册权限/缩略图）放真机验收。
/// 1x1 透明 PNG。
final Uint8List kThumb =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlE'
        'QVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

/// 假数据源：首页 [photos] 张照片，第二页空（没有更多）。
class FakeGallerySource implements AiGallerySource {
  FakeGallerySource(
      {this.photos = 2, this.denied = false, this.throwError = false});

  final int photos;
  final bool denied;
  final bool throwError;

  @override
  Future<void> ensurePermission() async {
    if (denied) throw const AiGalleryPermissionException();
    if (throwError) throw StateError('no plugin');
  }

  @override
  Future<List<AiGalleryPhoto>> fetchPage(int page, int size) async {
    if (page > 0) return const <AiGalleryPhoto>[];
    return <AiGalleryPhoto>[
      for (int i = 0; i < photos; i++)
        AiGalleryPhoto(
          id: 'photo_$i',
          loadThumb: () async => kThumb,
          loadOriginPath: () async => '/tmp/photo_$i.jpg',
        ),
    ];
  }
}

void main() {

  Widget harness({
    required VoidCallback onCamera,
    required VoidCallback onGalleryPicker,
    required ValueChanged<List<String>> onAttachPhotos,
    AiGallerySource? source,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => showAiAttachSheet(
                context,
                onCamera: onCamera,
                onGalleryPicker: onGalleryPicker,
                onAttachPhotos: onAttachPhotos,
                source: source,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('面板：功能排 4 卡渲染 + 照片网格显示（假源 2 张）',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: (_) {},
      source: FakeGallerySource(photos: 2),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('相机'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('敬请期待'), findsOneWidget);
    // 网格：两张照片缩略图渲染（MemoryImage 已就绪）。
    expect(find.byType(Image), findsNWidgets(2));
    // 未选中时不出现确认条。
    expect(find.textContaining('添加所选'), findsNothing);
  });

  testWidgets('面板：点相机卡触发回调并收起', (WidgetTester tester) async {
    bool cameraTapped = false;
    await tester.pumpWidget(harness(
      onCamera: () => cameraTapped = true,
      onGalleryPicker: () {},
      onAttachPhotos: (_) {},
      source: FakeGallerySource(),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('相机'));
    await tester.pumpAndSettle();

    expect(cameraTapped, isTrue);
    expect(find.text('敬请期待'), findsNothing); // 面板已收起
  });

  testWidgets('面板：点相册卡触发系统选择器回调', (WidgetTester tester) async {
    bool galleryTapped = false;
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () => galleryTapped = true,
      onAttachPhotos: (_) {},
      source: FakeGallerySource(),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();

    expect(galleryTapped, isTrue);
    expect(find.text('相机'), findsNothing);
  });

  testWidgets('面板：文件卡占位提示（面板收起）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: (_) {},
      source: FakeGallerySource(),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('文件'));
    // 不能用 pumpAndSettle：气泡是 AnimationController 驱动，settle 会把它的
    // 整段动画（恒显 + 淡出）跑完、气泡已自行消失。这里只推进到面板关闭动画
    // 结束（~250ms），此时气泡仍在恒显期。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('发送文件将在后续版本开放'), findsOneWidget);
    expect(find.text('相机'), findsNothing);
    // 气泡无定时器（不像 SnackBar）；推进到动画结束，避免用例结束时仍在跑。
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('面板：敬请期待卡提示（面板收起）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: (_) {},
      source: FakeGallerySource(),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('敬请期待'));
    // 同上一用例：不能用 pumpAndSettle（会把气泡动画跑完）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('该功能即将开放'), findsOneWidget);
    expect(find.text('相机'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('面板：网格照片多选 → 确认回调带所选原图路径',
      (WidgetTester tester) async {
    final List<List<String>> confirmed = <List<String>>[];
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: confirmed.add,
      source: FakeGallerySource(photos: 2),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 点选两张照片（照片单元带专用 key，与功能卡手势区分）。
    await tester.tap(find.byKey(const ValueKey<String>('ai_gallery_photo_photo_0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('ai_gallery_photo_photo_1')));
    await tester.pump();

    expect(find.text('已选 2 张'), findsOneWidget);
    expect(find.text('添加所选（2）'), findsOneWidget);

    await tester.tap(find.text('添加所选（2）'));
    await tester.pumpAndSettle();

    // 面板收起，回调带两张原图路径。
    expect(confirmed, hasLength(1));
    expect(confirmed.single, <String>['/tmp/photo_0.jpg', '/tmp/photo_1.jpg']);
  });

  testWidgets('面板：再次点选取消勾选（多选可反选）', (WidgetTester tester) async {
    final List<List<String>> confirmed = <List<String>>[];
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: confirmed.add,
      source: FakeGallerySource(photos: 2),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('ai_gallery_photo_photo_0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('ai_gallery_photo_photo_0'))); // 反选
    await tester.pump();

    expect(find.textContaining('添加所选'), findsNothing); // 全部取消后无确认条
    expect(confirmed, isEmpty);
  });

  testWidgets('面板：相册无权限容错态（去设置入口）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: (_) {},
      source: FakeGallerySource(denied: true),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('未授权访问相册'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(find.text('相机'), findsOneWidget); // 功能排不受影响
  });

  testWidgets('面板：数据源异常容错态（重试入口）', (WidgetTester tester) async {
    await tester.pumpWidget(harness(
      onCamera: () {},
      onGalleryPicker: () {},
      onAttachPhotos: (_) {},
      source: FakeGallerySource(throwError: true),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法读取相册'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
