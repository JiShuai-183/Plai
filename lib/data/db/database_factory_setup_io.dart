import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Windows 没有 sqflite 的原生平台实现，改用 SQLite FFI。
///
/// Android 与 iOS 继续使用 sqflite 默认工厂，不受影响。
void configureDatabaseFactoryForCurrentPlatform() {
  if (!Platform.isWindows) return;

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
