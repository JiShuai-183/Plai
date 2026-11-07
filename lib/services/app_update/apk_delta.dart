import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Wire name advertised in the update manifest.
const apkDeltaAlgorithm = 'plai-bsdiff-gzip-v1';
const apkDeltaMaxApkSize = 512 * 1024 * 1024;
const _maxInstructions = 1000000;
const _chunkSize = 64 * 1024;
const _positionLimit = 1 << 53;

/// Apply PLDIFF01 (BSDIFF signed-magnitude integers + three gzip streams).
///
/// [output] must not exist. Only that new file is removed on failure. The base
/// and patch are read incrementally and never modified. The caller must verify
/// the patch/base hashes beforehand and the complete APK SHA-256 afterwards.
/// Suitable for calling in Isolate.run; no Flutter or native-library dependency.
Future<void> applyApkDelta({
  required File base,
  required File patch,
  required File output,
  required int expectedSize,
}) async {
  if (expectedSize < 0 || expectedSize > apkDeltaMaxApkSize) {
    throw const FormatException('Delta target size exceeds limit');
  }
  RandomAccessFile? oldFile;
  RandomAccessFile? result;
  final readers = <_DeltaReader>[];
  var created = false;
  var succeeded = false;
  try {
    // Exclusive creation also rejects existing files and links to either input.
    await output.create(exclusive: true);
    created = true;
    final patchSize = await patch.length();
    if (patchSize < 32 || patchSize > apkDeltaMaxApkSize * 2) {
      throw const FormatException('Invalid delta file size');
    }
    final headerFile = await patch.open();
    late Uint8List header;
    try {
      header = await headerFile.read(32);
    } finally {
      await headerFile.close();
    }
    if (header.length != 32 ||
        ascii.decode(header.sublist(0, 8)) != 'PLDIFF01') {
      throw const FormatException('Invalid delta magic/header');
    }
    final controlSize = _signed(header, 8);
    final diffSize = _signed(header, 16);
    final targetSize = _signed(header, 24);
    if (targetSize != expectedSize ||
        controlSize < 20 ||
        diffSize < 20 ||
        controlSize > patchSize - 32 ||
        diffSize > patchSize - 32 - controlSize ||
        patchSize - 32 - controlSize - diffSize < 20) {
      throw const FormatException('Invalid delta block lengths/target size');
    }
    final instructionLimit = math.min(_maxInstructions, expectedSize + 1024);
    final control = _DeltaReader(
      _inflate(patch, 32, controlSize, instructionLimit * 24),
    );
    final diff = _DeltaReader(
      _inflate(patch, 32 + controlSize, diffSize, expectedSize),
    );
    final extra = _DeltaReader(
      _inflate(
        patch,
        32 + controlSize + diffSize,
        patchSize - 32 - controlSize - diffSize,
        expectedSize,
      ),
    );
    readers.addAll([control, diff, extra]);
    oldFile = await base.open();
    final oldSize = await oldFile.length();
    final source = _BaseReader(oldFile, oldSize);
    result = await output.open(mode: FileMode.writeOnly);
    final destination = _OutputWriter(result);
    var oldPosition = 0;
    var newPosition = 0;
    var instructions = 0;
    while (newPosition < expectedSize) {
      if (++instructions > instructionLimit) {
        throw const FormatException('Too many delta instructions');
      }
      final tuple = await control.read(24);
      final add = _signed(tuple, 0);
      final copy = _signed(tuple, 8);
      final seek = _signed(tuple, 16);
      if (add < 0 ||
          copy < 0 ||
          add > expectedSize - newPosition ||
          copy > expectedSize - newPosition - add) {
        throw const FormatException('Invalid delta instruction lengths');
      }
      var remaining = add;
      while (remaining > 0) {
        final count = math.min(remaining, _chunkSize);
        final bytes = await diff.read(count);
        await source.addTo(bytes, oldPosition);
        await destination.add(bytes);
        oldPosition = _move(oldPosition, count);
        newPosition += count;
        remaining -= count;
      }
      remaining = copy;
      while (remaining > 0) {
        final count = math.min(remaining, _chunkSize);
        await destination.add(await extra.read(count));
        newPosition += count;
        remaining -= count;
      }
      oldPosition = _move(oldPosition, seek);
    }
    // Consume stream ends to verify gzip trailers, CRCs and reject unused data.
    for (final reader in readers) {
      await reader.expectEnd();
    }
    await destination.flush();
    await result.flush();
    if (await result.length() != expectedSize) {
      throw const FormatException('Incorrect reconstructed APK size');
    }
    succeeded = true;
  } finally {
    for (final reader in readers) {
      await reader.cancel();
    }
    await oldFile?.close();
    await result?.close();
    if (created && !succeeded) await output.delete();
  }
}

/// BSDIFF often emits many tiny adjacent ranges. One aligned cache page avoids
/// two file-system calls per tuple while retaining constant memory usage.
class _BaseReader {
  _BaseReader(this.file, this.size);
  final RandomAccessFile file;
  final int size;
  var _pageStart = -1;
  Uint8List _page = Uint8List(0);

