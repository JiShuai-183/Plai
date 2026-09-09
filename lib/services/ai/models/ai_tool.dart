import 'dart:convert';

/// AI 函数调用声明（OpenAI function 对象：`name` + `arguments`）。
///
/// 用于工具定义与「调用引用」形态（如历史记录里只有 name/参数、还没 id）。
/// wire 上完整的带 id 工具调用用 [AiToolCall]。
class AiFunctionCall {
  const AiFunctionCall({required this.name, required this.argumentsJson});

  /// 函数名。
  final String name;

  /// 参数字符串（JSON 文本，保留原文，不提前解析）。
  final String argumentsJson;

  /// 解析参数为 Map。空串返回 `{}`；非法 JSON 或非对象抛 [FormatException]。
  Map<String, dynamic> get arguments {
    final s = argumentsJson.trim();
    if (s.isEmpty) return const {};
    final decoded = jsonDecode(s);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('function arguments 不是 JSON 对象');
  }

  Map<String, dynamic> toJson() => {'name': name, 'arguments': argumentsJson};

  /// 从 function 对象（`{name, arguments}`）解析。
  factory AiFunctionCall.fromJson(Map<String, dynamic> json) => AiFunctionCall(
        name: (json['name'] as String?) ?? '',
        argumentsJson: (json['arguments'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is AiFunctionCall &&
      other.name == name &&
      other.argumentsJson == argumentsJson;

  @override
  int get hashCode => Object.hash(name, argumentsJson);

  @override
  String toString() => 'AiFunctionCall(name: $name)';
}

/// AI 工具调用（带 id 的完整记录）。
///
/// 两类场景共用：
/// - 请求里 assistant 消息的 `tool_calls[]`（[AiMessage.assistantToolCalls]）；
/// - 响应解析结果（[LlmChatResult.toolCalls]），供工具执行后回传。
class AiToolCall {
  const AiToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  /// 工具调用 id（与后续 role=tool 消息的 tool_call_id 对应）。
  final String id;

  /// 函数名。
  final String name;

  /// 参数字符串（JSON 文本，保留原文）。
  final String argumentsJson;

  /// 解析参数为 Map。空串返回 `{}`；非法 JSON 或非对象抛 [FormatException]。
  Map<String, dynamic> get arguments {
    final s = argumentsJson.trim();
    if (s.isEmpty) return const {};
    final decoded = jsonDecode(s);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('tool arguments 不是 JSON 对象');
  }

  /// 序列化为 assistant 消息里 `tool_calls[]` 的元素（`type: function`）。
  Map<String, dynamic> toWireJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': argumentsJson},
      };

  /// 从 OpenAI 响应/请求的 tool_calls 元素解析（`{id, type, function:{...}}`）。
  factory AiToolCall.fromWire(Map<String, dynamic> json) {
    final function = json['function'];
    final Map<String, dynamic> fn = function is Map
        ? Map<String, dynamic>.from(function)
        : const {};
    return AiToolCall(
      id: (json['id'] as String?) ?? '',
      name: (fn['name'] as String?) ?? '',
      argumentsJson: (fn['arguments'] as String?) ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiToolCall &&
      other.id == id &&
      other.name == name &&
      other.argumentsJson == argumentsJson;

  @override
  int get hashCode => Object.hash(id, name, argumentsJson);

  @override
  String toString() => 'AiToolCall(id: $id, name: $name)';
}

/// 构造一个 `type:function` 的工具定义（OpenAI `tools[]` 数组元素）。
///
/// [parameters] 传 JSON Schema 对象；不传/传入缺少顶层 `type` 的裸对象时，
/// 统一归一为完整 JSON Schema `{"type": "object", ...}`——Moonshot 等严格
/// 服务商会校验顶层 `type: "object"`，裸空对象 `{}` 会直接 400。
Map<String, dynamic> functionTool({
  required String name,
  String? description,
  Map<String, dynamic> parameters = const {
    'type': 'object',
    'properties': <String, dynamic>{},
  },
}) {
  final Map<String, dynamic> params = parameters.containsKey('type')
      ? parameters
      : <String, dynamic>{'type': 'object', ...parameters};
  return {
    'type': 'function',
    'function': {
      'name': name,
      if (description != null && description.isNotEmpty)
        'description': description,
      'parameters': params,
    },
  };
}
