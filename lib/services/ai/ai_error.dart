/// AI 客户端错误分类。
///
/// 请求失败**不静默、不编造成功**：任何失败都抛类型化 [AiError]，
/// feature 层按 [kind] 分流提示（配置引导 / 网络 / 服务端状态码 / 重试）。
enum AiErrorKind {
  /// 配置错误：base_url 为空或非法、model 未配置、messages 为空等。
  /// 调用方修正参数后重试。
  config,

  /// 网络错误：连接失败 / DNS 解析失败 / 连接被重置 / 读流中断等
  /// （对应底层 Socket / ClientException）。
  network,

  /// HTTP 非 2xx：携带 [AiError.statusCode] 与服务端错误消息
  /// （如 401 密钥无效、429 限流、5xx 服务端故障）。
  http,

  /// 响应格式错误：非 JSON / choices 缺失 / 结构不符。
  format,

  /// 请求超时（连接或整体/无数据时长超限）。
  timeout,
}

/// AI 客户端类型化错误。
class AiError implements Exception {
  const AiError(this.kind, this.message,
      {this.statusCode, this.cause, this.retryAfter});

  /// 错误分类。
  final AiErrorKind kind;

  /// 人类可读描述（含必要上下文，不含完整密钥）。
  final String message;

  /// HTTP 状态码（仅 [AiErrorKind.http] 有值）。
  final int? statusCode;

  /// 底层异常/原因（可空）。
  final Object? cause;

  /// 服务端建议的等待时长（来自 `Retry-After` 头，仅 [retryable] 时可能有值）。
  final Duration? retryAfter;

  /// 是否属「瞬时繁忙/限流」，值得自动指数退避重试：仅 HTTP 429（限流）
  /// 与 503（服务繁忙）。401/403/404 等永久性错误与 network/timeout 一律不重试。
  bool get retryable =>
      kind == AiErrorKind.http && (statusCode == 429 || statusCode == 503);

  @override
  String toString() => statusCode == null
      ? 'AiError(${kind.name}): $message'
      : 'AiError(${kind.name}, HTTP $statusCode): $message';
}
