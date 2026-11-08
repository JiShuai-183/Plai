import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 业务工具只需要读取和刷新 provider，生命周期由应用级 provider 管理。
class AiToolContext {
  factory AiToolContext({
    required T Function<T>(ProviderListenable<T>) read,
    required void Function(ProviderOrFamily) invalidate,
    List<String> imagePaths = const [],
    String? requestId,
    String userText = '',
  }) => AiToolContext._(read, invalidate, imagePaths, requestId, userText);
  AiToolContext._(
    this._read,
    this._invalidate,
    List<String> paths,
    this.requestId,
    this.userText,
  ) : imagePaths = List.unmodifiable(paths);

  factory AiToolContext.fromRef(Ref ref) =>
      AiToolContext(read: ref.read, invalidate: ref.invalidate);

  final T Function<T>(ProviderListenable<T> provider) _read;
  final void Function(ProviderOrFamily provider) _invalidate;

  /// 仅本条队列消息冻结的图片，不能从另一会话或历史消息补取。
  final List<String> imagePaths;
  final String? requestId;
  final String userText;
  AiToolContext forRequest({
    required String requestId,
    required List<String> imagePaths,
    required String userText,
  }) => AiToolContext(
    read: _read,
    invalidate: _invalidate,
    requestId: requestId,
    imagePaths: imagePaths,
    userText: userText,
  );
  T read<T>(ProviderListenable<T> provider) => _read(provider);
  void invalidate(ProviderOrFamily provider) => _invalidate(provider);
}
