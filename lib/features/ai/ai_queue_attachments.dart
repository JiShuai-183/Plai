import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../shared/task_photo_prepare.dart';

/// 排队附件复制到私有持久目录；历史消息继续引用这些文件。
class AiQueueAttachments {
  AiQueueAttachments({
    Future<Directory> Function()? directory,
    TaskPhotoPreparer? prepare,
  }) : _directory =
           directory ??
           (() async => Directory(
             p.join(
               (await getApplicationDocumentsDirectory()).path,
               'ai_queue',
             ),
           )),
       _prepare = prepare ?? _prepareQueuePhoto;

  final Future<Directory> Function() _directory;
  final TaskPhotoPreparer _prepare;
  int _sequence = 0;

  Future<List<String>> dataUris(List<String> paths) async => [
    for (final path in paths) encodeImage(path, await File(path).readAsBytes()),
  ];

  static String encodeImage(String path, List<int> bytes) {
    final ext = path.toLowerCase();
    final mime = ext.endsWith('.png')
        ? 'image/png'
        : ext.endsWith('.webp')
        ? 'image/webp'
        : ext.endsWith('.gif')
        ? 'image/gif'
        : 'image/jpeg';
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  Future<List<String>> retain(List<String> paths) async {
    if (paths.isEmpty) return const [];
    if (paths.length > 4) throw const FormatException('每条消息最多4张照片');
    final root = await _directory();
    await root.create(recursive: true);
    final retained = <String>[];
    final created = <String>[];
    try {
      for (final path in paths) {
        final source = File(path);
        if (!await source.exists()) throw FileSystemException('图片已不可用', path);
        if (await source.length() > 32 * 1024 * 1024) {
          throw const FileSystemException('单张照片不能超过32MiB');
        }
        final target = p.join(
          root.path,
          '${DateTime.now().microsecondsSinceEpoch}_${_sequence++}${p.extension(path)}',
        );
        // 先冻结原文件再处理，避免处理期间相册原图变化导致识别与保存不一致。
        created.add(target);
        await source.copy(target);
        final prepared = await _prepare(target);
        if (prepared == null) {
          retained.add(target);
        } else {
          final converted =
              '${p.withoutExtension(target)}${prepared.extension}';
          if (converted != target) created.add(converted);
          await File(converted).writeAsBytes(prepared.bytes, flush: true);
          if (converted != target) await File(target).delete();
          retained.add(converted);
        }
      }
      return retained;
    } catch (_) {
      await remove(created);
      rethrow;
    }
  }

  Future<void> remove(List<String> paths) async {
    if (paths.isEmpty) return;
    final root = p.normalize(p.absolute((await _directory()).path));
    for (final path in paths.toSet()) {
      final absolute = p.normalize(p.absolute(path));
      // 只回收本服务的文件，历史外部相册路径不受影响。
      if (!p.isWithin(root, absolute)) continue;
      try {
        final f = File(absolute);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

/// 与手动端相同的清晰度规则；HEIC等发送端不通用的格式转PNG，避免伪标JPEG。
Future<PreparedTaskPhoto?> _prepareQueuePhoto(String path) async {
  final prepared = await prepareTaskPhoto(path);
  if (prepared != null) return prepared;
  if (const [
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
  ].contains(p.extension(path).toLowerCase())) {
    return null;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    await File(path).readAsBytes(),
  );
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final largest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final ratio = largest > 2560 ? 2560 / largest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * ratio).round().clamp(1, 2560),
      targetHeight: (descriptor.height * ratio).round().clamp(1, 2560),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw const FormatException('无法准备图片');
    return PreparedTaskPhoto(
      bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      extension: '.png',
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
