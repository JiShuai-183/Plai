import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'ai_error.dart';
import 'models/ai_message.dart';
import 'models/ai_tool.dart';

/// 单次非流式 chat 的结果。
class LlmChatResult {
  const LlmChatResult({
    this.content,
    this.toolCalls = const [],
    this.finishReason,
    this.model,
  });

  /// 回复文本；空/无文本时为 null（如纯工具调用回复）。
  final String? content;

  /// 工具调用列表（若有）。[AiToolCall.arguments] 可解析参数。
  final List<AiToolCall> toolCalls;

  /// 结束原因原串：`stop` / `tool_calls` / `length` / `content_filter` 等
  /// （不同服务措辞可能不同，按原样透传）。
  final String? finishReason;

  /// 服务端回显的模型名（可空）。
  final String? model;

  @override
  String toString() =>
      'LlmChatResult(content: ${content ?? ''}, toolCalls: ${toolCalls.length}, '
      'finishReason: $finishReason)';
}

/// 流式过程中的一个增量片段（回调透传给调用方做逐字/逐片段展示）。
class LlmDelta {
  const LlmDelta({
    this.contentDelta,
    this.toolCallDeltas = const [],
  });

  /// 本次增量文本（content delta）。
  final String? contentDelta;

  /// 本次增量的工具调用片段（OpenAI 流式 tool_calls 需按 [LlmToolCallDelta.index]
  /// 自行累加 arguments 等片段；本 Delta 内 index 也可能跨多个）。
  final List<LlmToolCallDelta> toolCallDeltas;
}

/// 流式工具调用增量片段（对应某个 index 的一次 delta）。
class LlmToolCallDelta {
  const LlmToolCallDelta({
    required this.index,
    this.id,
    this.functionName,
    this.argumentsDelta,
  });

  /// 工具调用序号（同一调用在多段 delta 间保持一致）。
  final int index;

  /// id 片段（通常在首段给全）。
  final String? id;

  /// 函数名片段。
  final String? functionName;

  /// arguments 增量片段（多个 delta 需按 [index] 拼接成完整 JSON）。
  final String? argumentsDelta;
}

/// OpenAI 兼容 `chat/completions` HTTP 客户端（纯服务，无 UI / 无 Riverpod）。
///
/// 配置（baseUrl/apiKey/model）由调用方（feature 层读 settings `ai.*` 键后）
/// 传入；本类只接收参数、不读库。注入 [httpClient] 便于单测 mock。
///
/// - baseUrl 拼接：自动补 `/chat/completions`（兼容已含 `/v1` 或已带后缀）。
/// - 错误统一抛类型化 [AiError]（config/network/http/format/timeout）。
/// - 瞬时繁忙（HTTP 429/503，[AiError.retryable]）在 [defaultMaxRetries]
///   次内自动指数退避重试（优先服务端 Retry-After）；首段流开始后不重试。
/// - 图片走 data URI（base64），大小由调用方控制，本层不压缩。
class LlmClient {
  /// 瞬时繁忙（429/503）自动重试次数上限；单次总尝试 = maxRetries + 1。
  static const int defaultMaxRetries = 2;

  /// 同一实例连续请求的最小起始间隔：单条用户消息内的相邻工具轮复用同一
  /// client，请求近乎背靠背发起；加小幅间隔平滑突发、降低触发服务端限流
  /// （429/503）的概率。首请求不等待；距上次请求已超过该间隔则不再等。
  /// （放本层而非页面层：生产复用同一 client 生效，widget 测试的 Fake
  /// 覆盖 chatStream 天然绕过，不影响其时钟。）
  static const Duration minRequestGap = Duration(milliseconds: 300);

  LlmClient({
    required String baseUrl,
    this.apiKey = '',
    required this.model,
    http.Client? httpClient,
    this.connectTimeout = const Duration(seconds: 10),
    this.totalTimeout = const Duration(seconds: 60),
  })  : _baseUrl = _normalizeBaseUrl(baseUrl),
        _client = httpClient ?? _newDefaultClient(connectTimeout),
        _ownsClient = httpClient == null;

