import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/services/ai/ai_error.dart';
import 'package:plai/services/ai/llm_client.dart';
import 'package:plai/services/ai/models/ai_message.dart';
import 'package:plai/services/ai/models/ai_tool.dart';

/// 构造注入 MockClient 的 LlmClient。
LlmClient clientFor(
  Future<http.Response> Function(http.Request) handler, {
  String baseUrl = 'https://api.example.com/v1',
  String apiKey = 'sk-test',
  String model = 'gpt-4o',
  Duration totalTimeout = const Duration(seconds: 5),
}) =>
    LlmClient(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      httpClient: MockClient(handler),
      totalTimeout: totalTimeout,
    );

http.Response _jsonOk(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _textChoice({
  String? content = '你好',
  List<Map<String, dynamic>>? toolCalls,
  String? finishReason = 'stop',
  String role = 'assistant',
}) {
  final message = <String, dynamic>{'role': role};
  if (content != null) message['content'] = content;
  if (toolCalls != null) message['tool_calls'] = toolCalls;
  return {
    'index': 0,
    'message': message,
    'finish_reason': finishReason,
  };
}

String _sse(Map<String, dynamic> payload) =>
    'data: ${jsonEncode(payload)}\n';

void main() {
  group('AiMessage wire 编码', () {
    test('system/user/assistant/tool 便捷构造', () {
      expect(AiMessage.system('你是助手').toRequestJson(),
          {'role': 'system', 'content': '你是助手'});
      expect(AiMessage.user('你好').toRequestJson(),
          {'role': 'user', 'content': '你好'});
      expect(AiMessage.assistantText('回复').toRequestJson(),
          {'role': 'assistant', 'content': '回复'});
      expect(AiMessage.tool(toolCallId: 'c1', content: 'ok').toRequestJson(),
          {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'});
    });

    test('tool 消息缺 tool_call_id 抛 FormatException', () {
      final m = AiMessage.tool(toolCallId: '', content: 'x');
      expect(m.toRequestJson, throwsFormatException);
    });

    test('assistant 回传 tool_calls 编码为 type:function', () {
      final m = AiMessage.assistantToolCalls(
          [const AiToolCall(id: 'c1', name: 'fn', argumentsJson: '{}')]);
      final json = m.toRequestJson();
      expect(json['content'], '');
      expect(json['tool_calls'], [
        {
          'id': 'c1',
          'type': 'function',
          'function': {'name': 'fn', 'arguments': '{}'},
        }
      ]);
    });

    test('userImages：文本段 + 图 data URI / http url', () {
      final m = AiMessage.userImages(
        text: '看这张图',
        images: [
          AiImagePart.data(base64: 'QUFB', mime: 'image/png'),
          AiImagePart.uri('https://cdn.example.com/x.png'),
        ],
      );
      final content = m.toRequestJson()['content'] as List;
      expect(content, hasLength(3));
      expect(content[0], {'type': 'text', 'text': '看这张图'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,QUFB'},
      });
      expect(content[2], {
        'type': 'image_url',
        'image_url': {'url': 'https://cdn.example.com/x.png'},
      });
    });

    test('functionTool 生成带 type:function 的工具定义', () {
      expect(
        functionTool(
          name: 'create_task',
          description: '创建任务',
          parameters: const {'type': 'object'},
        ),
        {
          'type': 'function',
          'function': {
            'name': 'create_task',
            'description': '创建任务',
            'parameters': {'type': 'object'},
          },
        },
      );
    });
  });

  group('请求组装', () {
    test('url 拼接：自动补 /chat/completions，兼容 /v1 与尾斜杠', () async {
      final cases = <String, String>{
        'https://api.example.com': 'https://api.example.com/chat/completions',
        'https://api.example.com/': 'https://api.example.com/chat/completions',
        'https://api.example.com/v1': 'https://api.example.com/v1/chat/completions',
        'https://api.example.com/v1/':
            'https://api.example.com/v1/chat/completions',
        'https://api.example.com/v1/chat/completions':
            'https://api.example.com/v1/chat/completions',
      };
      for (final entry in cases.entries) {
        Uri? seen;
        final client = clientFor(
          (req) async {
            seen = req.url;
            return _jsonOk({
              'model': 'gpt-4o',
              'choices': [_textChoice()],
            });
          },
          baseUrl: entry.key,
        );
        await client.chat(messages: [AiMessage.user('hi')]);
        expect(seen!.toString(), entry.value, reason: 'baseUrl: ${entry.key}');
      }
    });

    test('method/headers/基础 body', () async {
      http.Request? captured;
      final client = clientFor((req) async {
        captured = req;
        return _jsonOk({
          'model': 'gpt-4o',
          'choices': [_textChoice()],
        });
      });
      await client.chat(
        messages: [
          AiMessage.system('你是助手'),
          AiMessage.user('写首诗'),
        ],
        temperature: 0.7,
      );

      final req = captured!;
      expect(req.method, 'POST');
      expect(req.headers['authorization'], 'Bearer sk-test');
      expect(req.headers['content-type'], startsWith('application/json'));

      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-4o');
      expect(body['stream'], false);
      expect(body['temperature'], 0.7);
      expect(body.containsKey('tools'), false);
      expect(body.containsKey('tool_choice'), false);
      expect(body.containsKey('response_format'), false);
      final messages = body['messages'] as List;
      expect(messages, hasLength(2));
      expect(messages[0], {'role': 'system', 'content': '你是助手'});
      expect(messages[1], {'role': 'user', 'content': '写首诗'});
    });

    test('apiKey 为空不发送 Authorization', () async {
      http.Request? captured;
      final client = clientFor((req) async {
        captured = req;
        return _jsonOk({
          'model': 'm',
          'choices': [_textChoice()],
        });
      }, apiKey: '');
      await client.chat(messages: [AiMessage.user('hi')]);
      expect(captured!.headers['authorization'], isNull);
      expect(captured!.headers['content-type'], startsWith('application/json'));
    });

    test('可选字段：tools/tool_choice/jsonMode/temperature=null', () async {
      http.Request? captured;
      final client = clientFor((req) async {
        captured = req;
        return _jsonOk({
          'model': 'm',
          'choices': [_textChoice(content: '{"ok":true}', finishReason: 'stop')],
        });
      });

      await client.chat(
        messages: [AiMessage.user('hi')],
        tools: [
          functionTool(
            name: 'get_weather',
            parameters: const {
              'type': 'object',
              'properties': {'city': {'type': 'string'}},
            },
          ),
        ],
        toolChoice: {'type': 'function', 'function': {'name': 'get_weather'}},
        jsonMode: true,
        temperature: null,
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.containsKey('temperature'), false);
      expect((body['tools'] as List).single, {
        'type': 'function',
        'function': {
          'name': 'get_weather',
          'parameters': {
            'type': 'object',
            'properties': {'city': {'type': 'string'}},
          },
        },
      });
      expect(body['tool_choice'],
          {'type': 'function', 'function': {'name': 'get_weather'}});
      expect(body['response_format'], {'type': 'json_object'});
    });

    test('默认 temperature=0.3，toolChoice 字符串透传', () async {
      http.Request? captured;
      final client = clientFor((req) async {
        captured = req;
        return _jsonOk({
          'model': 'm',
          'choices': [_textChoice()],
        });
      });
      await client.chat(
        messages: [AiMessage.user('hi')],
        tools: [functionTool(name: 'fn')],
        toolChoice: 'auto',
      );
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['temperature'], 0.3);
      expect(body['tool_choice'], 'auto');
    });

    test('多模态图片消息经 chat 发送 body 含 data URI', () async {
      http.Request? captured;
      final client = clientFor((req) async {
        captured = req;
        return _jsonOk({
          'model': 'm',
          'choices': [_textChoice()],
        });
      });
      await client.chat(messages: [
        AiMessage.userImages(
          text: '识别',
          images: [AiImagePart.data(base64: 'AAAA', mime: 'image/jpeg')],
        ),
      ]);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final message = (body['messages'] as List).single as Map<String, dynamic>;
      final content = message['content'] as List;
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,AAAA'},
      });
    });
  });

  group('非流式结果解析', () {
    test('正常文本回复：content/finishReason/model', () async {
      final client = clientFor((req) async {
        return _jsonOk({
          'id': 'chatcmpl-1',
          'model': 'gpt-4o',
          'choices': [_textChoice(content: '你好！', finishReason: 'stop')],
        });
      });
      final result = await client.chat(messages: [AiMessage.user('hi')]);
      expect(result.content, '你好！');
      expect(result.toolCalls, isEmpty);
      expect(result.finishReason, 'stop');
      expect(result.model, 'gpt-4o');
    });

    test('工具调用回复：content 空 + tool_calls 解析', () async {
      final client = clientFor((req) async {
        return _jsonOk({
          'model': 'gpt-4o',
          'choices': [
            _textChoice(
              content: null,
              finishReason: 'tool_calls',
              toolCalls: [
                {
                  'id': 'call_a',
                  'type': 'function',
                  'function': {
                    'name': 'create_task',
                    'arguments': '{"title":"买牛奶","priority":"normal"}',
                  },
                },
              ],
            ),
          ],
        });
      });
      final result = await client.chat(messages: [AiMessage.user('建任务')]);
      expect(result.content, isNull);
      expect(result.finishReason, 'tool_calls');
      expect(result.toolCalls, hasLength(1));
      final call = result.toolCalls.single;
      expect(call.id, 'call_a');
      expect(call.name, 'create_task');
      expect(call.arguments,
          {'title': '买牛奶', 'priority': 'normal'});
    });

    test('非流式错误映射（关自动重试，纯分类断言）', () async {
      final cases = {
        'auth': http.Response(jsonEncode({'error': {'message': 'bad key'}}), 401),
        'rate': http.Response(jsonEncode({'error': {'message': 'slow down'}}), 429),
        'server': http.Response('upstream broke', 503),
      };
      for (final e in cases.entries) {
        final client = clientFor((req) async => e.value);
        await expectLater(
          client.chat(messages: [AiMessage.user('hi')], maxRetries: 0),
          throwsA(isA<AiError>()
              .having((err) => err.kind, 'kind', AiErrorKind.http)
              .having((err) => err.statusCode, 'status', e.value.statusCode)
              .having((err) => err.message, 'message', contains('HTTP'))),
          reason: 'case: ${e.key}',
        );
      }
    });

    test('网络异常 → AiError.network', () async {
      final client = clientFor((req) async {
        throw http.ClientException('Connection refused', req.url);
      });
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>().having(
            (err) => err.kind, 'kind', AiErrorKind.network)),
      );
    });

    test('Socket 异常 → AiError.network', () async {
      final client = clientFor((req) async {
        throw const SocketException('Connection refused');
      });
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>().having(
            (err) => err.kind, 'kind', AiErrorKind.network)),
      );
    });

    test('非 JSON body / 空 body / choices 缺失 → AiError.format', () async {
      final nonJson = clientFor((req) async => http.Response('oops not json', 200));
      await expectLater(
        nonJson.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.format)),
      );

      final empty = clientFor((req) async => http.Response('', 200));
      await expectLater(
        empty.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.format)),
      );

      final noChoices = clientFor((req) async => _jsonOk({'id': 'x'}));
      await expectLater(
        noChoices.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.format)),
      );
    });

    test('超时 → AiError.timeout', () async {
      final client = clientFor((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _jsonOk({
          'model': 'm',
          'choices': [_textChoice()],
        });
      }, totalTimeout: const Duration(milliseconds: 40));
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.timeout)),
      );
    });
  });

  group('流式 chatStream（SSE）', () {
    test('文本逐段回调 + 聚合', () async {
      final sse = [
        _sse({
          'choices': [
            {'delta': {'role': 'assistant', 'content': '你'}},
          ],
        }),
        _sse({
          'choices': [
            {'delta': {'content': '好'}},
          ],
        }),
        _sse({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
        }),
        'data: [DONE]\n',
      ].join();
      final client = clientFor((req) async => http.Response.bytes(
            utf8.encode(sse),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          ));

      final contentDeltas = <String>[];
      final result = await client.chatStream(
        messages: [AiMessage.user('hi')],
        onDelta: (delta) {
          if (delta.contentDelta != null) contentDeltas.add(delta.contentDelta!);
        },
      );
      expect(contentDeltas, ['你', '好']);
      expect(result.content, '你好');
      expect(result.toolCalls, isEmpty);
      expect(result.finishReason, 'stop');
    });

    test('tool_calls 多 index delta 合并 + 文本混合', () async {
      final sse = [
        _sse({
          'choices': [
            {
              'delta': {
                'role': 'assistant',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'type': 'function',
                    'function': {'name': 'get_weather', 'arguments': ''},
                  },
                ],
              },
            },
          ],
        }),
        _sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 1,
                    'id': 'call_2',
                    'type': 'function',
                    'function': {'name': 'create_task', 'arguments': '{"title":"买'},
                  },
                ],
              },
            },
          ],
        }),
        _sse({
          'choices': [
            {'delta': {'content': '收到'}},
          ],
        }),
        _sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {'index': 0, 'function': {'arguments': '{"city":"beijing"}'}},
                ],
              },
            },
          ],
        }),
        _sse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {'index': 1, 'function': {'arguments': '牛奶"}'}},
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
        'data: [DONE]\n',
      ].join();

      final client = clientFor((req) async => http.Response.bytes(
            utf8.encode(sse),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          ));

      final indexesSeen = <int>[];
      final result = await client.chatStream(
        messages: [AiMessage.user('帮我办两件事')],
        tools: [
          functionTool(name: 'get_weather'),
          functionTool(name: 'create_task'),
        ],
        onDelta: (delta) {
          for (final t in delta.toolCallDeltas) {
            indexesSeen.add(t.index);
          }
        },
      );

      expect(result.content, '收到');
      expect(result.toolCalls, hasLength(2));
      final byId = {for (final t in result.toolCalls) t.id: t};
      expect(byId['call_1']!.name, 'get_weather');
      expect(byId['call_1']!.arguments, {'city': 'beijing'});
      expect(byId['call_2']!.name, 'create_task');
      expect(byId['call_2']!.arguments, {'title': '买牛奶'});
      expect(result.finishReason, 'tool_calls');
      expect(indexesSeen.toSet(), {0, 1});
    });

    test('流式 http 非 2xx → AiError.http', () async {
      final client = clientFor(
          (req) async => http.Response('{"error":"denied"}', 401));
      await expectLater(
        client.chatStream(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.http)
            .having((e) => e.statusCode, 'status', 401)),
      );
    });

    test('流式网络异常 → AiError.network', () async {
      final client = clientFor((req) async {
        throw http.ClientException('connection reset', req.url);
      });
      await expectLater(
        client.chatStream(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.network)),
      );
    });
  });

  group('429/503 瞬时繁忙自动重试', () {
    // Retry-After: 0 → 退避等待为零，测试不真实睡秒级时间。
    http.Response busy(int status) => http.Response(
          '{"error":{"message":"busy"}}',
          status,
          headers: {'retry-after': '0'},
        );

    test('chat：503 一次后成功，请求数 2', () async {
      var calls = 0;
      final client = clientFor((req) async {
        calls++;
        return calls == 1
            ? busy(503)
            : _jsonOk({'model': 'm', 'choices': [_textChoice(content: '恢复')]});
      });
      final result = await client.chat(messages: [AiMessage.user('hi')]);
      expect(result.content, '恢复');
      expect(calls, 2);
    });

    test('chat：429 超过默认 maxRetries 耗尽后抛错', () async {
      var calls = 0;
      final client = clientFor((req) async {
        calls++;
        return busy(429);
      });
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.http)
            .having((e) => e.statusCode, 'status', 429)),
      );
      expect(calls, LlmClient.defaultMaxRetries + 1);
    });

    test('chat：maxRetries 0 遇 503 立即抛不重试', () async {
      var calls = 0;
      final client = clientFor((req) async {
        calls++;
        return busy(503);
      });
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')], maxRetries: 0),
        throwsA(isA<AiError>().having((e) => e.statusCode, 'status', 503)),
      );
      expect(calls, 1);
    });

    test('chat：永久错误 400/401 不重试', () async {
      for (final status in [400, 401]) {
        var calls = 0;
        final client = clientFor((req) async {
          calls++;
          return http.Response('{"error":"denied"}', status);
        });
        await expectLater(
          client.chat(messages: [AiMessage.user('hi')]),
          throwsA(isA<AiError>()
              .having((e) => e.kind, 'kind', AiErrorKind.http)
              .having((e) => e.statusCode, 'status', status)),
        );
        expect(calls, 1, reason: 'HTTP $status 不应自动重试');
      }
    });

    test('chatStream：首段流前 503 一次后成功', () async {
      var calls = 0;
      final client = clientFor((req) async {
        calls++;
        if (calls == 1) return busy(503);
        return http.Response.bytes(
          utf8.encode('data: {"choices":[{"delta":{"content":"好"}}]}\n'
              'data: [DONE]\n'),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      });
      final result = await client.chatStream(messages: [AiMessage.user('hi')]);
      expect(result.content, '好');
      expect(calls, 2);
    });

    test('chatStream：maxRetries 0 遇 503 立即抛', () async {
      var calls = 0;
      final client = clientFor((req) async {
        calls++;
        return busy(503);
      });
      await expectLater(
        client.chatStream(messages: [AiMessage.user('hi')], maxRetries: 0),
        throwsA(isA<AiError>().having((e) => e.statusCode, 'status', 503)),
      );
      expect(calls, 1);
    });
  });

  group('ping 与配置校验', () {
    test('ping 成功即返回（非流式短消息）', () async {
      var called = false;
      final client = clientFor((req) async {
        called = true;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['stream'], false);
        return _jsonOk({
          'model': 'm',
          'choices': [_textChoice()],
        });
      });
      await client.ping();
      expect(called, true);
    });

    test('ping 遇 503 立即抛（连通性测试不自动重试）', () async {
      var calls = 0;
      final client = clientFor((req) async {
        calls++;
        return http.Response('busy', 503, headers: {'retry-after': '0'});
      });
      await expectLater(
        client.ping(),
        throwsA(isA<AiError>().having((e) => e.statusCode, 'status', 503)),
      );
      expect(calls, 1);
    });

    test('base_url 为空 → config', () async {
      final client = clientFor((req) async => _jsonOk({}),
          baseUrl: '', apiKey: 'k', model: 'm');
      await expectLater(
        client.ping(),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.config)),
      );
    });

    test('base_url 非 http(s) → config', () async {
      final client = clientFor((req) async => _jsonOk({}),
          baseUrl: 'example.com', apiKey: 'k', model: 'm');
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.config)),
      );
    });

    test('model 为空 → config', () async {
      final client = clientFor((req) async {
        fail('不应发起网络请求');
      }, baseUrl: 'https://api.example.com/v1', apiKey: 'k', model: '');
      await expectLater(
        client.chat(messages: [AiMessage.user('hi')]),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.config)),
      );
    });

    test('messages 为空 → config', () async {
      final client = clientFor((req) async {
        fail('不应发起网络请求');
      });
      await expectLater(
        client.chat(messages: const []),
        throwsA(isA<AiError>()
            .having((e) => e.kind, 'kind', AiErrorKind.config)),
      );
    });
  });
}
