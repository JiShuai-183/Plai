import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plai/services/app_update/apk_delta.dart';

List<int> integer(int value) {
  final bytes = Uint8List(8);
  var magnitude = value.abs();
  for (var i = 0; i < 8; i++) {
    bytes[i] = magnitude & 255;
    magnitude >>>= 8;
  }
  if (value < 0) bytes[7] |= 128;
  return bytes;
}

List<int> delta(
  List<List<int>> tuples,
  List<int> diff,
  List<int> extra,
  int size, {
  List<int>? rawControl,
}) {
  final control = gzip.encode(
    rawControl ??
        [
          for (final tuple in tuples)
            for (final value in tuple) ...integer(value),
        ],
  );
  final changes = gzip.encode(diff);
  return [
    ...ascii.encode('PLDIFF01'),
    ...integer(control.length),
    ...integer(changes.length),
    ...integer(size),
    ...control,
    ...changes,
    ...gzip.encode(extra),
  ];
}

void main() {
  late Directory root;
  late File base;
  late File patch;
  late File output;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('apk_delta_test_');
    base = File('${root.path}/base.apk');
    patch = File('${root.path}/patch');
    output = File('${root.path}/result.apk');
    await base.writeAsBytes([10, 20, 30]);
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> apply(List<int> data, int size) async {
    await patch.writeAsBytes(data);
    await applyApkDelta(
      base: base,
      patch: patch,
      output: output,
      expectedSize: size,
    );
  }

  Future<void> rejects(List<int> data, int size) async {
    final before = await base.readAsBytes();
    await expectLater(apply(data, size), throwsA(isA<Exception>()));
    expect(await output.exists(), isFalse);
    expect(await base.readAsBytes(), before);
  }

  test('diff bytes add modulo 256, extra bytes append independently', () async {
    await apply(
      delta(
        [
          [3, 2, 0],
        ],
        [250, 1, 2],
        [44, 55],
        5,
      ),
      5,
    );
    expect(await output.readAsBytes(), [4, 21, 32, 44, 55]);
  });

  test('negative old positions and reads beyond EOF are zero-filled', () async {
    await apply(
      delta(
        [
          [0, 0, -2],
          [5, 0, 10],
          [3, 0, 0],
        ],
        List.filled(8, 1),
        [],
        8,
      ),
      8,
    );
    expect(await output.readAsBytes(), [1, 1, 11, 21, 31, 1, 1, 1]);
  });

  test('empty target validates all three empty gzip streams', () async {
    await apply(delta([], [], [], 0), 0);
    expect(await output.length(), 0);
  });

  test('old-file cache handles cross-page reads and backward seeks', () async {
    const page = 64 * 1024;
    final old = List.generate(3 * page + 3, (i) => i % 251);
    await base.writeAsBytes(old);
    await apply(
      delta(
        [
          [0, 0, page - 2],
          [10, 3, -20],
          [25, 0, 3 * page],
          [4, 0, 0],
        ],
        List.filled(39, 0),
        [2, 3, 4],
        42,
      ),
      42,
    );
    expect(await output.readAsBytes(), [
      ...old.sublist(page - 2, page + 8),
      2,
      3,
      4,
      ...old.sublist(page - 12, page + 13),
      0,
      0,
      0,
      0,
    ]);
  });

  test(
    'many tiny instructions fill and flush output buffer correctly',
    () async {
      const count = 4096;
      final tuples = List.generate(count, (_) => [1, 32, 0]);
      await apply(
        delta(
          tuples,
          List.filled(count, 0),
          List.filled(count * 32, 7),
          count * 33,
        ),
        count * 33,
      );
      final actual = await output.readAsBytes();
      expect(actual, [
        for (var i = 0; i < count; i++) ...[
          i < 3 ? (i + 1) * 10 : 0,
          ...List.filled(32, 7),
        ],
      ]);
    },
  );

  test(
    'large compressed target crosses input/output chunk boundaries',
    () async {
      const size = 3 * 1024 * 1024;
      await apply(
        delta(
          [
            [size, 0, 0],
          ],
          List.filled(size, 0),
          [],
          size,
        ),
        size,
      );
      expect(await output.length(), size);
      final head = await output.open();
      expect(await head.read(5), [10, 20, 30, 0, 0]);
      await head.close();
    },
  );

  test('real bsdiff4 generator fixtures decode exactly', () async {
    final fixtures = jsonDecode(
      await File('test/fixtures/apk_delta_v1.json').readAsString(),
    ) as List;
    for (final fixture in fixtures) {
      await base.writeAsBytes(base64Decode(fixture['old'] as String));
      final expected = base64Decode(fixture['new'] as String);
      await apply(base64Decode(fixture['patch'] as String), expected.length);
      expect(
        await output.readAsBytes(),
        expected,
        reason: fixture['name'] as String,
      );
      await output.delete();
    }
  });

  test('existing output and base alias are never overwritten', () async {
    await output.writeAsBytes([99]);
    await expectLater(
      apply(delta([], [], [], 0), 0),
      throwsA(isA<FileSystemException>()),
    );
    expect(await output.readAsBytes(), [99]);
    await expectLater(
      applyApkDelta(base: base, patch: patch, output: base, expectedSize: 0),
      throwsA(isA<FileSystemException>()),
    );
    expect(await base.readAsBytes(), [10, 20, 30]);
  });

  test(
    'header, target size and compressed block boundaries are checked',
    () async {
      final valid = delta(
        [
          [0, 1, 0],
        ],
        [],
        [1],
        1,
      );
      for (final malformed in [
        <int>[],
        valid.sublist(0, 31),
        [0, ...valid.skip(1)],
        [...valid.take(8), ...integer(-1), ...valid.skip(16)],
        [...valid.take(8), ...integer(0x7fffffffffffffff), ...valid.skip(16)],
        [...valid.take(16), ...integer(0x7fffffffffffffff), ...valid.skip(24)],
        valid.sublist(0, valid.length - 1),
      ]) {
        await rejects(malformed, 1);
      }
      await rejects(valid, 2);
      await rejects(valid, -1);
      await rejects(valid, 512 * 1024 * 1024 + 1);
    },
  );

  test(
    'negative lengths, output overshoot and old-position overflow fail',
    () async {
      for (final tuple in [
        [-1, 1, 0],
        [0, -1, 0],
        [2, 0, 0],
        [0, 2, 0],
        [0, 0, 0x7fffffffffffffff],
      ]) {
        await rejects(delta([tuple], [0], [0], 1), 1);
      }
    },
  );

  test('zero-progress instructions are bounded', () async {
    await rejects(delta(List.generate(1026, (_) => [0, 0, 0]), [], [], 1), 1);
  });

  test('truncated tuples and insufficient diff/extra bytes fail', () async {
    await rejects(delta([], [], [], 1, rawControl: [1]), 1);
    await rejects(
      delta(
        [
          [1, 0, 0],
        ],
        [],
        [],
        1,
      ),
      1,
    );
    await rejects(
      delta(
        [
          [0, 1, 0],
        ],
        [],
        [],
        1,
      ),
      1,
    );
  });

  test('unused decoded control/diff/extra bytes are rejected', () async {
    await rejects(
      delta(
        [
          [0, 1, 0],
          [0, 0, 0],
        ],
        [],
        [1],
        1,
      ),
      1,
    );
    await rejects(
      delta(
        [
          [0, 1, 0],
        ],
        [1],
        [1],
        1,
      ),
      1,
    );
    await rejects(
      delta(
        [
          [0, 1, 0],
        ],
        [],
        [1, 2],
        1,
      ),
      1,
    );
  });

  test('gzip checksum, size, header and truncation are checked', () async {
    final good = delta(
      [
        [0, 1, 0],
      ],
      [],
      [1],
      1,
    );
    for (final offset in [32, 35, good.length - 8, good.length - 4]) {
      final corrupt = List<int>.of(good);
      corrupt[offset] ^= 1;
      await rejects(corrupt, 1);
    }
    final truncated = good.sublist(0, good.length - 9);
    await rejects(truncated, 1);
    await rejects([...good, 1, 2, 3], 1);
  });
}
