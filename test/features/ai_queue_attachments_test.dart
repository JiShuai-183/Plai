import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/ai/ai_queue_attachments.dart';
import 'package:plai/shared/task_photo_prepare.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xffaabbcc),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('异步复制图片后原文件变化不影响排队内容；清理只触及私有目录', () async {
    final temp = await Directory.systemTemp.createTemp(
      'plai-queue-attachment-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final original = File('${temp.path}/source.png');
    await original.writeAsBytes([1, 2, 3]);
    final root = Directory('${temp.path}/queue');
    final store = AiQueueAttachments(
      directory: () async => root,
      prepare: (_) async => null,
    );
    final retained = await store.retain([original.path]);
    expect(retained.single, isNot(original.path));
    await original.writeAsBytes([9]);
    expect(await File(retained.single).readAsBytes(), [1, 2, 3]);
    expect(await store.dataUris(retained), [
      'data:image/png;base64,${base64Encode([1, 2, 3])}',
    ]);
    await store.remove([original.path, ...retained]);
    expect(await original.exists(), isTrue);
    expect(await File(retained.single).exists(), isFalse);
  });
  test('任一附件不可读时清理本次已复制文件，整条消息不带残缺附件入队', () async {
    final temp = await Directory.systemTemp.createTemp(
      'plai-queue-attachment-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/source.jpg');
    await source.writeAsBytes([1]);
    final root = Directory('${temp.path}/queue');
    final store = AiQueueAttachments(
      directory: () async => root,
      prepare: (_) async => null,
    );
    await expectLater(
      store.retain([source.path, '${temp.path}/missing.jpg']),
      throwsA(isA<FileSystemException>()),
    );
    expect(await root.list().toList(), isEmpty);
    expect(await source.exists(), isTrue);
  });
  test('统一处理保留小截图原字节，超大图缩至手动端尺寸且wire与队列一致', () async {
    final temp = await Directory.systemTemp.createTemp('ai-photo-quality');
    addTearDown(() => temp.delete(recursive: true));
    final small = File('${temp.path}/small.png');
    final smallBytes = await _png(100, 50);
    await small.writeAsBytes(smallBytes);
    final large = File('${temp.path}/large.png');
    await large.writeAsBytes(await _png(3200, 1600));
    final store = AiQueueAttachments(
      directory: () async => Directory('${temp.path}/queue'),
    );
    final paths = await store.retain([small.path, large.path]);
    expect(await File(paths.first).readAsBytes(), smallBytes);
    final largeBytes = await File(paths.last).readAsBytes();
    // 队列就是后续日程复制的可信源，发送不能另拿一份更模糊的图。
    final codec = await ui.instantiateImageCodec(largeBytes);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, 2560);
    expect(image.height, 1280);
    image.dispose();
    codec.dispose();
    final uris = await store.dataUris(paths);
    expect(base64Decode(uris.last.split(',').last), largeBytes);
  });
  test('转换失败回收所有已准备副本，保留输入原图', () async {
    final temp = await Directory.systemTemp.createTemp('ai-photo-cleanup');
    addTearDown(() => temp.delete(recursive: true));
    final a = File('${temp.path}/a.jpg');
    final b = File('${temp.path}/b.jpg');
    await a.writeAsBytes([1]);
    await b.writeAsBytes([2]);
    final root = Directory('${temp.path}/queue');
    var processed = 0;
    final store = AiQueueAttachments(
      directory: () async => root,
      prepare: (path) async {
        if (++processed == 2) throw const FormatException('invalid image');
        return PreparedTaskPhoto(bytes: await _png(10, 10), extension: '.png');
      },
    );
    await expectLater(store.retain([a.path, b.path]), throwsFormatException);
    expect(await root.list().toList(), isEmpty);
    expect(await a.exists(), isTrue);
    expect(await b.exists(), isTrue);
  });
  test('扩展名不通用的可解码图片转PNG而不伪标JPEG', () async {
    final temp = await Directory.systemTemp.createTemp('ai-photo-format');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/unknown.heic');
    await source.writeAsBytes(await _png(32, 16));
    final store = AiQueueAttachments(
      directory: () async => Directory('${temp.path}/queue'),
    );
    final retained = await store.retain([source.path]);
    expect(retained.single.endsWith('.png'), isTrue);
    expect(
      (await store.dataUris(retained)).single.startsWith('data:image/png;'),
      isTrue,
    );
  });
}
