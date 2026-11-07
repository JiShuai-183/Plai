import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';

/// 日程照片私有文件；删除始终检查数据库引用与真实目录边界。
class TaskImageStore {
  // Public named argument keeps injection callers independent of the private field.
  // ignore: prefer_initializing_formals
  TaskImageStore({Directory? directory}) : _directory = directory;

  final Directory? _directory;
  static const maxImageBytes = 32 * 1024 * 1024;

  Future<Directory> get directory async =>
      _directory ??
      Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'task_images'),
      );

  Future<String> importFile(
    String sourcePath, {
    List<int>? bytes,
    String? extension,
  }) async {
    if (bytes == null && await File(sourcePath).length() > maxImageBytes) {
      throw const FormatException('照片超过32MiB');
    }
    final data = bytes ?? await File(sourcePath).readAsBytes();
    final ext = imageExtension(data);
    final dir = await directory;
    await dir.create(recursive: true);
    final file = File(
      p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}.$ext',
      ),
    );
    try {
      await file.writeAsBytes(data, flush: true);
      return file.absolute.path;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<bool> isManaged(String path) async {
    final dir = await directory;
    final file = File(path);
    if (!await dir.exists() || !await file.exists()) return false;
    final root = await dir.resolveSymbolicLinks();
    final real = await file.resolveSymbolicLinks();
    return p.isWithin(root, real) && p.dirname(real) == root;
  }

  /// 校验常见照片容器签名；不信任文件名或备份扩展名。
  static String imageExtension(List<int> bytes) {
    if (bytes.length < 12 || bytes.length > maxImageBytes) {
      throw const FormatException('照片为空、损坏或超过32MiB');
    }
    if (bytes.length >= 45 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 13 &&
        bytes[5] == 10 &&
        bytes[6] == 26 &&
        bytes[7] == 10 &&
        ascii.decode(bytes.sublist(12, 16), allowInvalid: true) == 'IHDR' &&
        ascii.decode(
              bytes.sublist(bytes.length - 8, bytes.length - 4),
              allowInvalid: true,
            ) ==
            'IEND') {
      return 'png';
    }
    if (bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff &&
        bytes[bytes.length - 2] == 0xff &&
        bytes.last == 0xd9) {
      return 'jpg';
    }
    if ([
          'GIF87a',
          'GIF89a',
        ].contains(ascii.decode(bytes.sublist(0, 6), allowInvalid: true)) &&
        bytes.last == 0x3b) {
      return 'gif';
    }
    if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    if (ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp' &&
        [
          'heic',
          'heix',
          'hevc',
          'mif1',
          'avif',
        ].contains(ascii.decode(bytes.sublist(8, 12), allowInvalid: true))) {
      return 'heic';
    }
    throw const FormatException('不支持或损坏的照片格式');
  }

  Future<void> removeIfUnreferenced(
    AppDatabase db,
    Iterable<String> paths,
  ) async {
    if (paths.isEmpty) return;
    try {
      final rows = await (await db.database).query(
        'task',
        columns: ['image_paths'],
      );
      final referenced = <String>{};
      for (final row in rows) {
        final raw = jsonDecode(row['image_paths'] as String? ?? '[]') as List;
        referenced.addAll(raw.cast<String>());
      }
      for (final path in paths.toSet().difference(referenced)) {
        try {
          final dir = await directory;
          if (!await dir.exists()) continue;
          final file = File(path);
          if (!await file.exists()) continue;
          final root = await dir.resolveSymbolicLinks();
          final real = await file.resolveSymbolicLinks();
          if (p.isWithin(root, real) && p.dirname(real) == root) {
            await file.delete();
          }
        } catch (_) {
          // 数据写入已成功；回收失败留待后续，不把成功伪装成失败。
        }
      }
    } catch (_) {
      // 查询或解析失败时保守保留，避免写入成功后被报告为失败。
    }
  }
}
