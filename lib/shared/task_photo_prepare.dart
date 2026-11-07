import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// No temporary files: the caller imports these bytes into its attachment store.
class PreparedTaskPhoto {
  const PreparedTaskPhoto({required this.bytes, required this.extension});
  final Uint8List bytes;
  final String extension;
}

typedef TaskPhotoPreparer = Future<PreparedTaskPhoto?> Function(String path);

final taskPhotoPreparerProvider = Provider<TaskPhotoPreparer>(
  (ref) => prepareTaskPhoto,
);

/// Preserve small originals. Resize oversized images losslessly only when the
/// resulting PNG is smaller than the source; never upsample screenshots.
Future<PreparedTaskPhoto?> prepareTaskPhoto(String path) async {
  final file = File(path);
  if (await file.length() > 32 * 1024 * 1024) {
    throw const FileSystemException('单张照片不能超过 32 MB');
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > 32 * 1024 * 1024) {
    throw const FileSystemException('单张照片不能超过 32 MB');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Animated images must retain their original frames.
    final probe = await descriptor.instantiateCodec();
    final animated = probe.frameCount > 1;
    probe.dispose();
    if (animated) return null;
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    if (longest <= 2560) return null;
    final ratio = 2560 / longest;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * ratio).round().clamp(1, 2560),
      targetHeight: (descriptor.height * ratio).round().clamp(1, 2560),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes >= bytes.length) return null;
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
