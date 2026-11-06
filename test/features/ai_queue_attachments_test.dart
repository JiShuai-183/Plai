import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/ai/ai_queue_attachments.dart';

void main() {
  test('异步复制图片后原文件变化不影响排队内容；清理只触及私有目录', () async {
    final temp = await Directory.systemTemp.createTemp(
      'plai-queue-attachment-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final original = File('${temp.path}/source.png');
    await original.writeAsBytes([1, 2, 3]);
    final root = Directory('${temp.path}/queue');
    final store = AiQueueAttachments(directory: () async => root);
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
    final store = AiQueueAttachments(directory: () async => root);
    await expectLater(
      store.retain([source.path, '${temp.path}/missing.jpg']),
      throwsA(isA<FileSystemException>()),
    );
    expect(await root.list().toList(), isEmpty);
    expect(await source.exists(), isTrue);
  });
}
