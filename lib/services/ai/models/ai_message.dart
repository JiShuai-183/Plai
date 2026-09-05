import 'ai_tool.dart';

/// 对话消息角色（OpenAI 兼容 wire 角色）。
///
/// 与数据层存储用的 [ChatRole]（无 system）互相独立：本类型只描述发给
/// LLM 的传输层消息，feature 层在存储模型与 wire 消息之间自行转换。
enum AiRole {
  system('system'),
  user('user'),
  assistant('assistant'),
  tool('tool');

  const AiRole(this.code);

  /// wire / 存储交换用的代码。
  final String code;
}

/// 多模态消息里的一段内容（content parts）。
///
/// [AiTextPart]：纯文本段；[AiImagePart]：图片段（data URI）。
sealed class AiContentPart {
  const AiContentPart();

  Map<String, dynamic> toJson();
}

/// 文本内容段（`{type: text, text: ...}`）。
class AiTextPart extends AiContentPart {
  const AiTextPart(this.text);

  /// 文本内容。
  final String text;

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

/// 图片内容段（`{type: image_url, image_url: {url: ...}}`）。
///
/// [imageUrl] 可为 http(s) 链接或 data URI；data URI 用
/// [AiImagePart.data] 构造（`data:<mime>;base64,<base64>`）。
/// 图片大小由调用方压缩控制，本层不做压缩、不改编码。
class AiImagePart extends AiContentPart {
  const AiImagePart.uri(String url) : imageUrl = url;

  /// 用 base64 + mime 构造 data URI（mime 缺省 `image/png`）。
  AiImagePart.data({required String base64, String mime = 'image/png'})
      : imageUrl = 'data:$mime;base64,$base64';

  /// 完整可用的图片 URL（含 data URI）。
  final String imageUrl;

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'image_url', 'image_url': {'url': imageUrl}};

  @override
  bool operator ==(Object other) =>
      other is AiImagePart && other.imageUrl == imageUrl;

  @override
  int get hashCode => imageUrl.hashCode;

  @override
  String toString() => 'AiImagePart(${imageUrl.length > 80 ? '${imageUrl.substring(0, 80)}…' : imageUrl})';
}

/// 发给 LLM 的对话消息（wire 层，只承载 OpenAI 兼容传输结构）。
///
/// 一个 [AiMessage] 表达四类形态之一：
/// - 纯文本：system / user / assistant（[AiMessage.system] 等便捷构造）；
/// - 多模态：user 携带 [parts]（文本 + 一张或多张图）；
/// - 工具执行结果：role=tool + [toolCallId]；
/// - 回传 assistant 工具调用：role=assistant + [toolCalls]。
class AiMessage {
  const AiMessage({
    required this.role,
    this.text,
    this.parts,
    this.toolCallId,
    this.toolCalls,
  });

  AiMessage.system(String text)
      : this(role: AiRole.system, text: text);

  AiMessage.user(String text) : this(role: AiRole.user, text: text);

  AiMessage.assistantText(String text)
      : this(role: AiRole.assistant, text: text);

  /// 带图 user 消息：[text] 可为空，[images] 追加到文本段之后。
  AiMessage.userImages({String text = '', List<AiImagePart> images = const []})
      : this(
          role: AiRole.user,
          parts: [
            if (text.isNotEmpty) AiTextPart(text),
            ...images,
          ],
        );

  /// 工具执行结果回传（多轮工具链把结果喂回模型）。
  AiMessage.tool({required String toolCallId, required String content})
      : this(role: AiRole.tool, text: content, toolCallId: toolCallId);

  /// 回传上一轮 assistant 发起的工具调用（请求需带上这些消息）。
  AiMessage.assistantToolCalls(List<AiToolCall> toolCalls)
      : this(role: AiRole.assistant, toolCalls: toolCalls);

  /// 角色。
  final AiRole role;

  /// 纯文本内容。多模态走 [parts]；role=tool 时存工具执行结果文本。
  final String? text;

  /// 多模态内容段（文本 + 图片）。非空时优先于 [text] 编为 content 数组。
  final List<AiContentPart>? parts;

  /// role=tool 时必填：对应 assistant tool_calls 里的 id。
  final String? toolCallId;

  /// role=assistant 携带的工具调用（多轮工具链回传用）。
  final List<AiToolCall>? toolCalls;

  /// 编码为 OpenAI 请求 messages 数组元素。
  Map<String, dynamic> toRequestJson() {
    final json = <String, dynamic>{'role': role.code};

    if (role == AiRole.tool) {
      final id = toolCallId ?? '';
      if (id.isEmpty) {
        throw const FormatException('tool 消息缺少 tool_call_id');
      }
      json['tool_call_id'] = id;
      json['content'] = text ?? '';
      return json;
    }

    final hasParts = parts?.isNotEmpty ?? false;
    json['content'] = hasParts
        ? parts!.map((p) => p.toJson()).toList(growable: false)
        : (text ?? '');

    if (toolCalls?.isNotEmpty ?? false) {
      json['tool_calls'] =
          toolCalls!.map((t) => t.toWireJson()).toList(growable: false);
    }
    return json;
  }

  @override
  String toString() =>
      'AiMessage(${role.code}${text == null || text!.isEmpty ? '' : ': "$text"'}'
      '${(parts?.length ?? 0) > 0 ? ' parts=${parts!.length}' : ''}'
      '${(toolCalls?.length ?? 0) > 0 ? ' toolCalls=${toolCalls!.length}' : ''})';
}
