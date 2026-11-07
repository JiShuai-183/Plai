import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../data/backup/backup_service.dart';

/// Match BackupService.readFile; enforce the same boundary for SAF/content URIs
/// which cannot be passed to dart:io File or the service's path-based reader.
Future<Uint8List> readBackupSelection(
  PlatformFile file, {
  int maxBytes = 384 * 1024 * 1024,
}) async {
  final knownLength = file.lengthSync();
  if (knownLength != null && knownLength > maxBytes) {
    throw BackupFormatException('备份文件过大，不能超过 384 MiB');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (chunk.length > maxBytes - builder.length) {
      throw BackupFormatException('备份文件过大，不能超过 384 MiB');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  if (bytes.length > maxBytes) {
    throw BackupFormatException('备份文件过大，不能超过 384 MiB');
  }
  return bytes;
}
