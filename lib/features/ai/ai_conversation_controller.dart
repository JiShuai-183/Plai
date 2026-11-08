import 'dart:convert';

import '../../data/models/chat_message.dart';
import '../../data/repositories/chat_repository.dart';
import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/models/ai_message.dart';
import '../../services/ai/models/ai_tool.dart';

enum AiConversationPhase { thinking, querying, editing, writing, summarizing }

/// 一次发送的显示状态。控制器不持有 Widget、BuildContext 或 WidgetRef。
class AiConversationState {
  const AiConversationState({
    this.text = '',
    this.progress = '',
    this.phase = AiConversationPhase.thinking,
    this.running = false,
  });

  final String text;
  final String progress;
  final AiConversationPhase phase;
  final bool running;
}

/// 页面把现有业务工具适配为回调，控制器只编排，不另实现保存/提醒规则。
class AiConversationTool {
  const AiConversationTool({
    required this.name,
    required this.label,
    required this.schema,
    required this.execute,
    this.validate,
    this.intentKey,
    this.describe,
  });

  final String name;
  final String label;
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic>) execute;
  final String? Function(Map<String, dynamic>)? validate;
  final String Function(Map<String, dynamic>)? intentKey;
  final Future<String> Function(Map<String, dynamic>)? describe;
  bool get isWrite => validate != null;
}

/// 模型的写调用只产生提案，只有确认回调返回的草稿才有资格执行。
class AiWriteProposal {
  factory AiWriteProposal({
    required AiConversationTool tool,
    required Map<String, dynamic> args,
    required String description,
    Future<void> Function(Map<String, dynamic>)? onDraftChanged,
  }) =>
      AiWriteProposal._(tool, _copyJsonMap(args), description, onDraftChanged);

  AiWriteProposal._(
    this.tool,
    this._args,
    this._description,
    this._onDraftChanged,
  );

  final AiConversationTool tool;
  Map<String, dynamic> _args;
  String _description;
  final Future<void> Function(Map<String, dynamic>)? _onDraftChanged;
  Future<void> _updates = Future<void>.value();
  Map<String, dynamic> get args => Map.unmodifiable(_copyJsonMap(_args));
  String get description => _description;

  /// Only publish the new draft after its durable checkpoint succeeds.
  Future<void> updateDraft(Map<String, dynamic> args) {
    final next = _copyJsonMap(args);
    final update = _updates.then((_) async {
      await _onDraftChanged?.call(next);
      var description = _description;
      try {
        description = await tool.describe?.call(next) ?? description;
      } catch (_) {}
      _args = _copyJsonMap(next);
      _description = description;
    });
    _updates = update.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return update;
  }
}

Map<String, dynamic> _copyJsonMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

typedef AiConfirmWrites = Future<List<Map<String, dynamic>?>> Function(
  List<AiWriteProposal> proposals,
);

/// 单次发送的请求循环、确认、去重、执行与历史记录。
///
/// 轮数由 App 限制；成功/拒绝/执行失败的操作在本次发送内不重放。
/// 参数无效可以交回模型修正，执行失败则如实展示，由用户重新发起并确认。
class AiConversationController {
  AiConversationController({
    required this.client,
    required this.repository,
    required this.sessionId,
    required this.tools,
    required this.confirmWrites,
    required this.systemPrompt,
    required this.onState,
    required this.onMessagesChanged,
    this.maxRounds = 4,
    Map<String, dynamic> checkpoint = const {},
    this.onCheckpoint,
    this.queueId,
    this.prepareWrites,
  }) : checkpoint = Map<String, dynamic>.from(
         jsonDecode(jsonEncode(checkpoint)) as Map,
       );

  final LlmClient client;
  final IChatRepository repository;
  final int sessionId;
  final List<AiConversationTool> tools;
  final AiConfirmWrites confirmWrites;
  final String systemPrompt;
  final void Function(AiConversationState) onState;
  final void Function() onMessagesChanged;
  final int maxRounds;
  final int? queueId;
  final Future<List<AiWriteProposal>> Function(List<AiWriteProposal>)?
  prepareWrites;
  final Map<String, dynamic> checkpoint;
  final Future<void> Function(Map<String, dynamic>)? onCheckpoint;
  bool hadFailures = false;

