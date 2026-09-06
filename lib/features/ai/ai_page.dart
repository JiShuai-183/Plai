import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/models/chat_message.dart';
import '../../data/models/chat_session.dart';
import '../../data/repositories/chat_repository.dart';
import '../../routes/app_routes.dart';
import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/models/ai_message.dart';
import '../../services/ai/models/ai_tool.dart';
import '../settings/settings_providers.dart';
import '../timetable/timetable_providers.dart' hide settingsRepositoryProvider;
import 'ai_message_bubble.dart';
import 'ai_providers.dart';
import 'ai_read_tools.dart';
import 'ai_session_drawer.dart';
import 'ai_settings_keys.dart';
import 'ai_timetable_scan.dart';
import 'ai_write_confirm_sheet.dart';
import 'ai_write_tools.dart';

/// AI 对话页：底部导航第 3 位 Tab。
///
/// - AppBar：菜单(历史会话抽屉) / 标题(当前会话名) / 齿轮(→ AI 服务设置)；
/// - 多轮文字对话：历史会话本地持久化、流式回复、上下文按需注入、知情提示。
///
/// 发送/流式流程见 [_handleSend]；上下文注入见 [_composeUserText]。
class AiPage extends ConsumerStatefulWidget {
  const AiPage({super.key});

  @override
  ConsumerState<AiPage> createState() => _AiPageState();
}