  /// API Base URL（已去尾部斜杠）。空串表示未配置。
  final String _baseUrl;

  /// API 密钥（可为空：本地无鉴权服务不需要发 Authorization）。
  final String apiKey;

  /// 对话模型名。
  final String model;

  /// 连接超时（仅默认 io 客户端生效；注入客户端时由其自行保证）。
  final Duration connectTimeout;

  /// 总/无数据超时。
  final Duration totalTimeout;

  final http.Client _client;
  final bool _ownsClient;

  /// 上次实际发起请求的时刻（用于工具轮连续请求的起始间隔平滑）。
  DateTime? _lastRequestStartedAt;

  static String _normalizeBaseUrl(String baseUrl) {
    final t = baseUrl.trim();
    return t.replaceFirst(RegExp(r'/+$'), '');
  }

  static http.Client _newDefaultClient(Duration connectTimeout) {
    final io = HttpClient()..connectionTimeout = connectTimeout;
    return IOClient(io);
  }

  /// 对话端点（配置校验：base_url 非空、必须 http(s) 开头）。
  Uri get endpoint => _endpointFor('/chat/completions');

  /// 按 [suffix] 拼出端点；baseUrl 的校验与拼接规则统一在此。
  Uri _endpointFor(String suffix) {
    if (_baseUrl.isEmpty) {
      throw const AiError(AiErrorKind.config, 'base_url 为空，请先在设置中配置');
    }
    if (!_baseUrl.startsWith('http://') &&
        !_baseUrl.startsWith('https://')) {
      throw const AiError(
        AiErrorKind.config,
        'base_url 非法：必须以 http:// 或 https:// 开头',
      );
    }
    final url = _baseUrl.endsWith(suffix) ? _baseUrl : _baseUrl + suffix;
    return Uri.parse(url);
  }

