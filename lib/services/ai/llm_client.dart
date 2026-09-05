import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
/// - 图片走 data URI（base64），大小由调用方控制，本层不压缩。
class LlmClient {
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

  static String _normalizeBaseUrl(String baseUrl) {
    final t = baseUrl.trim();
    return t.replaceFirst(RegExp(r'/+$'), '');
  }

  static http.Client _newDefaultClient(Duration connectTimeout) {
    final io = HttpClient()..connectionTimeout = connectTimeout;
    return IOClient(io);
  }

  /// 实际请求端点（配置校验：base_url 非空、必须 http(s) 开头）。
  Uri get endpoint {
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
    const suffix = '/chat/completions';
    final url = _baseUrl.endsWith(suffix) ? _baseUrl : _baseUrl + suffix;
    return Uri.parse(url);
  }

  /// 连接性探测：发一条极短 user 消息，非流式成功即连通；
  /// 失败按 [AiError] 抛（如未配置 → config）。
  Future<void> ping({Duration? timeout}) {
    return chat(
      messages: [AiMessage.user('ping')],
      temperature: 0,
      timeout: timeout,
    ).then((_) {});
  }

  /// 非流式对话。返回文本与/或工具调用，另附 finishReason。
  Future<LlmChatResult> chat({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature = 0.3,
    Duration? timeout,
  }) async {
    final body = _buildBody(
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      jsonMode: jsonMode,
      temperature: temperature,
      stream: false,
    );
    final response = await _sendBuffered(body, timeout ?? totalTimeout);
    _ensure2xx(response);
    final root = _decodeJsonObject(response.body);
    return _parseNonStreamResult(root);
  }

  /// 流式对话（SSE）。[onDelta] 逐段回调增量；结束返回聚合结果
  /// （文本拼接 + 按 index 合并好的完整 tool_calls）。
  Future<LlmChatResult> chatStream({
    required List<AiMessage> messages,
    List<Map<String, dynamic>>? tools,
    Object? toolChoice,
    bool jsonMode = false,
    double? temperature = 0.3,
    Duration? timeout,
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

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
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
      throw _httpError(streamed.statusCode, _snippet(text));
    }

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

  Future<http.Response> _sendBuffered(
    Map<String, dynamic> body,
    Duration dur,
  ) async {
    final request = _makeRequest(body);
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

  void _ensure2xx(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw _httpError(response.statusCode, _snippet(response.body));
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

  AiError _timeout(Duration dur, Object cause) =>
      AiError(AiErrorKind.timeout,
          '请求超时（超过 ${_durLabel(dur)}）：${_describe(cause)}',
          cause: cause);

  AiError _network(Object cause) => AiError(
      AiErrorKind.network, '网络错误：${_describe(cause)}', cause: cause);

  AiError _httpError(int status, String message) => AiError(
      AiErrorKind.http,
      'HTTP $status${message.isEmpty ? '' : '：$message'}',
      statusCode: status);

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