class _AiPageState extends ConsumerState<AiPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();

  /// 历史面板开合动画（0 关 → 1 开）。
  late final AnimationController _historyCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// 当前会话 id；null = 尚未建立（空态引导，首条消息时自动创建）。
  int? _sessionId;

  /// 首次加载到会话列表时的自动选中只做一次。
  bool _autoSelectPending = true;

  /// 是否有请求在途（防重复发送 / 禁切换）。
  bool _sending = false;

  /// 流式回复已累积文本（仅存在于 UI 状态，结束后一次性落库）。
  String _streamText = '';

  /// 当前流式所属会话（切换会话后清空）。
  int? _streamSessionId;

  /// 是否有工具查询在途（等待期只显示通用转圈，不展示查了什么）。
  bool _toolRunning = false;

  @override
  void dispose() {
    _inputCtl.dispose();
    _scrollCtl.dispose();
    _historyCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 历史面板

  /// 历史面板宽度：屏宽 82%（夹在 280–400 之间），右侧留一条残留。
  double _historyPanelWidth(double screenWidth) =>
      (screenWidth * 0.82).clamp(280.0, 400.0);

  void _openHistory() {
    if (_sending) {
      _showSnack('正在生成，请稍候');
      return;
    }
    _historyCtrl.forward();
  }

  void _closeHistory() => _historyCtrl.reverse();

  // ------------------------------------------------------------ 知情提示

  /// 首次使用弹知情对话框一次（落 `ai.onboarded`）；返回是否可继续发送。
  Future<bool> _ensureOnboarded() async {
    bool mustShow = false;
    try {
      final s = ref.read(settingsRepositoryProvider);
      final String? v = await s.getValue(AiSettingsKeys.aiOnboarded);
      mustShow = v != '1';
    } catch (_) {
      return true; // 设置仓库不可用（如测试环境无 DB）→ 不打扰。
    }
    if (!mustShow) return true;
    if (!mounted) return false;

    final bool? go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.shield_outlined),
          title: const Text('关于 AI 对话'),
          content: const Text(
            '使用 AI 对话时，你输入的内容以及 AI 查询到的课表/日程数据，'
            '会发送给你在「AI 服务」中自己配置的第三方服务。\n\n'
            'AI 只在回答需要时自动查询你的课表与日程（只读；任何修改都需你逐条确认）；'
            '密钥等设置仅保存在本机。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('去设置'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始使用'),
            ),
          ],
        );
      },
    );
    try {
      await ref.read(settingsRepositoryProvider).setValue(
            AiSettingsKeys.aiOnboarded,
            '1',
          );
    } catch (_) {
      // 落库失败不阻断：下次再弹。
    }
    if (go == false && mounted) {
      Navigator.of(context).pushNamed(AppRoutes.aiServiceSettings);
      return false;
    }
    return true; // true 或点外关闭都视为已知情，可继续。
  }

  // ------------------------------------------------------------ 发送/流式

  Future<void> _handleSend() async {
    final String raw = _inputCtl.text.trim();
    if (raw.isEmpty || _sending) return;
    if (!await _ensureOnboarded()) return;
    if (!mounted) return;

    final LlmConfig cfg;
    try {
      cfg = await ref.read(llmConfigProvider.future);
    } catch (_) {
      _showConfigHint();
      return;
    }
    if (!cfg.usable) {
      _showConfigHint();
      return;
    }
    if (!mounted) return;

    // 建/取会话。
    final IChatRepository repo = ref.read(chatRepositoryProvider);
    int sessionId = _sessionId ?? -1;
    if (_sessionId == null) {
      sessionId = await repo.createSession();
      if (!mounted) return;
      setState(() => _sessionId = sessionId);
      ref.invalidate(sessionsProvider);
    }

    // 组装 wire（历史回放；课表/日程由 AI 按需经只读工具查询，不再注入）。
    final List<ChatMessage> history = await repo.messagesFor(sessionId);
    final List<AiMessage> wire = composeWireMessages(
      userText: raw,
      history: history,
    );

    // 落库用户消息。
    await repo.appendMessage(ChatMessage(
      sessionId: sessionId,
      role: ChatRole.user,
      content: raw,
    ));
    if (_sessionId == sessionId) {
      final String title = _deriveTitle(raw);
      if (title.isNotEmpty) {
        await repo.renameSession(sessionId, title);
      }
    }
    await repo.touchSession(sessionId);
    ref.invalidate(messagesProvider(sessionId));
    ref.invalidate(sessionsProvider);

    if (!mounted) return;
    setState(() {
      _sending = true;
      _streamText = '';
      _streamSessionId = sessionId;
      _toolRunning = false;
      _inputCtl.clear();
    });
    _scrollToBottom();

    final LlmClient client = ref.read(llmClientFactoryProvider)(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
    final List<AiReadTool> tools = aiReadTools;
    // 写工具受 ai.write_enabled 门控：开关关闭时不向模型提供写工具。
    bool writeEnabled = false;
    try {
      writeEnabled = await ref.read(settingsRepositoryProvider).getValue(
                AiSettingsKeys.writeEnabled,
              ) ==
          'true';
    } catch (_) {
      // 读不到按关闭处理。
    }
    final List<Map<String, dynamic>> toolSchemas = <Map<String, dynamic>>[
      for (final AiReadTool t in tools) t.toSchema(),
      if (writeEnabled)
        for (final AiWriteTool t in aiWriteTools) t.toSchema(),
    ];
    // 本次发送流程内已处理过的写调用（name+参数）：再次出现不再弹窗、
    // 不重复执行，直接回传 skipped（防模型重复调用导致二次确认/重复建数据）。
    final Set<String> handledWrites = <String>{};
    try {
      // function-calling 循环：模型发起工具调用 → 本地执行只读查询 →
      // 结果回传，直到给出最终回答；达 [maxToolRounds] 轮后不再提供工具，
      // 强制模型基于已有结果文本收尾。
      for (int round = 0;; round++) {
        final bool allowTools = round < maxToolRounds;
        final LlmChatResult result = await client.chatStream(
          messages: wire,
          tools: allowTools ? toolSchemas : null,
          timeout: const Duration(seconds: 60),
          onDelta: (LlmDelta delta) {
            final String? part = delta.contentDelta;
            if (part == null || part.isEmpty) return;
            if (!mounted) return;
            setState(() => _streamText += part);
            _scrollToBottom();
          },
        );
        final List<AiToolCall> calls = result.toolCalls;
        if (!allowTools || calls.isEmpty) break;

        // ---- 工具轮：assistant(tool_calls) 落库 → 执行 → tool 结果落库回传。
        final String turnText = _streamText.trim();
        // 流式 tool_call id 偶发缺失 → 本地补齐，保证 tool 消息可配对。
        final List<AiToolCall> normalized = <AiToolCall>[
          for (int i = 0; i < calls.length; i++)
            calls[i].id.isEmpty
                ? AiToolCall(
                    id: 'call_${round}_$i',
                    name: calls[i].name,
                    argumentsJson: calls[i].argumentsJson)
                : calls[i],
        ];
        await repo.appendMessage(ChatMessage(
          sessionId: sessionId,
          role: ChatRole.assistant,
          content: turnText,
          toolRecords: <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'tool_calls',
              'calls': <Map<String, dynamic>>[
                for (final AiToolCall c in normalized)
                  <String, dynamic>{
                    'id': c.id,
                    'name': c.name,
                    'arguments': c.argumentsJson,
                  },
              ],
            },
          ],
        ));
        wire.add(AiMessage(
          role: AiRole.assistant,
          text: turnText.isEmpty ? null : turnText,
          toolCalls: normalized,
        ));
        if (!mounted) return;
        setState(() {
          _streamText = '';
          _toolRunning = true;
        });
        ref.invalidate(messagesProvider(sessionId));
        _scrollToBottom();

        // 分流：读工具直接执行；写工具需用户逐条确认后执行。
        final List<int> readIndexes = <int>[];
        final Map<int, AiWriteTool> writeByIndex = <int, AiWriteTool>{};
        for (int i = 0; i < normalized.length; i++) {
          if (findAiReadTool(normalized[i].name) != null) {
            readIndexes.add(i);
          } else if (writeEnabled) {
            final AiWriteTool? wt = findAiWriteTool(normalized[i].name);
            if (wt != null) writeByIndex[i] = wt;
          }
        }

        // 写调用预解析参数（失败直接 error 回传，不弹窗）。
        final Map<int, Map<String, dynamic>> writeArgs =
            <int, Map<String, dynamic>>{};
        for (final int i in writeByIndex.keys) {
          try {
            writeArgs[i] = normalized[i].arguments;
          } on FormatException {
            // 保持缺失 → 执行循环回 error。
          }
        }

        // 写调用三类：参数无效（不弹窗，回 error 让模型自纠）/
        // 意图重复（不弹窗，回 skipped）/ 待确认（弹窗）。
        final Map<int, String> invalidWrites = <int, String>{};
        final List<int> pendingIndexes = <int>[];
        for (final int i in writeByIndex.keys) {
          final Map<String, dynamic>? args = writeArgs[i];
          if (args == null) {
            invalidWrites[i] = '参数不是合法 JSON 对象';
            continue;
          }
          final AiWriteTool wt = writeByIndex[i]!;
          final String? err = wt.validate(args);
          if (err != null) {
            invalidWrites[i] = err;
          } else if (handledWrites.contains(wt.intentKey(args))) {
            continue; // 意图已处理过：既不弹窗也不执行，回 skipped。
          } else {
            pendingIndexes.add(i);
          }
        }

        // 待确认写操作：转成人类可读描述，弹逐条确认/草稿编辑面板（S8）。
        final Map<int, Map<String, dynamic>?> approved =
            <int, Map<String, dynamic>?>{};
        if (pendingIndexes.isNotEmpty) {
          final List<AiWriteConfirmItem> items = <AiWriteConfirmItem>[];
          for (final int i in pendingIndexes) {
            String desc;
            try {
              desc =
                  await writeByIndex[i]!.describe(ref, writeArgs[i]!);
            } catch (_) {
              desc = writeByIndex[i]!.label;
            }
            items.add(AiWriteConfirmItem(
              tool: writeByIndex[i]!,
              args: writeArgs[i]!,
              description: desc,
            ));
          }
          if (!mounted) return;
          final List<Map<String, dynamic>?> decisions =
              await showAiWriteConfirmSheet(context, items: items);
          if (!mounted) return;
          for (int k = 0; k < pendingIndexes.length; k++) {
            approved[pendingIndexes[k]] = decisions[k];
          }
        }

        for (int i = 0; i < normalized.length; i++) {
          final AiToolCall call = normalized[i];
          String output;
          if (readIndexes.contains(i)) {
            output = await _executeTool(call, tools);
          } else if (writeByIndex.containsKey(i)) {
            final Map<String, dynamic>? args = writeArgs[i];
            final AiWriteTool wt = writeByIndex[i]!;
            if (invalidWrites.containsKey(i)) {
              output = jsonEncode(<String, dynamic>{
                'status': 'error',
                'error': invalidWrites[i]!,
              });
            } else if (args != null &&
                handledWrites.contains(wt.intentKey(args))) {
              output = jsonEncode(<String, dynamic>{
                'status': 'skipped',
                'note': '相同操作本次对话中已处理过，未重复执行',
              });
            } else if (approved.containsKey(i) && approved[i] != null) {
              // 用户勾选执行（args 可能经草稿编辑替换——S8）。
              try {
                output = await wt.execute(ref, approved[i] ?? args!);
              } catch (_) {
                output = jsonEncode(<String, dynamic>{
                  'status': 'error',
                  'error': '执行失败',
                });
              }
              handledWrites.add(wt.intentKey(args!));
            } else {
              output = jsonEncode(<String, dynamic>{
                'status': 'skipped',
                'note': '用户未确认此操作',
              });
              if (args != null) handledWrites.add(wt.intentKey(args));
            }
          } else if (!writeEnabled && findAiWriteTool(call.name) != null) {
            output = jsonEncode(<String, dynamic>{
              'status': 'error',
              'error':
                  '写工具未开启，请用户到「AI 服务」设置打开「允许 AI 操作 App」',
            });
          } else {
            output = jsonEncode(<String, dynamic>{
              'status': 'error',
              'error': '未知工具 ${call.name}',
            });
          }
          if (!mounted) return;
          await repo.appendMessage(ChatMessage(
            sessionId: sessionId,
            role: ChatRole.tool,
            content: output,
            toolRecords: <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tool_result',
                'tool_call_id': call.id,
                'name': call.name,
              },
            ],
          ));
          wire.add(AiMessage.tool(toolCallId: call.id, content: output));
        }
        ref.invalidate(messagesProvider(sessionId));
        if (!mounted) return;
        setState(() => _toolRunning = false);
      }

      // 最终回答：一次性落库。
      final String reply = _streamText.trim();
      if (!mounted) return;
      setState(() {
        _streamText = '';
        _streamSessionId = null;
        _toolRunning = false;
      });
      await repo.appendMessage(ChatMessage(
        sessionId: sessionId,
        role: ChatRole.assistant,
        content: reply.isEmpty ? '（无文本回复）' : reply,
      ));
    } on AiError catch (e) {
      await _handleStreamError(repo: repo, sessionId: sessionId, error: e);
      return;
    } finally {
      client.close();
    }
    if (!mounted) return;
    await repo.touchSession(sessionId);
    ref.invalidate(messagesProvider(sessionId));
    ref.invalidate(sessionsProvider);
    setState(() => _sending = false);
    _scrollToBottom();
  }

  /// 执行一个只读工具调用：未知工具 / 参数非法 / 执行异常都返回错误 JSON，
  /// 不向上抛（对话不中断）。
  Future<String> _executeTool(AiToolCall call, List<AiReadTool> tools) async {
    AiReadTool? tool;
    for (final AiReadTool t in tools) {
      if (t.name == call.name) {
        tool = t;
        break;
      }
    }
    if (tool == null) {
      return jsonEncode(<String, dynamic>{'error': '未知工具 ${call.name}'});
    }
    Map<String, dynamic> args;
    try {
      args = call.arguments;
    } on FormatException {
      return jsonEncode(
          <String, dynamic>{'error': '工具参数不是合法 JSON 对象'});
    }
    try {
      return await tool.execute(ref, args);
    } catch (_) {
      return jsonEncode(<String, dynamic>{'error': '数据读取失败'});
    }
  }

  /// 流式中断：已生成部分保留为 assistant 消息，再给可理解错误条。
  Future<void> _handleStreamError({
    required IChatRepository repo,
    required int sessionId,
    required AiError error,
  }) async {
    final String partial = _streamText.trim();
    if (mounted) {
      setState(() {
        _streamText = '';
        _streamSessionId = null;
        _toolRunning = false;
      });
    }
    if (partial.isNotEmpty) {
      await repo.appendMessage(ChatMessage(
        sessionId: sessionId,
        role: ChatRole.assistant,
        content: partial,
      ));
    }
    if (!mounted) return;
    await repo.touchSession(sessionId);
    ref.invalidate(messagesProvider(sessionId));
    ref.invalidate(sessionsProvider);
    setState(() => _sending = false);
    _showSnack(friendlyAiErrorMessage(error));
  }

  /// 首条消息截取为会话标题（最长 24 字）。
  static String _deriveTitle(String raw) {
    final String one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 24 ? one : one.substring(0, 24);
  }

  void _showConfigHint() {
    _showSnackWithAction(
      '尚未启用或未配置对话模型，请先到「AI 服务」设置',
      onAction: () => Navigator.of(context).pushNamed(AppRoutes.aiServiceSettings),
    );
  }

  // ------------------------------------------------------------ 会话切换

  void _selectSession(int? id) {
    if (_sending) {
      _showSnack('正在生成，请稍候');
      return;
    }
    setState(() {
      _sessionId = id;
      _streamSessionId = null;
      _streamText = '';
    });
    _scrollToBottom();
  }

  void _onSessionDeleted(int id) {
    if (_sessionId == id) {
      setState(() => _sessionId = null);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    // 首次有会话列表时自动选中最近一个（只做一次；之后用户操作自行选择）。
    ref.listen(sessionsProvider,
        (AsyncValue<List<ChatSession>>? prev, AsyncValue<List<ChatSession>> next) {
      if (!_autoSelectPending) return;
      final List<ChatSession>? data = next.valueOrNull;
      if (data == null || data.isEmpty) return;
      final int? first = data.first.id;
      if (first == null) return;
      _autoSelectPending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _sessionId != null) return;
        setState(() => _sessionId = first);
        _scrollToBottom();
      });
    });

    final AsyncValue<List<ChatSession>> sessions = ref.watch(sessionsProvider);
    final AsyncValue<List<ChatMessage>> messages =
        _sessionId == null ? const AsyncData(<ChatMessage>[]) : ref.watch(messagesProvider(_sessionId!));

    final String title = _sessionId == null
        ? '新对话'
        : (_displayTitle(_sessionId!, sessions.valueOrNull ?? const []));

    final double panelWidth =
        _historyPanelWidth(MediaQuery.of(context).size.width);

    // 推挤式历史面板：主对话页整体右移（右侧留一条并淡化），
    // 历史面板从左侧滑入。三层：① 主页面 ② 淡化遮罩 ③ 左滑面板。
    return AnimatedBuilder(
      animation: _historyCtrl,
      builder: (BuildContext context, Widget? child) {
        return PopScope(
          canPop: _historyCtrl.value == 0,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop && _historyCtrl.value > 0) _closeHistory();
          },
          child: child!,
        );
      },
      child: Scaffold(
        body: Stack(
          children: [
            // ① 主对话页：打开时整体右移 panelWidth。
            AnimatedBuilder(
              animation: _historyCtrl,
              builder: (BuildContext context, Widget? child) {
                final double t =
                    Curves.easeOutCubic.transform(_historyCtrl.value);
                return Transform.translate(
                  offset: Offset(t * panelWidth, 0),
                  child: child,
                );
              },
              child: _buildMainPage(title, messages),
            ),
            // ② 残留区淡化遮罩（面板开着时点击即关闭）。
            AnimatedBuilder(
              animation: _historyCtrl,
              builder: (BuildContext context, _) {
                final double t = _historyCtrl.value;
                if (t == 0) return const SizedBox.shrink();
                return Positioned.fill(
                  child: GestureDetector(
                    onTap: _closeHistory,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.4 * t),
                    ),
                  ),
                );
              },
            ),
            // ③ 左侧历史面板：从屏外滑入；全关后移出舞台。
            AnimatedBuilder(
              animation: _historyCtrl,
              builder: (BuildContext context, Widget? child) {
                final double t =
                    Curves.easeOutCubic.transform(_historyCtrl.value);
                return Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: panelWidth,
                  child: Offstage(
                    offstage:
                        _historyCtrl.isDismissed && !_historyCtrl.isAnimating,
                    child: Transform.translate(
                      offset: Offset(-panelWidth * (1 - t), 0),
                      child: child,
                    ),
                  ),
                );
              },
              child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                elevation: 16,
                shadowColor: Theme.of(context).colorScheme.shadow,
                child: AiSessionDrawer(
                  selectedId: _sessionId,
                  enabled: !_sending,
                  onClose: _closeHistory,
                  onSelect: _selectSession,
                  onDeleted: _onSessionDeleted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 主对话页（AppBar + 消息区 + 上下文行 + 输入栏）。
  Widget _buildMainPage(
    String title,
    AsyncValue<List<ChatMessage>> messages,
  ) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: '历史对话',
          onPressed: _openHistory,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.settings),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessagesArea(messages)),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessagesArea(AsyncValue<List<ChatMessage>> messages) {
    final ThemeData theme = Theme.of(context);
    // 空会话/无历史 → 引导空态（含隐私一句话）。
    if (_sessionId == null) return _buildEmpty(theme);

    if (messages.hasError && (messages.valueOrNull?.isEmpty ?? true)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('消息加载失败',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.invalidate(messagesProvider(_sessionId!)),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (messages.isLoading && messages.valueOrNull == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // 工具过程消息不渲染：tool 结果与空正文工具轮属于「怎么做的」，
    // 用户只看最终回答（AI 实际做了修改时由回答文本说明）。
    final List<ChatMessage> list = messages.valueOrNull
            ?.where((ChatMessage m) =>
                m.role != ChatRole.tool &&
                !(m.role == ChatRole.assistant &&
                    m.toolRecords.isNotEmpty &&
                    m.content.trim().isEmpty))
            .toList() ??
        const <ChatMessage>[];
    if (list.isEmpty && !_isStreaming) return _buildEmpty(theme);

    // reverse 列表（聊天标准架构）：index 0 在视觉底部，最新消息/
    // 流式占位天然贴住输入框上方；键盘弹出视口收缩时无需滚动即保持对齐。
    final int itemCount = list.length + (_isStreaming ? 1 : 0);
    return ListView.builder(
      controller: _scrollCtl,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (_isStreaming) {
          if (index == 0) {
            if (_toolRunning && _streamText.isEmpty) {
              return const AiToolTraceRow(text: '正在查询…', pending: true);
            }
            return AiMessageBubble(
              role: ChatRole.assistant,
              content: _streamText,
              streaming: true,
            );
          }
          final ChatMessage m = list[list.length - index];
          return AiMessageBubble(role: m.role, content: m.content);
        }
        final ChatMessage m = list[list.length - 1 - index];
        return AiMessageBubble(role: m.role, content: m.content);
      },
    );
  }

  bool get _isStreaming => _sending && _streamSessionId == _sessionId;

  Widget _buildEmpty(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 64, color: scheme.outline),
            const SizedBox(height: 16),
            Text('开始一段对话吧', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '对话内容会发送给你自配的第三方服务；\n'
              'AI 回答需要时会自动查询你的课表与日程。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 「+」更多菜单（参考豆包）：拍照 / 相册 / 发送文件。
  ///
  /// 拍照与相册已接入 S9 课表识别；发送文件的文件解析链路属后续范围。
  Future<void> _showAttachSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('添加内容',
                      style: theme.textTheme.titleMedium),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('拍照识别课表'),
                subtitle: const Text('拍摄课表图片，识别后确认导入'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickAndScanTimetable(fromCamera: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: const Text('相册识别课表'),
                subtitle: const Text('从相册选择课表截图/照片'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickAndScanTimetable(fromCamera: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('发送文件'),
                subtitle: const Text('选择本地文件发给 AI'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSnack('发送文件将在后续版本开放');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// S9 课表识别全流程：选图（相机/相册）→ 视觉识别 → 草稿确认面板 →
  /// 确认项落库。落库经用户在面板中逐条勾选确认（用户显式点按钮发起，
  /// 不受 ai.write_enabled 对话门控约束）。
  Future<void> _pickAndScanTimetable({required bool fromCamera}) async {
    if (_sending) return;
    final LlmConfig cfg;
    try {
      cfg = await ref.read(llmConfigProvider.future);
    } catch (_) {
      _showConfigHint();
      return;
    }
    if (!cfg.usable) {
      _showConfigHint();
      return;
    }
    if (!mounted) return;
    // OCR 引擎：专用服务协议未定，当前仅支持对话模型视觉模式。
    try {
      final String? mode = await ref
          .read(settingsRepositoryProvider)
          .getValue(AiSettingsKeys.ocrMode);
      if (mode == 'provider') {
        _showSnack('专用 OCR 服务即将支持，请先在设置中使用「对话模型」识别');
        return;
      }
    } catch (_) {
      // 读不到按默认 llm 模式继续。
    }

    // 选图（压缩到可上传尺寸）。
    final XFile? photo;
    try {
      photo = await ImagePicker().pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 1600,
      );
    } catch (_) {
      _showSnack('打开相机/相册失败，请检查权限');
      return;
    }
    if (photo == null) return; // 用户取消。
    if (!mounted) return;

    // 识别结果要落进当前学期。
    int? totalWeeks;
    String? semesterName;
    try {
      final semester = await ref.read(currentSemesterProvider.future);
      totalWeeks = semester?.totalWeeks;
      semesterName = semester?.name;
    } catch (_) {
      // 学期读不到 → 下面按未设置提示。
    }
    if (totalWeeks == null) {
      _showSnack('请先到课表页添加学期，再导入课表');
      return;
    }

    // 识别中：不可关闭的进度对话框。
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在识别课表…'),
            ],
          ),
        ),
      ),
    );

    List<Map<String, dynamic>> drafts;
    try {
      drafts = await scanTimetableFromImage(
        ref,
        imagePath: photo.path,
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: cfg.model,
        totalWeeks: totalWeeks,
      );
    } on AiError catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _showSnack(friendlyAiErrorMessage(e));
      return;
    } catch (_) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _showSnack('识别失败，请重试');
      return;
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;
    if (drafts.isEmpty) {
      _showSnack('没有识别出课程，试试更清晰的图片或文字描述');
      return;
    }

    // 草稿确认面板（复用 S8：课程卡可编辑）。
    final AiWriteTool? courseTool = findAiWriteTool('create_course');
    if (courseTool == null) return;
    final List<AiWriteConfirmItem> items = <AiWriteConfirmItem>[
      for (final Map<String, dynamic> args in drafts)
        AiWriteConfirmItem(
          tool: courseTool,
          args: args,
          description: courseTool.describeQuick!(args),
        ),
    ];
    final List<Map<String, dynamic>?> decisions =
        await showAiWriteConfirmSheet(context, items: items);
    if (!mounted) return;

    int created = 0;
    for (final Map<String, dynamic>? args in decisions) {
      if (args == null) continue;
      try {
        final String out = await courseTool.execute(ref, args);
        if (out.contains('"created"')) created++;
      } catch (_) {
        // 单条失败不阻断其余。
      }
    }
    _showSnack(created == drafts.length
        ? '已向「$semesterName」导入 $created 门课程'
        : '已导入 $created/${drafts.length} 门课程');
  }

  /// 标签式输入栏：大圆角胶囊、白底轻投影，左相机钮（S9 接入）+
  /// 右端圆形发送按钮（参考主流聊天 App 输入栏布局）。
  Widget _buildInputBar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canSend = !_sending && _inputCtl.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: SafeArea(
        // 键盘弹出时 Scaffold 已把页面缩到键盘上方；再保留底部安全区
        // 会把输入框顶离键盘一段空白（手势条高度），故此时关闭 bottom。
        top: false,
        bottom: MediaQuery.of(context).viewInsets.bottom == 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '拍照识别（即将开放）',
                icon: const Icon(Icons.photo_camera_outlined, size: 24),
                onPressed: _sending
                    ? null
                    : () => _showSnack('拍照识别课表将在后续版本开放'),
              ),
              Expanded(
                child: TextField(
                  controller: _inputCtl,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  enabled: !_sending,
                  decoration: InputDecoration(
                    hintText: '输入消息',
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 13),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_sending) return;
                    // 多行输入时，回车保留；发送按钮触发发送。
                  },
                ),
              ),
              IconButton.filled(
                tooltip: '发送',
                style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send, size: 20),
                onPressed: canSend ? _handleSend : null,
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(Icons.add, size: 28),
                onPressed: _sending ? null : _showAttachSheet,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 工具

  void _scrollToBottom() {
    // reverse 列表：底部 = offset 0。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtl.hasClients) return;
      if (_scrollCtl.offset <= 0) return;
      _scrollCtl.animateTo(
        0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showSnackWithAction(String message, {required VoidCallback onAction}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(label: '去设置', onPressed: onAction),
      ));
  }
}

/// 当前会话展示标题（会话列表中查不到则回退「新对话」）。
String _displayTitle(int sessionId, List<ChatSession> sessions) {
  for (final ChatSession s in sessions) {
    if (s.id == sessionId) {
      return s.title.trim().isEmpty ? '新对话' : s.title;
    }
  }
  return '新对话';
}