  /// 拉取服务端可用模型列表（OpenAI 兼容 `GET {base}/models`）。
  ///
  /// 返回去重并按名称排序的模型 id。与 [ping] 同属「用户当面等待」的操作，
  /// 默认不做繁忙重试（`maxRetries: 0`），失败立即反馈。
  Future<List<String>> listModels({
    Duration? timeout,
    int maxRetries = 0,
  }) async {
    final Duration dur = timeout ?? totalTimeout;
    var attempt = 0;
    while (true) {
      final http.Response response =
          await _sendRequest(_makeGetRequest(_endpointFor('/models')), dur);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _parseModelIds(_decodeJsonObject(response.body));
      }
      final AiError error = _httpError(
        response.statusCode,
        _snippet(response.body),
        retryAfter: _retryAfterOf(response),
      );
      if (!error.retryable || attempt >= maxRetries) throw error;
      attempt++;
      await Future<void>.delayed(_backoff(attempt, error.retryAfter));
    }
  }

  /// 解析 `/models` 响应：取 `data[].id`，去重后排序（服务端顺序不保证）。
  static List<String> _parseModelIds(Map<String, dynamic> root) {
    final Object? data = root['data'];
    if (data is! List) {
      throw const AiError(AiErrorKind.format, '响应缺少 data 列表');
    }
    final Set<String> ids = <String>{};
    for (final Object? item in data) {
      if (item is! Map) continue;
      final Object? id = item['id'];
      if (id is String && id.trim().isNotEmpty) ids.add(id.trim());
    }
    return ids.toList()..sort();
  }

  /// 连接性探测：发一条极短 user 消息，非流式成功即连通；
  /// 失败按 [AiError] 抛（如未配置 → config）。
  /// 连通性测试不做繁忙自动重试（maxRetries: 0），立即反馈结果给用户；
  /// 不携带 temperature——思考/推理型模型只允许默认采样，多供应商兼容。
  Future<void> ping({Duration? timeout}) {
    return chat(
      messages: [AiMessage.user('ping')],
      timeout: timeout,
      maxRetries: 0,
    ).then((_) {});
  }

  /// 非流式对话。返回文本与/或工具调用，另附 finishReason。
  /// [temperature] 不传则不携带该字段——尊重服务端默认（思考/推理型模型
  /// 普遍禁止自定义采样温度，各厂商约束不一，默认不传最鲁棒）。
  Future<LlmChatResult> chat({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
    int maxRetries = defaultMaxRetries,
  }) async {
    final body = _buildBody(
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      jsonMode: jsonMode,
      temperature: temperature,
      stream: false,
    );
    // 整体缓冲，响应未交付调用方前可安全重试瞬时繁忙。
    final response = await _sendBufferedWithRetry(
      body,
      timeout ?? totalTimeout,
      maxRetries: maxRetries,
    );
    final root = _decodeJsonObject(response.body);
    return _parseNonStreamResult(root);
  }

  /// 流式对话（SSE）。[onDelta] 逐段回调增量；结束返回聚合结果
  /// （文本拼接 + 按 index 合并好的完整 tool_calls）。
  /// [temperature] 不传则不携带该字段（同 [chat]，默认尊重服务端采样设定）。
  Future<LlmChatResult> chatStream({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
    int maxRetries = defaultMaxRetries,
    void Function(LlmDelta delta)? onDelta,
  }) async {
    final dur = timeout ?? totalTimeout;
    final body = _buildBody(
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      jsonMode: jsonMode,
      temperature: temperature,
      stream: true,
    );

    // 同一实例被工具轮连续复用时，平滑相邻请求的起始时刻（真实等待只在
    // 距上次请求不足 [minRequestGap] 时发生；首请求直接放行）。
    await _throttleRoundGap();

    // 只对「首段流开始前」的失败自动重试：此刻尚未有任何 delta 交付给
    // onDelta，重发不会造成已显示文字重复。拿到 2xx SSE 响应体后，后续
    // 读流中断（Socket/超时/格式）一律不重试，直接按原逻辑抛错。
    final http.StreamedResponse streamed = await _openStreamWithRetry(
      body,
      dur,
      maxRetries: maxRetries,
    );

    final acc = _SseAccumulator(onDelta);
    try {
      final lines = const LineSplitter()
          .bind(utf8.decoder.bind(streamed.stream))
          .timeout(dur);
      await for (final line in lines) {
        if (acc.feed(line)) break; // data: [DONE]
      }
    } on TimeoutException catch (e) {
      throw _timeout(dur, e);
    } on http.ClientException catch (e) {
      throw _network(e);
    } on SocketException catch (e) {
      throw _network(e);
    }
    return acc.result();
  }

  // ---------------------------------------------------------- 内部构建

  Map<String, dynamic> _buildBody({
    required bool stream,
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    required bool jsonMode,
    double? temperature,
  }) {
    if (messages.isEmpty) {
      throw const AiError(AiErrorKind.config, 'messages 不能为空');
    }
    if (model.trim().isEmpty) {
      throw const AiError(AiErrorKind.config, 'model 未配置');
    }
    final body = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toRequestJson()).toList(growable: false),
      'stream': stream,
    };
    if (tools != null && tools.isNotEmpty) body['tools'] = tools;
    if (toolChoice != null) body['tool_choice'] = toolChoice;
    if (jsonMode) body['response_format'] = const {'type': 'json_object'};
    if (temperature != null) body['temperature'] = temperature;
    return body;
  }

  http.Request _makeRequest(Map<String, dynamic> body) {
    final request = http.Request('POST', endpoint);
    if (apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $apiKey';
    }
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.body = jsonEncode(body);
    return request;
  }

  /// GET 请求：只带鉴权头，无 body / Content-Type。
  http.Request _makeGetRequest(Uri url) {
    final request = http.Request('GET', url);
    if (apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $apiKey';
    }
    return request;
  }

  Future<http.Response> _sendBuffered(
    Map<String, dynamic> body,
    Duration dur,
  ) =>
      _sendRequest(_makeRequest(body), dur);

  /// 发请求并缓冲响应体；超时/网络异常统一转 [AiError]。
  Future<http.Response> _sendRequest(
    http.Request request,
    Duration dur,
  ) async {
    try {
      final streamed = await _client.send(request).timeout(dur);
      final text = await streamed.stream.bytesToString().timeout(dur);
      return http.Response(text, streamed.statusCode,
          headers: streamed.headers, request: request);
    } on TimeoutException catch (e) {
      throw _timeout(dur, e);
    } on http.ClientException catch (e) {
      throw _network(e);
    } on SocketException catch (e) {
      throw _network(e);
    }
  }

  /// 带自动退避重试的缓冲发送：2xx 直接返回；[AiError.retryable]（429/503）
  /// 在 [maxRetries] 次内退避重发（优先服务端 Retry-After），耗尽仍失败抛错；
  /// 其它状态码及网络/超时错误不重试、立即抛。
  Future<http.Response> _sendBufferedWithRetry(
    Map<String, dynamic> body,
    Duration dur, {
    required int maxRetries,
  }) async {
    var attempt = 0;
    while (true) {
      final http.Response response = await _sendBuffered(body, dur);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }
      final AiError error = _httpError(
        response.statusCode,
        _snippet(response.body),
        retryAfter: _retryAfterOf(response),
      );
      if (!error.retryable || attempt >= maxRetries) throw error;
      attempt++;
      await Future<void>.delayed(_backoff(attempt, error.retryAfter));
    }
  }

  /// 发送请求并只对「首段流开始前」的失败（send 抛错 / 非 2xx）退避重试；
  /// 返回已确认 2xx 的 [http.StreamedResponse]，由消费方逐行读 SSE。
  Future<http.StreamedResponse> _openStreamWithRetry(
    Map<String, dynamic> body,
    Duration dur, {
    required int maxRetries,
  }) async {
    var attempt = 0;
    while (true) {
      http.StreamedResponse streamed;
      try {
        streamed = await _client.send(_makeRequest(body)).timeout(dur);
      } on TimeoutException catch (e) {
        throw _timeout(dur, e);
      } on http.ClientException catch (e) {
        throw _network(e);
      } on SocketException catch (e) {
        throw _network(e);
      }
      if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
        return streamed;
      }
      String text = '';
      try {
        text = await streamed.stream.bytesToString().timeout(dur);
      } on TimeoutException catch (e) {
        throw _timeout(dur, e);
      } on http.ClientException {
        text = '';
      } on SocketException {
        text = '';
      }
      final AiError error = _httpError(
        streamed.statusCode,
        _snippet(text),
        retryAfter: _retryAfterOfStream(streamed),
      );
      if (!error.retryable || attempt >= maxRetries) throw error;
      attempt++;
      await Future<void>.delayed(_backoff(attempt, error.retryAfter));
    }
  }

  /// 保证本次请求与同一 client 上一次请求的起始间隔 ≥ [minRequestGap]
  /// （用真实时钟：间隔只削峰，不额外拖慢已较慢的轮次）。
  Future<void> _throttleRoundGap() async {
    final DateTime now = DateTime.now();
    final DateTime? prev = _lastRequestStartedAt;
    _lastRequestStartedAt = now;
    if (prev == null) return;
    final Duration rest = minRequestGap - now.difference(prev);
    if (rest > Duration.zero) {
      await Future<void>.delayed(rest);
    }
  }

  Map<String, dynamic> _decodeJsonObject(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const AiError(AiErrorKind.format, '响应体为空');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw AiError(AiErrorKind.format, '响应不是合法 JSON：${e.message}', cause: e);
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const AiError(AiErrorKind.format, '响应顶层不是 JSON 对象');
  }

  LlmChatResult _parseNonStreamResult(Map<String, dynamic> root) {
    final rawChoices = root['choices'];
    if (rawChoices is! List || rawChoices.isEmpty) {
      throw const AiError(AiErrorKind.format, '响应缺少 choices');
    }
    final first = rawChoices.first;
    if (first is! Map) {
      throw const AiError(AiErrorKind.format, 'choices[0] 不是对象');
    }
    final choice = Map<String, dynamic>.from(first);

    String? content;
    List<AiToolCall> toolCalls = const [];
    final rawMessage = choice['message'];
    if (rawMessage is Map) {
      final message = Map<String, dynamic>.from(rawMessage);
      content = _contentToString(message['content']);
      final rawCalls = message['tool_calls'];
      if (rawCalls is List) {
        toolCalls = rawCalls.map((e) {
          if (e is! Map) {
            throw const AiError(AiErrorKind.format, 'tool_calls 元素不是对象');
          }
          return AiToolCall.fromWire(Map<String, dynamic>.from(e));
        }).toList(growable: false);
      }
    } else if (rawMessage != null) {
      throw const AiError(AiErrorKind.format, 'message 不是对象');
    }

    return LlmChatResult(
      content: content,
      toolCalls: toolCalls,
      finishReason: choice['finish_reason'] as String?,
      model: root['model'] as String?,
    );
  }

  // ------------------------------------------------------------- 辅助

  static String? _contentToString(Object? content) {
    if (content == null) return null;
    if (content is String) return content.isEmpty ? null : content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final e in content) {
        if (e is Map && e['type'] == 'text') {
          final t = e['text'];
          if (t is String) buffer.write(t);
        }
      }
      return buffer.isEmpty ? null : buffer.toString();
    }
    return null;
  }

  static String _snippet(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    return s.length <= 500 ? s : '${s.substring(0, 500)}…';
  }

  static String _durLabel(Duration d) =>
      d.inMilliseconds < 1000 ? '${d.inMilliseconds} ms' : '${d.inSeconds} s';

  /// `Retry-After` 头（秒）→ 等待时长；HTTP-date 或缺失 → null；≤0 视为立即。
  static Duration? _retryAfterOf(http.Response response) =>
      _parseRetryAfter(response.headers['retry-after']);

  static Duration? _retryAfterOfStream(http.StreamedResponse response) =>
      _parseRetryAfter(response.headers['retry-after']);

  static Duration? _parseRetryAfter(String? raw) {
    final int? seconds = int.tryParse(raw?.trim() ?? '');
    if (seconds == null) return null; // HTTP-date 日期串不解析，走指数退避。
    return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
  }

  /// 重试等待：优先服务端 [retryAfter]（`0` 表示立即）；否则指数 1→2→4s
  /// （封顶 8s）加 0~300ms 随机抖动，打散可能同时发生的重试。
  static Duration _backoff(int attempt, Duration? retryAfter) {
    if (retryAfter != null) return retryAfter;
    final int secs = 1 << (attempt - 1);
    return Duration(
      seconds: secs > 8 ? 8 : secs,
      milliseconds: _jitter.nextInt(301),
    );
  }

  static final Random _jitter = Random();

  AiError _timeout(Duration dur, Object cause) =>
      AiError(AiErrorKind.timeout,
          '请求超时（超过 ${_durLabel(dur)}）：${_describe(cause)}',
          cause: cause);

  AiError _network(Object cause) => AiError(
      AiErrorKind.network, '网络错误：${_describe(cause)}', cause: cause);

  AiError _httpError(int status, String message, {Duration? retryAfter}) =>
      AiError(
        AiErrorKind.http,
        'HTTP $status${message.isEmpty ? '' : '：$message'}',
        statusCode: status,
        retryAfter: retryAfter,
      );

  static String _describe(Object cause) => cause.toString();

  /// 释放自建 http.Client（注入的客户端由注入方管理）。
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// 流式 SSE 累积器：按 index 合并 tool_calls、拼接文本，逐段回调。
class _SseAccumulator {
  _SseAccumulator(this.onDelta);

