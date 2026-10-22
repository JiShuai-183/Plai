import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/services/ai/ai_error.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';

/// 用户反馈：「连接测试」正常，但实际对话一直提示异常。
///
/// 根因方向：连接测试只发 `stream:false`、无 tools、一条消息的请求，
/// 而真实对话是 `stream:true` + 工具 schema。这组测试锁定流式路径的
/// 三种「非标准响应」必须给出可定位的错误，而不是静默成空回复。
LlmClient _client(String body, {String contentType = 'application/json'}) =>
    LlmClient(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      model: 'gpt-4o',
      // http.Response(String) 默认按 latin1 编码，中文会直接抛错；用 bytes + charset。
      httpClient: MockClient((http.Request r) async => http.Response.bytes(
            utf8.encode(body),
            200,
            headers: <String, String>{
              'content-type': '$contentType; charset=utf-8',
            },
          )),
      totalTimeout: const Duration(seconds: 5),
    );

void main() {
  group('流式响应的异常形态必须可诊断', () {
    test('流内 error 帧不再被静默丢弃', () async {
      const String sse =
          'data: {"error":{"message":"当前分组额度不足","type":"insufficient_quota"}}\n\n';
      final LlmClient client = _client(sse, contentType: 'text/event-stream');
      await expectLater(
        client.chatStream(messages: <AiMessage>[AiMessage.user('你好')]),
        throwsA(isA<AiError>().having(
          (AiError e) => e.message,
          'message',
          contains('当前分组额度不足'),
        )),
      );
    });

    test('网关忽略 stream 参数、直接回整体 JSON 时按非流式解析', () async {
      final String body = jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'index': 0,
            'message': <String, dynamic>{'role': 'assistant', 'content': '你好呀'},
            'finish_reason': 'stop',
          },
        ],
      });
      final LlmClient client = _client(body);
      final LlmChatResult result =
          await client.chatStream(messages: <AiMessage>[AiMessage.user('你好')]);
      expect(result.content, '你好呀');
    });

    test('非 SSE 也不是 JSON（如 HTML 错误页）时报格式错误并带原文', () async {
      final LlmClient client = _client(
        '<html><body>502 Bad Gateway</body></html>',
        contentType: 'text/html',
      );
      await expectLater(
        client.chatStream(messages: <AiMessage>[AiMessage.user('你好')]),
        throwsA(isA<AiError>()
            .having((AiError e) => e.kind, 'kind', AiErrorKind.format)
            .having((AiError e) => e.message, 'message', contains('502 Bad Gateway'))),
      );
    });

    test('200 但响应体为空时报「流式响应为空」', () async {
      final LlmClient client = _client('');
      await expectLater(
        client.chatStream(messages: <AiMessage>[AiMessage.user('你好')]),
        throwsA(isA<AiError>().having(
          (AiError e) => e.message,
          'message',
          contains('流式响应为空'),
        )),
      );
    });

    test('正常 SSE 仍然逐段拼接', () async {
      const String sse = 'data: {"choices":[{"index":0,"delta":{"content":"你"}}]}\n\n'
          'data: {"choices":[{"index":0,"delta":{"content":"好"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n';
      final LlmClient client = _client(sse, contentType: 'text/event-stream');
      final List<String> deltas = <String>[];
      final LlmChatResult result = await client.chatStream(
        messages: <AiMessage>[AiMessage.user('你好')],
        onDelta: (LlmDelta d) {
          final String? c = d.contentDelta;
          if (c != null) deltas.add(c);
        },
      );
      expect(deltas, <String>['你', '好']);
      expect(result.content, '你好');
    });
  });

  group('错误提示必须带得出线索', () {
    test('400 带 tools 报错时提示不支持工具调用，并保留服务端原文', () {
      const AiError e = AiError(
        AiErrorKind.http,
        'HTTP 400：{"error":{"message":"tools is not supported by this model"}}',
        statusCode: 400,
      );
      final String msg = friendlyAiErrorMessage(e);
      expect(msg, contains('不支持工具调用'));
      expect(msg, contains('tools is not supported'));
    });

    test('400 中文上下文超限也能命中上下文提示', () {
      const AiError e = AiError(
        AiErrorKind.http,
        'HTTP 400：请求上下文长度超限',
        statusCode: 400,
      );
      expect(friendlyAiErrorMessage(e), contains('上下文'));
    });

    test('400 额度不足给出额度提示（连接测试通过不代表还有额度）', () {
      const AiError e = AiError(
        AiErrorKind.http,
        'HTTP 400：账户余额不足',
        statusCode: 400,
      );
      expect(friendlyAiErrorMessage(e), contains('额度'));
    });

    test('网络错误保留底层原因，便于远程排查', () {
      const AiError e = AiError(
        AiErrorKind.network,
        '网络错误：SocketException: Connection reset by peer',
      );
      expect(friendlyAiErrorMessage(e), contains('Connection reset by peer'));
    });

    test('超长原文被截断，提示仍是单行', () {
      final String raw = 'HTTP 400：${'x' * 500}';
      final String msg = friendlyAiErrorMessage(
        AiError(AiErrorKind.http, raw, statusCode: 400),
      );
      expect(msg.contains('\n'), isFalse);
      expect(msg.length, lessThan(400));
    });
  });
}
