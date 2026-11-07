import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:plai/data/backup/backup_service.dart';
import 'package:plai/features/settings/backup_file_reader.dart';

final class _PickedBackup extends PlatformFile {
  _PickedBackup({this.reportedLength, this.chunks = const []});
  final int? reportedLength;
  final List<List<int>> chunks;
  bool readStarted = false;
  bool cancelled = false;
  int chunksRead = 0;
  @override
  String get name => 'backup.plai';
  @override
  Uri get uri => Uri.parse('content://documents/backup.plai');
  @override
  XFile get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => reportedLength;
  @override
  Future<int> length() async =>
      throw StateError('must not read whole file to stat');
  @override
  Future<Uint8List> readAsBytes() async =>
      throw StateError('unbounded read forbidden');
  @override
  Stream<Uint8List> readAsByteStream() async* {
    readStarted = true;
    try {
      for (final chunk in chunks) {
        chunksRead++;
        yield Uint8List.fromList(chunk);
      }
    } finally {
      cancelled = true;
    }
  }
}

void main() {
  test('known oversized picker selection is rejected before reading', () async {
    final file = _PickedBackup(reportedLength: 384 * 1024 * 1024 + 1);
    await expectLater(
      readBackupSelection(file),
      throwsA(isA<BackupFormatException>()),
    );
    expect(file.readStarted, isFalse);
  });
  test(
    'unknown size stops and cancels stream as soon as limit is crossed',
    () async {
      final file = _PickedBackup(
        chunks: [
          [1, 2, 3],
          [4, 5, 6],
          [7],
        ],
      );
      await expectLater(
        readBackupSelection(file, maxBytes: 5),
        throwsA(isA<BackupFormatException>()),
      );
      expect(file.chunksRead, 2);
      expect(file.cancelled, isTrue);
    },
  );
  test(
    'a stale undersized reported size cannot bypass actual byte limit',
    () async {
      final file = _PickedBackup(
        reportedLength: 1,
        chunks: [
          [1, 2, 3],
        ],
      );
      await expectLater(
        readBackupSelection(file, maxBytes: 2),
        throwsA(isA<BackupFormatException>()),
      );
    },
  );
  test(
    'exact boundary works with SAF URI and does not require filesystem path',
    () async {
      final file = _PickedBackup(
        chunks: [
          [1, 2],
          [3, 4],
        ],
      );
      expect(await readBackupSelection(file, maxBytes: 4), [1, 2, 3, 4]);
    },
  );
}