  final void Function(LlmDelta)? onDelta;
  final StringBuffer _content = StringBuffer();
  final Map<int, _PartialToolCall> _toolCalls = {};
  String? _finishReason;
  String? _model;
  bool _finished = false;

  /// 处理一行 SSE。返回 true 表示遇到 `data: [DONE]`，应停止。
  bool feed(String line) {
    if (line.isEmpty) return false;
    if (!line.startsWith('data:')) return false; // 心跳/注释行忽略
    final payload = line.substring('data:'.length).trim();
    if (payload.isEmpty) return false;
    if (payload == '[DONE]') {
      _finished = true;
      return true;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (e) {
      throw AiError(AiErrorKind.format, 'SSE data 不是合法 JSON：${e.message}',
          cause: e);
    }
    if (decoded is! Map) {
      throw const AiError(AiErrorKind.format, 'SSE data 顶层不是 JSON 对象');
    }
    final root = Map<String, dynamic>.from(decoded);
    _model ??= root['model'] as String?;

    final rawChoices = root['choices'];
    if (rawChoices is List) {
      for (final e in rawChoices) {
        if (e is! Map) continue;
        _applyChoice(Map<String, dynamic>.from(e));
      }
    }
    return false;
  }

  void _applyChoice(Map<String, dynamic> choice) {
    final delta = choice['delta'];
    Map<String, dynamic>? src;
    if (delta is Map) {
      src = Map<String, dynamic>.from(delta);
    } else {
      final message = choice['message'];
      if (message is Map) src = Map<String, dynamic>.from(message);
    }
    if (src != null) _applyDelta(src);

    final fr = choice['finish_reason'];
    if (fr is String && fr.isNotEmpty) _finishReason = fr;
  }

  void _applyDelta(Map<String, dynamic> delta) {
    String? contentDelta;
    final content = delta['content'];
    if (content is String && content.isNotEmpty) {
      _content.write(content);
      contentDelta = content;
    } else if (content is List) {
      final buffer = StringBuffer();
      for (final e in content) {
        if (e is Map && e['type'] == 'text') {
          final t = e['text'];
          if (t is String && t.isNotEmpty) {
            buffer.write(t);
            _content.write(t);
          }
        }
      }
      contentDelta = buffer.isEmpty ? null : buffer.toString();
    }

    final deltas = <LlmToolCallDelta>[];
    final rawCalls = delta['tool_calls'];
    if (rawCalls is List) {
      for (final e in rawCalls) {
        if (e is! Map) continue;
        final call = Map<String, dynamic>.from(e);
        final index = (call['index'] as num?)?.toInt() ?? 0;
        final partial = _toolCalls.putIfAbsent(index, _PartialToolCall.new);

        String? idFrag;
        final id = call['id'];
        if (id is String && id.isNotEmpty) {
          partial.id.write(id);
          idFrag = id;
        }

        String? nameFrag;
        String? argFrag;
        final fn = call['function'];
        if (fn is Map) {
          final name = fn['name'];
          if (name is String && name.isNotEmpty) {
            partial.name.write(name);
            nameFrag = name;
          }
          final args = fn['arguments'];
          if (args is String && args.isNotEmpty) {
            partial.args.write(args);
            argFrag = args;
          }
        }
        deltas.add(LlmToolCallDelta(
          index: index,
          id: idFrag,
          functionName: nameFrag,
          argumentsDelta: argFrag,
        ));
      }
    }

    if (contentDelta != null || deltas.isNotEmpty) {
      onDelta?.call(LlmDelta(
        contentDelta: contentDelta,
        toolCallDeltas: deltas,
      ));
    }
  }

  LlmChatResult result() {
    final content = _content.isEmpty ? null : _content.toString();
    final calls = <AiToolCall>[];
    final indexes = _toolCalls.keys.toList()..sort();
    for (final i in indexes) {
      final p = _toolCalls[i]!;
      final id = p.id.toString();
      final name = p.name.toString();
      final args = p.args.toString();
      if (id.isEmpty && name.isEmpty && args.isEmpty) continue;
      calls.add(AiToolCall(id: id, name: name, argumentsJson: args));
    }
    return LlmChatResult(
      content: content,
      toolCalls: calls,
      finishReason: _finished ? (_finishReason ?? 'stop') : _finishReason,
      model: _model,
    );
  }
}

/// 流式 tool_call 按 index 的累积中间态。
class _PartialToolCall {
  final StringBuffer id = StringBuffer();
  final StringBuffer name = StringBuffer();
  final StringBuffer args = StringBuffer();
}