  Future<void> addTo(Uint8List bytes, int oldPosition) async {
    // BSDIFF treats reads before/after the old file as zero bytes.
    var start = math.max(0, oldPosition);
    final end = math.min(size, oldPosition + bytes.length);
    while (start < end) {
      final pageStart = start ~/ _chunkSize * _chunkSize;
      if (_pageStart != pageStart) {
        await file.setPosition(pageStart);
        final count = math.min(_chunkSize, size - pageStart);
        _page = await file.read(count);
        if (_page.length != count) {
          throw const FormatException('Base APK changed during delta apply');
        }
        _pageStart = pageStart;
      }
      final count = math.min(end - start, _page.length - (start - _pageStart));
      final destination = start - oldPosition;
      final source = start - _pageStart;
      for (var i = 0; i < count; i++) {
        bytes[destination + i] =
            (bytes[destination + i] + _page[source + i]) & 255;
      }
      start += count;
    }
  }
}

class _OutputWriter {
  _OutputWriter(this.file);
  final RandomAccessFile file;
  final _buffer = Uint8List(_chunkSize);
  var _length = 0;

  Future<void> add(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      final count = math.min(bytes.length - offset, _buffer.length - _length);
      _buffer.setRange(_length, _length + count, bytes, offset);
      offset += count;
      _length += count;
      if (_length == _buffer.length) await flush();
    }
  }

  Future<void> flush() async {
    if (_length == 0) return;
    await file.writeFrom(_buffer, 0, _length);
    _length = 0;
  }
}

int _signed(List<int> bytes, int offset) {
  var magnitude = bytes[offset + 7] & 127;
  for (var i = 6; i >= 0; i--) {
    magnitude = (magnitude << 8) | bytes[offset + i];
  }
  return bytes[offset + 7] & 128 == 0 ? magnitude : -magnitude;
}

int _move(int position, int offset) {
  if (offset < -_positionLimit ||
      offset > _positionLimit ||
      position < -_positionLimit - offset ||
      position > _positionLimit - offset) {
    throw const FormatException('Delta base position exceeds limit');
  }
  return position + offset;
}

/// Small compressed input chunks bound transient inflater output (~1 MiB at
/// the maximum DEFLATE expansion ratio), even for malicious all-zero streams.
Stream<List<int>> _compressed(File file, int start, int length) async* {
  final handle = await file.open();
  try {
    await handle.setPosition(start);
    var remaining = length;
    while (remaining > 0) {
      final bytes = await handle.read(math.min(1024, remaining));
      if (bytes.isEmpty) throw const FormatException('Truncated delta stream');
      remaining -= bytes.length;
      yield bytes;
    }
  } finally {
    await handle.close();
  }
}

Stream<List<int>> _inflate(File file, int start, int length, int limit) async* {
  final handle = await file.open();
  late Uint8List trailer;
  try {
    await handle.setPosition(start);
    final header = await handle.read(10);
    if (header.length != 10 ||
        header[0] != 31 ||
        header[1] != 139 ||
        header[2] != 8 ||
        header[3] != 0) {
      throw const FormatException('Invalid delta gzip header');
    }
    await handle.setPosition(start + length - 8);
    trailer = await handle.read(8);
    if (trailer.length != 8) {
      throw const FormatException('Truncated gzip trailer');
    }
  } finally {
    await handle.close();
  }
  var size = 0;
  var crc = 0xffffffff;
  await for (final bytes in gzip.decoder.bind(
    _compressed(file, start, length),
  )) {
    size += bytes.length;
    if (size > limit) throw const FormatException('Delta stream exceeds limit');
    for (final byte in bytes) {
      crc = _crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
    }
    yield bytes;
  }
  final trailerData = ByteData.sublistView(trailer);
  if (((crc ^ 0xffffffff) & 0xffffffff) !=
          trailerData.getUint32(0, Endian.little) ||
      size != trailerData.getUint32(4, Endian.little)) {
    throw const FormatException('Delta gzip checksum/size mismatch');
  }
}

final _crcTable = List<int>.generate(256, (value) {
  for (var bit = 0; bit < 8; bit++) {
    value = value & 1 != 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value;
});

class _DeltaReader {
  _DeltaReader(Stream<List<int>> stream) : _iterator = StreamIterator(stream);
  final StreamIterator<List<int>> _iterator;
  List<int> _bytes = const [];
  var _offset = 0;

  Future<Uint8List> read(int length) async {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      if (_offset == _bytes.length) {
        if (!await _iterator.moveNext()) {
          throw const FormatException('Truncated delta decoded block');
        }
        _bytes = _iterator.current;
        _offset = 0;
        if (_bytes.isEmpty) continue;
      }
      final count = math.min(length - offset, _bytes.length - _offset);
      result.setRange(offset, offset + count, _bytes, _offset);
      _offset += count;
      offset += count;
    }
    return result;
  }

  Future<void> expectEnd() async {
    if (_offset != _bytes.length) {
      throw const FormatException('Unused delta decoded data');
    }
    while (await _iterator.moveNext()) {
      if (_iterator.current.isNotEmpty) {
        throw const FormatException('Unused delta decoded data');
      }
    }
  }

  Future<void> cancel() => _iterator.cancel();
}
