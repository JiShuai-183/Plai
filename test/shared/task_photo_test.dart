import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:plai/shared/task_photo_picker.dart';
import 'package:plai/shared/task_photo_prepare.dart';
import 'package:plai/shared/task_photo_viewer.dart';

class _Gallery implements TaskPhotoGallerySource {
  bool denied = false;
  bool brokenPath = false;
  int calls = 0;
  @override
  Future<void> ensurePermission() async {
    if (denied) throw TaskGalleryPermissionException();
  }

  @override
  Future<List<TaskGalleryPhoto>> fetchPage(int page, int size) async {
    calls++;
    return List.generate(
      5,
      (index) => TaskGalleryPhoto(
        id: '$index',
        loadThumb: () async => null,
        loadPath: () async => brokenPath ? null : '/image$index.png',
      ),
    );
  }
}

class _Device implements TaskPhotoDevicePicker {
  List<String> result = [];
  int? limit;
  bool? camera;
  @override
  Future<List<String>> pick({required bool camera, required int limit}) async {
    this.limit = limit;
    this.camera = camera;
    return result;
  }
}

class _ImagePicker extends ImagePicker {
  ImageSource? source;
  int? limit;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    this.source = source;
    return XFile('/single.png');
  }

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async {
    this.limit = limit;
    return [XFile('/multi.png')];
  }
}