  List<Map<String, dynamic>> get _operations =>
      (checkpoint['operations'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Future<void> _record(List<Map<String, dynamic>> operations) async {
    final next = _copyJsonMap({...checkpoint, 'operations': operations});
    await onCheckpoint?.call(_copyJsonMap(next));
    checkpoint
      ..clear()
      ..addAll(next);
  }

  Future<void> _draftWrites = Future<void>.value();

  AiWriteProposal _persistentDraft(
    AiWriteProposal draft, {
    String? initialKey,
  }) {
    var currentKey =
        initialKey ?? '${draft.tool.name}:${draft.tool.intentKey!(draft.args)}';
    return AiWriteProposal(
      tool: draft.tool,
      args: draft.args,
      description: draft.description,
      onDraftChanged: (args) {
        final write = _draftWrites.then((_) async {
          if (_cancelled) throw StateError('当前确认已结束');
          final operations = _operations;
          final index = operations.indexWhere((op) => op['key'] == currentKey);
          if (index < 0 ||
              const {
                'succeeded',
                'skipped',
                'running',
              }.contains(operations[index]['status'])) {
            throw StateError('当前草稿已不能修改');
          }
          final nextKey = '${draft.tool.name}:${draft.tool.intentKey!(args)}';
          if (operations.asMap().entries.any(
            (entry) => entry.key != index && entry.value['key'] == nextKey,
          )) {
            throw StateError('修改后的操作与其他提案重复');
          }
          var description = draft.description;
          try {
            description = await draft.tool.describe?.call(args) ?? description;
          } catch (_) {}
          operations[index] = {
            ...operations[index],
            'key': nextKey,
            'args': _copyJsonMap(args),
            'description': description,
          };
          await _record(operations);
          currentKey = nextKey;
        });
        _draftWrites = write.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return write;
      },
    );
  }

  /// 写入前先保存意图；进程中断后 running 必须视为结果未知。
  Future<String> _executeJournaled(
    AiWriteProposal proposal,
    Map<String, dynamic> args,
  ) async {
    final operations = _operations;
    final key = '${proposal.tool.name}:${proposal.tool.intentKey!(args)}';
    for (final op in operations) {
      if (op['key'] == key && op['status'] == 'succeeded') {
        return op['output'] as String;
      }
    }
    final existing = operations.indexWhere((e) => e['key'] == key);
    final entry = <String, dynamic>{
      'key': key,
      'tool': proposal.tool.name,
      'args': args,
      'description': proposal.description,
      'status': 'running',
    };
    if (existing < 0) {
      operations.add(entry);
    } else {
      operations[existing] = entry;
    }
    await _record(operations);
    String output;
    bool uncertain = false;
    try {
      output = await proposal.tool.execute(args);
    } catch (_) {
      uncertain = true;
      output = _error('执行未完成，请核对数据后重试');
    }
    final success = const {
      'created',
      'updated',
      'completed',
      'reopened',
      'deleted',
    }.contains(_field(output, 'status'));
    hadFailures |= !success;
    entry['status'] = success
        ? 'succeeded'
        : uncertain
        ? 'unknown'
        : 'failed';
    entry['output'] = output;
    await _record(operations);
    return output;
  }

  /// 已有写入记录时只恢复未完成提案，成功项不会重新交给模型生成。
  Future<void> _retryOperations() async {
    final operations = _operations;
    final proposals = <AiWriteProposal>[];
    for (final op in operations) {
      if (op['status'] == 'succeeded' || op['status'] == 'skipped') continue;
      final tool = _tool(op['tool'] as String);
      if (tool == null) {
        hadFailures = true;
        continue;
      }
      proposals.add(
        _persistentDraft(
          AiWriteProposal(
            tool: tool,
            args: Map<String, dynamic>.from(op['args'] as Map),
            description: op['description'] as String,
          ),
          initialKey: op['key'] as String,
        ),
      );
    }
    final lines = <String>[];
    if (proposals.isNotEmpty) {
      final decisions = await confirmWrites(List.unmodifiable(proposals));
      if (_cancelled) return;
      if (decisions.length != proposals.length) {
        throw const AiError(AiErrorKind.format, '确认结果数量不匹配');
      }
      for (int i = 0; i < proposals.length; i++) {
        if (_cancelled) return;
        final p = proposals[i];
        final args = decisions[i];
        if (args == null) {
          final ops = _operations;
          final key = '${p.tool.name}:${p.tool.intentKey!(p.args)}';
          for (final op in ops) {
            if (op['key'] == key) op['status'] = 'skipped';
          }
          await _record(ops);
          lines.add('已跳过：${p.description}');
          continue;
        }
        final validation = p.tool.validate!(args);
        if (validation != null) {
          hadFailures = true;
          lines.add('未完成：$validation');
          continue;
        }
        String description = p.description;
        try {
          description = await p.tool.describe!(args);
        } catch (_) {}
        // 原失败项与编辑后的待执行项在同一检查点更新，途中崩溃不会丢提案。
        final ops = _operations;
        final originalKey = '${p.tool.name}:${p.tool.intentKey!(p.args)}';
        final nextKey = '${p.tool.name}:${p.tool.intentKey!(args)}';
        final alreadySucceeded = ops.any(
          (op) => op['key'] == nextKey && op['status'] == 'succeeded',
        );
        for (final op in ops) {
          if (op['key'] == originalKey &&
              originalKey != nextKey &&
              op['status'] != 'succeeded') {
            op['status'] = 'skipped';
          }
        }
        if (!alreadySucceeded) {
          final pending = <String, dynamic>{
            'key': nextKey,
            'tool': p.tool.name,
            'args': args,
            'description': description,
            'status': 'pending',
          };
          final index = ops.indexWhere((op) => op['key'] == nextKey);
          if (index < 0) {
            ops.add(pending);
          } else {
            ops[index] = pending;
          }
        }
        await _record(ops);
        final output = await _executeJournaled(
          AiWriteProposal(tool: p.tool, args: args, description: description),
          args,
        );
        final success = const {
          'created',
          'updated',
          'completed',
          'reopened',
          'deleted',
        }.contains(_field(output, 'status'));
        lines.add('${success ? '已完成' : '未完成'}：$description');
      }
    }
    if (!_cancelled) {
      await _say(lines.isEmpty ? '已保留此前完成的操作，请核对会话中的结果。' : lines.join('\n'));
    }
  }

  AiConversationState _state = const AiConversationState();
  AiConversationState get state => _state;
  bool _cancelled = false;
  bool _started = false;

  void cancel() {
    _cancelled = true;
    _state = AiConversationState(text: _state.text, phase: _state.phase);
    client.close();
  }

  void _emit({
    String? text,
    String? progress,
    AiConversationPhase? phase,
    bool? running,
  }) {
    if (_cancelled) return;
    _state = AiConversationState(
      text: text ?? _state.text,
      progress: progress ?? _state.progress,
      phase: phase ?? _state.phase,
      running: running ?? _state.running,
    );
    onState(_state);
  }

  AiConversationTool? _tool(String name) {
    for (final tool in tools) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  Future<void> _append(ChatMessage message) async {
    if (_cancelled) return;
    await repository.appendMessage(
      queueId == null
          ? message
          : message.copyWith(
              toolRecords: [
                ...message.toolRecords,
                {'type': 'queue', 'id': queueId},
              ],
            ),
    );
    if (!_cancelled) onMessagesChanged();
  }

  Future<void> _say(String text) => _append(
    ChatMessage(sessionId: sessionId, role: ChatRole.assistant, content: text),
  );

  Future<void> run({
    required List<AiMessage> messages,
    required String userText,
    required bool writeEnabled,
  }) async {
    if (_started) throw StateError('一次发送只能运行一次');
    _started = true;
    if (_cancelled) return;
    final wire = List<AiMessage>.of(messages);
    final schemas = <Map<String, dynamic>>[
      for (final tool in tools)
        if (!tool.isWrite || writeEnabled) tool.schema,
    ];
    final handled = <String>{};
    final outputs = <String>[];
    bool wrote = false;
    bool read = false;
    bool reportedWrites = false;
    _emit(running: true, progress: '正在思考…');
    try {
      if (_operations.isNotEmpty) {
        if (!writeEnabled) {
          throw const AiError(AiErrorKind.config, '请先开启允许 AI 操作 App，再恢复这条消息');
        }
        await _retryOperations();
        return;
      }
      for (int round = 0; round <= maxRounds; round++) {
        if (_cancelled) return;
        final allowTools = round < maxRounds;
        _emit(text: '');
        final result = await client.chatStream(
          messages: wire,
          tools: allowTools ? schemas : null,
          timeout: const Duration(seconds: 60),
          onDelta: (delta) {
            final part = delta.contentDelta;
            if (part != null && part.isNotEmpty) {
              _emit(text: _state.text + part);
            }
          },
        );
        if (_cancelled) return;
        // 文本结果在「空工具调用」退出前处理，不经过写调用分支。
        if (!allowTools || result.toolCalls.isEmpty) {
          _emit(text: result.content ?? '');
          break;
        }
        final calls = <AiToolCall>[
          for (int i = 0; i < result.toolCalls.length; i++)
            AiToolCall(
              id: result.toolCalls[i].id.isEmpty
                  ? 'call_${round}_$i'
                  : result.toolCalls[i].id,
              name: result.toolCalls[i].name,
              argumentsJson: result.toolCalls[i].argumentsJson,
            ),
        ];
        // 工具轮前言不作为最终回复，也不进入历史。
        _emit(text: '', progress: '正在处理…', phase: AiConversationPhase.querying);
        await _append(
          ChatMessage(
            sessionId: sessionId,
            role: ChatRole.assistant,
            content: '',
            toolRecords: [
              {
                'type': 'tool_calls',
                'calls': [
                  for (final call in calls)
                    {
                      'id': call.id,
                      'name': call.name,
                      'arguments': call.argumentsJson,
                    },
                ],
              },
            ],
          ),
        );
        wire.add(AiMessage(role: AiRole.assistant, toolCalls: calls));
        final results = <int, String>{};
        final proposals = <AiWriteProposal>[];
        final indexes = <int>[];
        final keys = <int, String>{};
        final pendingKeys = <String>{};
        bool invalid = false;
        for (int i = 0; i < calls.length; i++) {
          if (_cancelled) return;
          final call = calls[i];
          final tool = _tool(call.name);
          if (tool == null) {
            results[i] = _error('未知工具 ${call.name}');
            continue;
          }
          if (tool.isWrite && !writeEnabled) {
            results[i] = _error('写工具未开启，请到「AI 服务」设置打开「允许 AI 操作 App」');
            continue;
          }
          final Map<String, dynamic> args;
          try {
            args = call.arguments;
          } on FormatException {
            results[i] = _error('工具参数不是合法 JSON 对象');
            invalid = true;
            continue;
          }
          if (!tool.isWrite) {
            read = true;
            try {
              results[i] = await tool.execute(args);
              if (_field(results[i]!, 'error') != null ||
                  _field(results[i]!, 'status') == 'error') {
                hadFailures = true;
              }
            } catch (_) {
              results[i] = _error('数据读取失败');
              hadFailures = true;
            }
            continue;
          }
          final error = tool.validate!(args);
          if (error != null) {
            results[i] = _error(error);
            invalid = true;
            continue;
          }
          final key = '${tool.name}:${tool.intentKey!(args)}';
          keys[i] = key;
          if (handled.contains(key) || !pendingKeys.add(key)) {
            results[i] = _skipped('相同操作本次对话中已处理过，未重复执行');
            continue;
          }
          String description;
          try {
            description = await tool.describe!(args);
          } catch (_) {
            description = tool.label;
          }
          proposals.add(
            AiWriteProposal(
              tool: tool,
              args: Map<String, dynamic>.unmodifiable(args),
              description: description,
            ),
          );
          indexes.add(i);
        }
        final lines = <String>[];
        if (proposals.isNotEmpty) {
          if (_cancelled) return;
          final mergedIntentKeys = <String>[];
          if (prepareWrites != null) {
            final prepared = await prepareWrites!(List.unmodifiable(proposals));
            if (prepared.length != proposals.length ||
                prepared.asMap().entries.any(
                  (entry) =>
                      !identical(entry.value.tool, proposals[entry.key].tool),
                )) {
              throw const AiError(AiErrorKind.format, '准备确认草稿失败，未执行修改');
            }
            proposals
              ..clear()
              ..addAll(prepared);
            final preparedKeys = <String>{};
            for (var k = 0; k < proposals.length;) {
              final proposal = proposals[k];
              final key =
                  '${proposal.tool.name}:${proposal.tool.intentKey!(proposal.args)}';
              // Keep the model's original key as well as the prepared key:
              // preparation may bind a new task-photo baseline on later rounds.
              if (handled.contains(key) || !preparedKeys.add(key)) {
                mergedIntentKeys.add(keys[indexes[k]]!);
                results[indexes[k]] = _skipped('相同操作本次对话中已处理过，未重复执行');
                indexes.removeAt(k);
                proposals.removeAt(k);
              } else {
                k++;
              }
            }
          }
          if (proposals.isNotEmpty) {
            // 待确认草稿也保存；重启后仍需重新确认，不会丢掉后续未处理提案。
            final waiting = _operations;
            for (final p in proposals) {
              final key = '${p.tool.name}:${p.tool.intentKey!(p.args)}';
              if (!waiting.any((op) => op['key'] == key)) {
                waiting.add({
                  'key': key,
                  'tool': p.tool.name,
                  'args': p.args,
                  'description': p.description,
                  'status': 'unconfirmed',
                });
              }
            }
            await _record(waiting);
            final preparedIntentKeys = [
              for (final p in proposals)
                '${p.tool.name}:${p.tool.intentKey!(p.args)}',
            ];
            for (var k = 0; k < proposals.length; k++) {
              proposals[k] = _persistentDraft(proposals[k]);
            }
            _emit(progress: '准备修改…', phase: AiConversationPhase.editing);
            final decisions = await confirmWrites(List.unmodifiable(proposals));
            if (_cancelled) return;
            if (decisions.length != proposals.length) {
              throw const AiError(AiErrorKind.format, '确认结果数量不匹配，未执行修改');
            }
            // 确认完成后一次记录所有未执行意图；中途退出不会遗漏后半批。
            final planned = _operations;
            for (int k = 0; k < proposals.length; k++) {
              final p = proposals[k];
              final args = decisions[k] ?? p.args;
              final originalKey = '${p.tool.name}:${p.tool.intentKey!(p.args)}';
              final nextKey = '${p.tool.name}:${p.tool.intentKey!(args)}';
              if (originalKey != nextKey) {
                for (final op in planned) {
                  if (op['key'] == originalKey && op['status'] != 'succeeded') {
                    op['status'] = 'skipped';
                  }
                }
              }
              final plannedEntry = <String, dynamic>{
                'key': '${p.tool.name}:${p.tool.intentKey!(args)}',
                'tool': p.tool.name,
                'args': args,
                'description': p.description,
                'status': decisions[k] == null ? 'skipped' : 'pending',
              };
              final existing = planned.indexWhere(
                (op) => op['key'] == plannedEntry['key'],
              );
              if (existing < 0) {
                planned.add(plannedEntry);
              } else if (planned[existing]['status'] != 'succeeded') {
                planned[existing] = plannedEntry;
              }
            }
            await _record(planned);
            _emit(progress: '正在执行…', phase: AiConversationPhase.writing);
            for (int k = 0; k < proposals.length; k++) {
              if (_cancelled) return;
              final index = indexes[k];
              final proposal = proposals[k];
              final approved = decisions[k];
              // 无论执行成功、失败或被拒绝，本次流程都不自动重放写操作。
              handled.add(keys[index]!);
              if (approved == null) {
                handled
                  ..add(preparedIntentKeys[k])
                  ..add(
                    '${proposal.tool.name}:${proposal.tool.intentKey!(proposal.args)}',
                  );
                results[index] = _skipped('用户未确认此操作');
                lines.add('已跳过：${proposal.description}');
                continue;
              }
              // 编辑后的草稿也要重新校验，不能沿用模型初始参数的校验结果。
              final args = Map<String, dynamic>.from(approved);
              final validation = proposal.tool.validate!(args);
              if (validation != null) {
                handled.add(preparedIntentKeys[k]);
                hadFailures = true;
                results[index] = _error(validation);
                lines.add('未完成：${proposal.description}（$validation）');
                continue;
              }
              final approvedKey =
                  '${proposal.tool.name}:${proposal.tool.intentKey!(args)}';
              if (approvedKey != keys[index] && handled.contains(approvedKey)) {
                handled.add(preparedIntentKeys[k]);
                results[index] = _skipped('编辑后的操作已处理过，未重复执行');
                continue;
              }
              handled
                ..add(preparedIntentKeys[k])
                ..add(
                  '${proposal.tool.name}:${proposal.tool.intentKey!(proposal.args)}',
                )
                ..add(approvedKey);
              String description = proposal.description;
              try {
                description = await proposal.tool.describe!(args);
              } catch (_) {}
              if (_cancelled) return;
              final output = await _executeJournaled(
                AiWriteProposal(
                  tool: proposal.tool,
                  args: args,
                  description: description,
                ),
                args,
              );
              results[index] = output;
              final status = _field(output, 'status');
              if (const {
                'created',
                'updated',
                'completed',
                'reopened',
                'deleted',
              }.contains(status)) {
                wrote = true;
                lines.add('已完成：$description');
              } else {
                lines.add(
                  '未完成：$description（${_field(output, 'error') ?? '执行结果异常，请核对数据'}）',
                );
              }
            }
          }
          handled.addAll(mergedIntentKeys);
        }
        for (int i = 0; i < calls.length; i++) {
          if (_cancelled) return;
          final output = results[i] ?? _error('操作未执行');
          await _append(
            ChatMessage(
              sessionId: sessionId,
              role: ChatRole.tool,
              content: output,
              toolRecords: [
                {
                  'type': 'tool_result',
                  'tool_call_id': calls[i].id,
                  'name': calls[i].name,
                },
              ],
            ),
          );
          wire.add(AiMessage.tool(toolCallId: calls[i].id, content: output));
          outputs.add(output);
        }
        if (lines.isNotEmpty) {
          reportedWrites = true;
          await _say(lines.join('\n'));
        }
        // 纯写操作由本地执行结果收尾，包括取消和失败，省掉一次模型汇报。
        if (!read && reportedWrites && !invalid) break;
        _emit(progress: '正在整理结果…', phase: AiConversationPhase.summarizing);
      }
      if (_cancelled) return;
      final reply = _state.text.trim();
      final short = reply.isNotEmpty && reply.length < 4;
      String body = reply;
      if (short && wrote) {
        body = '';
      } else if (short && read) {
        _emit(progress: '正在整理结果…', phase: AiConversationPhase.summarizing);
        body = await _finalAnswer(userText, outputs);
        if (body.isEmpty && !wrote) {
          body = '我查到了数据，但没能把它整理成一句话。换个问法再试一次，例如"本月还有哪些没做完的日程"。';
        }
      } else if (short) {
        body = '这个回答不完整，请把问题说得更具体一些（例如"本月还有哪些没做完的日程"），或者直接说你要改什么。';
      }
      _emit(text: '', progress: '');
      if (body.isNotEmpty || !reportedWrites) {
        await _say(body.isEmpty ? '（无文本回复）' : body);
      }
    } on AiError {
      if (!_cancelled && _state.text.trim().isNotEmpty) {
        await _say(_state.text.trim());
      }
      rethrow;
    } finally {
      client.close();
      _emit(text: '', progress: '', running: false);
      if (!_cancelled) {
        await repository.touchSession(sessionId);
        onMessagesChanged();
      }
    }
  }

  Future<String> _finalAnswer(String userText, List<String> outputs) async {
    try {
      final result = await client.chatStream(
        messages: [
          AiMessage.system(systemPrompt),
          AiMessage.user(
            '（系统提示，非用户输入）以下是本轮查询的原始结果。\n'
            '用户的原话：$userText\n请直接用中文一两句话回答，不要调用工具，'
            '不要输出 JSON，不要复述提示。\n查询结果：\n${outputs.join('\n')}',
          ),
        ],
        timeout: const Duration(seconds: 60),
      );
      final text = result.content?.trim() ?? '';
      return text.length >= 6 ? text : '';
    } on AiError {
      hadFailures = true;
      return '';
    }
  }

  static String _error(String error) =>
      jsonEncode({'status': 'error', 'error': error});
  static String _skipped(String note) =>
      jsonEncode({'status': 'skipped', 'note': note});
  static String? _field(String output, String key) {
    try {
      final value = (jsonDecode(output) as Map<String, dynamic>)[key];
      return value is String ? value : null;
    } catch (_) {
      return null;
    }
  }
}
