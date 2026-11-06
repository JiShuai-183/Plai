import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 业务工具只需要读取和刷新 provider，生命周期由应用级 provider 管理。
class AiToolContext {
  factory AiToolContext({
    required T Function<T>(ProviderListenable<T>) read,
    required void Function(ProviderOrFamily) invalidate,
  }) => AiToolContext._(read, invalidate);
  AiToolContext._(this._read, this._invalidate);

  factory AiToolContext.fromRef(Ref ref) =>
      AiToolContext(read: ref.read, invalidate: ref.invalidate);

  final T Function<T>(ProviderListenable<T> provider) _read;
  final void Function(ProviderOrFamily provider) _invalidate;
  T read<T>(ProviderListenable<T> provider) => _read(provider);
  void invalidate(ProviderOrFamily provider) => _invalidate(provider);
}