Future<void> _open(
  WidgetTester tester,
  _Gallery gallery, {
  int remaining = 2,
  _Device? device,
  ValueChanged<List<String>>? done,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final paths = await showTaskPhotoPicker(
                context,
                remaining: remaining,
                source: gallery,
                devicePicker: device ?? _Device(),
              );
              done?.call(paths);
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

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xffaabbcc),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('production gallery permission channel', () {
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('image grant succeeds without video grant; requests images without location', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'requestPermissionExtend') {
          final permission =
              (call.arguments as Map)['androidPermission'] as Map;
          // Android 13 has IMAGE granted and VIDEO denied: the old common
          // request returns denied, the image-only request succeeds.
          return permission['type'] == RequestType.image.value
              ? PermissionState.authorized.index
              : PermissionState.denied.index;
        }
        if (call.method == 'getAssetPathList') return {'data': []};
        throw StateError('Unexpected platform call: ${call.method}');
      });
      final source = DeviceTaskPhotoGallery();
      await source.ensurePermission();
      expect(await source.fetchPage(0, 60), isEmpty);
      final permission =
          (calls.first.arguments as Map)['androidPermission'] as Map;
      expect(permission, {
        'type': RequestType.image.value,
        'mediaLocation': false,
      });
      expect((calls.last.arguments as Map)['type'], RequestType.image.value);
    });

    test('limited access loads the accessible image collection', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'requestPermissionExtend') {
          return PermissionState.limited.index;
        }
        if (call.method == 'getAssetPathList') {
          return {
            'data': [
              {
                'id': 'limited',
                'name': '可访问照片',
                'isAll': true,
                'assetCount': 1,
              },
            ],
          };
        }
        if (call.method == 'getAssetListPaged') {
          return {
            'data': [
              {'id': 'accessible-photo', 'type': 1, 'width': 120, 'height': 80},
            ],
          };
        }
        throw StateError('Unexpected platform call: ${call.method}');
      });
      final source = DeviceTaskPhotoGallery();
      await source.ensurePermission();
      expect((await source.fetchPage(0, 60)).single.id, 'accessible-photo');
    });

    for (final permission in [
      PermissionState.denied,
      PermissionState.restricted,
    ]) {
      test('${permission.name} is not accepted as photo access', () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestPermissionExtend');
          return permission.index;
        });
        await expectLater(
          DeviceTaskPhotoGallery().ensurePermission(),
          throwsA(isA<TaskGalleryPermissionException>()),
        );
      });
    }

    test(
      'platform permission failure is not mislabeled as a denied state',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'native_error');
        });
        await expectLater(
          DeviceTaskPhotoGallery().ensurePermission(),
          throwsA(isA<PlatformException>()),
        );
      },
    );
  });
  test('system picker uses single selection for one remaining slot', () async {
    final fake = _ImagePicker();
    final picker = SystemTaskPhotoPicker(picker: fake);
    expect(await picker.pick(camera: false, limit: 1), ['/single.png']);
    expect(fake.source, ImageSource.gallery);
    expect(await picker.pick(camera: true, limit: 4), ['/single.png']);
    expect(fake.source, ImageSource.camera);
    expect(await picker.pick(camera: false, limit: 3), ['/multi.png']);
    expect(fake.limit, 3);
  });
  testWidgets(
    'grid limits selection before confirm and returns exact originals',
    (tester) async {
      List<String>? result;
      await _open(tester, _Gallery(), done: (paths) => result = paths);
      await tester.tap(find.byKey(const ValueKey('task_gallery_0')));
      await tester.tap(find.byKey(const ValueKey('task_gallery_1')));
      await tester.tap(find.byKey(const ValueKey('task_gallery_2')));
      await tester.pump();
      expect(find.text('还可选择 0 张'), findsOneWidget);
      expect(find.text('最多还能添加 2 张照片'), findsOneWidget);
      await tester.tap(find.text('添加所选（2）'));
      await tester.pumpAndSettle();
      expect(result, ['/image0.png', '/image1.png']);
    },
  );
  testWidgets('deselect restores remaining allowance', (tester) async {
    await _open(tester, _Gallery(), remaining: 1);
    await tester.tap(find.byKey(const ValueKey('task_gallery_0')));
    await tester.pump();
    expect(find.text('还可选择 0 张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('task_gallery_0')));
    await tester.pump();
    expect(find.text('还可选择 1 张'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '添加所选（0）'),
    );
    expect(button.onPressed, isNull);
  });
  testWidgets(
    'denied gallery retains system picker and can retry after permission',
    (tester) async {
      final gallery = _Gallery()..denied = true;
      final device = _Device()..result = ['/system.png'];
      List<String>? result;
      await _open(
        tester,
        gallery,
        remaining: 1,
        device: device,
        done: (paths) => result = paths,
      );
      expect(find.textContaining('未授权访问相册'), findsOneWidget);
      gallery.denied = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task_gallery_0')), findsOneWidget);
      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      expect(result, ['/system.png']);
      expect(device.limit, 1);
    },
  );
  testWidgets('returning from settings refreshes a previously denied gallery', (
    tester,
  ) async {
    final gallery = _Gallery()..denied = true;
    await _open(tester, gallery);
    expect(find.textContaining('未授权访问相册'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    gallery.denied = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('未授权访问相册'), findsNothing);
    expect(find.byKey(const ValueKey('task_gallery_0')), findsOneWidget);
  });
  testWidgets(
    'unavailable origin does not close sheet or silently drop photo',
    (tester) async {
      await _open(tester, _Gallery()..brokenPath = true);
      await tester.tap(find.byKey(const ValueKey('task_gallery_0')));
      await tester.pump();
      await tester.tap(find.text('添加所选（1）'));
      await tester.pumpAndSettle();
      expect(find.text('所选照片无法读取，请重选或重试'), findsOneWidget);
      expect(find.text('添加所选（1）'), findsOneWidget);
    },
  );
  testWidgets('oversized device result is refused with no silent truncation', (
    tester,
  ) async {
    await _open(
      tester,
      _Gallery(),
      remaining: 1,
      device: _Device()..result = ['/a.png', '/b.png'],
    );
    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请重新选择'), findsOneWidget);
  });
  testWidgets('small screen and large type show actions without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _open(tester, _Gallery()..denied = true);
    expect(tester.takeException(), isNull);
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('添加所选（0）'), findsOneWidget);
  });
  testWidgets(
    'viewer opens requested photo and swipes with load error recovery',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTaskPhotoViewer(
                  context,
                  paths: ['/missing0.png', '/missing1.png', '/missing2.png'],
                  initialIndex: 1,
                ),
                child: const Text('view'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('view'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      final viewerWidth = tester.getSize(find.byType(Dialog)).width;
      expect(
        tester.getCenter(find.byType(CloseButton)).dx,
        greaterThan(viewerWidth / 2),
      );
      expect(
        tester.getCenter(find.text('2 / 3')).dx,
        closeTo(viewerWidth / 2, 0.1),
      );
      // FileImage uses real filesystem I/O outside the widget fake clock.
      for (var i = 0; i < 20 && find.text('照片无法加载').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('照片无法加载'), findsWidgets);
      expect(
        tester
            .widget<InteractiveViewer>(
              find.byKey(const ValueKey('task_photo_zoom_1')),
            )
            .maxScale,
        6,
      );
      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('view'), findsOneWidget);
    },
  );
  test('oversized source is rejected before image decoding', () async {
    final directory = await Directory.systemTemp.createTemp('plai-photo-large');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/large.png')
        .open(mode: FileMode.write);
    await file.truncate(32 * 1024 * 1024 + 1);
    await file.close();
    expect(
      prepareTaskPhoto('${directory.path}/large.png'),
      throwsA(isA<FileSystemException>()),
    );
  });
  test('small images stay byte identical and oversized images shrink without upsampling', () async {
    final directory = await Directory.systemTemp.createTemp(
      'plai-photo-prepare',
    );
    addTearDown(() => directory.delete(recursive: true));
    final small = File('${directory.path}/small.png');
    final original = await _png(100, 50);
    await small.writeAsBytes(original);
    expect(await prepareTaskPhoto(small.path), isNull);
    expect(await small.readAsBytes(), original);
    final big = File('${directory.path}/big.png');
    await big.writeAsBytes(await _png(3200, 1600));
    final prepared = await prepareTaskPhoto(big.path);
    expect(prepared, isNotNull);
    expect(prepared!.extension, '.png');
    expect(prepared.bytes.length, lessThan(await big.length()));
    final codec = await ui.instantiateImageCodec(prepared.bytes);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, 2560);
    expect(image.height, 1280);
    image.dispose();
    codec.dispose();
  });
}
