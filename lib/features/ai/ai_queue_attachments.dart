import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 排队附件复制到私有持久目录；历史消息继续引用这些文件。
class AiQueueAttachments {
  AiQueueAttachments({Future<Directory> Function()? directory})
    : _directory =
          directory ??
          (() async => Directory(
            p.join((await getApplicationDocumentsDirectory()).path, 'ai_queue'),
          ));

  final Future<Directory> Function() _directory;
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
        : 'image/jpeg';
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  Future<List<String>> retain(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final root = await _directory();
    await root.create(recursive: true);
    final retained = <String>[];
    try {
      for (final path in paths) {
        final source = File(path);
        if (!await source.exists()) throw FileSystemException('图片已不可用', path);
        final target = p.join(
          root.path,
          '${DateTime.now().microsecondsSinceEpoch}_${_sequence++}${p.extension(path)}',
        );
        retained.add((await source.copy(target)).path);
      }
      return retained;
    } catch (_) {
      await remove(retained);
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
