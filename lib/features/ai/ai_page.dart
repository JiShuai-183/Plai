import 'dart:convert';
import 'dart:io';

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
import '../../shared/layout_breakpoints.dart';
import '../../shared/plai_toast.dart';
import '../settings/settings_providers.dart';
import 'ai_attach_panel.dart';
import 'ai_conversation_controller.dart';
import 'ai_message_bubble.dart';
import 'ai_providers.dart';
import 'ai_read_tools.dart';
import 'ai_session_drawer.dart';
import 'ai_settings_keys.dart';
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
  bool _preparing = false;
  AiConversationController? _conversation;

  /// 流式回答增量文本（仅存在于 UI 状态，结束后一次性落库）。用
  /// [ValueNotifier] 只让尾部气泡自更新，避免每个 token 触发整页 setState
  /// （聊天历史长时不卡）。
  final ValueNotifier<String> _streamText = ValueNotifier<String>('');

  /// 待随下一条消息附带的图片本地路径（面板选图/拍照暂存，发送后清空）。
  final List<String> _pendingImages = <String>[];

  /// 单条消息最多附带的图片数。
  static const int _maxPendingImages = 4;

  /// 当前流式所属会话（切换会话后清空）。
  int? _streamSessionId;

  /// 当前阶段的进度提示（用户视角的一句话，如「正在查询你的课表…」）。
  ///
  /// 单条消息要串行发 2~3 次模型请求，每段都可能等十几秒；只给一个固定
  /// 「正在查询…」时用户分不清是在等模型、在查数据还是卡住了。这里按阶段
  /// 更新文案，只让进度行自身重建（同 [_streamText] 的理由）。
  final ValueNotifier<String> _progress = ValueNotifier<String>('');

  /// 当前阶段的图标（思考 / 查询 / 修改 / 整理），随 [_progress] 一起变。
  final ValueNotifier<AiTracePhase> _progressPhase =
      ValueNotifier<AiTracePhase>(AiTracePhase.thinking);

  /// 状态快照缓存：只在「换了一天」或「本次对话里改过数据」后重建。
  ///
  /// 原来每发一句话都重新读一遍课表/日程再拼进 system（省了模型的一次查询，
  /// 却让每条消息都带上同样一大段事实）。实测「今天/这周」类之外的问题
  /// （改到期日、改课程颜色、调课）完全用不到它，纯属拖慢。现在同一天、
  /// 同一份数据内只建一次，后续消息复用同一段文本。
  String? _snapshotText;
  String? _snapshotDay;
  int? _snapshotSessionId;
  List<ChatMessage>? _snapshotMessages;

  /// 更新进度文案与图标（空串 = 无进度行）。
  void _setProgress(String text, AiTracePhase phase) {
    _progress.value = text;
    _progressPhase.value = phase;
  }

  @override
  void dispose() {
    _conversation?.cancel();
    _streamText.dispose();
    _progress.dispose();
    _progressPhase.dispose();
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
    // 抽屉压住输入栏，输入框不该继续保持焦点 —— 否则键盘会盖住抽屉下半部分，
    // 删完会话回到主页面时又会「自己弹出来」。这里统一先收键盘。
    _dismissKeyboard();
    _historyCtrl.forward();
  }

  void _closeHistory() {
    // 删除/切换会话后主页面会重建，输入框若仍持有焦点就会立刻重新弹出键盘；
    // 关闭抽屉时同样先释放焦点。
    _dismissKeyboard();
    _historyCtrl.reverse();
  }

  /// 释放输入框焦点并收起软键盘。
  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

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
            '使用 AI 对话时，你输入的内容、发送的图片以及 AI 查询到的'
            '课表/日程数据，会发送给你在「AI 服务」中自己配置的第三方服务。\n\n'
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
      await ref
          .read(settingsRepositoryProvider)
          .setValue(AiSettingsKeys.aiOnboarded, '1');
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
    if (_sending ||
        _preparing ||
        (_inputCtl.text.trim().isEmpty && _pendingImages.isEmpty)) {
      return;
    }
    _preparing = true;
    try {
      await _sendTurn();
    } on AiError catch (error) {
      if (mounted) {
        _showSnack(friendlyAiErrorMessage(error), kind: PlaiToastKind.error);
      }
    } catch (_) {
      if (mounted) _showSnack('这次处理未完成，请核对数据后重试', kind: PlaiToastKind.error);
    } finally {
      _preparing = false;
      _conversation = null;
      if (mounted) {
        setState(() {
          _sending = false;
          _streamSessionId = null;
          _streamText.value = '';
        });
        _setProgress('', AiTracePhase.thinking);
        _scrollToBottom();
      }
    }
  }

  Future<void> _sendTurn() async {
    final String raw = _inputCtl.text.trim();
    final bool hasImages = _pendingImages.isNotEmpty;
    if (raw.isEmpty && !hasImages) return;
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

    // 附带图片转 data URI（读不到的跳过；仅本次消息进入 wire）。
    final List<String> imageDataUris = <String>[];
    for (final String path in _pendingImages) {
      try {
        final File f = File(path);
        if (f.existsSync()) {
          imageDataUris.add(
            'data:image/jpeg;base64,${base64Encode(f.readAsBytesSync())}',
          );
        }
      } catch (_) {
        // 单张读取失败不影响发送。
      }
    }

    // 组装 wire。发送前先预取一份本地状态快照（方案 B）：今天有什么课、
    // 哪些事没做完、提醒怎么设的——模型据此直接回答，不必为这些最常见
    // 的问题额外发一整轮请求（每轮都要重发约 5 万字符的工具说明）。
    // 读失败只是少这一块，不阻断发送；用户要求「整块一直带」。
    //
    // 快照按「天」缓存：同一天、同一份数据内不复建。会话首句代表示意图
    // （用户此刻想问的正是这些事实），而后续追问大多是改到期日/调课/改颜色，
    // 用不到整段课表与日程列表——每句都重发一遍只会拖慢。
    final List<ChatMessage> history = await repo.messagesFor(sessionId);
    final String day = _todayKey();
    final bool firstInSession = !history.any(
      (ChatMessage m) => m.role == ChatRole.user,
    );
    // 新会话（或用户新建了第二条会话）也要重建，否则会把上一个会话的旧事实带过去。
    final bool sessionChanged = sessionId != _snapshotSessionId;
    final bool changed = !_sameMessages(_snapshotMessages, history);
    String appState;
    if (!sessionChanged &&
        !firstInSession &&
        !changed &&
        day == _snapshotDay &&
        _snapshotText != null) {
      appState = _snapshotText!;
    } else {
      appState = await buildAppStateSnapshot(ref);
      _snapshotText = appState;
      _snapshotDay = day;
      _snapshotSessionId = sessionId;
    }
    _snapshotMessages = List<ChatMessage>.unmodifiable(history);
    final List<AiMessage> wire = composeWireMessages(
      userText: raw,
      history: history,
      imageDataUris: imageDataUris,
      appState: appState,
    );

    // 落库用户消息（附带图片路径存 attachments，历史回放可显示）。
    await repo.appendMessage(
      ChatMessage(
        sessionId: sessionId,
        role: ChatRole.user,
        content: raw,
        attachments: hasImages ? List<String>.of(_pendingImages) : const [],
      ),
    );
    if (_sessionId == sessionId) {
      final String title = _deriveTitle(raw.isEmpty ? '（图片）' : raw);
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
      _streamText.value = '';
      _streamSessionId = sessionId;
      _pendingImages.clear();
      _inputCtl.clear();
    });
    _setProgress('正在思考…', AiTracePhase.thinking);
    _scrollToBottom();

    bool writeEnabled = false;
    try {
      writeEnabled =
          await ref
              .read(settingsRepositoryProvider)
              .getValue(AiSettingsKeys.writeEnabled) ==
          'true';
    } catch (_) {}
    if (!mounted) return;
    final LlmClient client = ref.read(llmClientFactoryProvider)(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
    final controller = AiConversationController(
      client: client,
      repository: repo,
      sessionId: sessionId,
      maxRounds: maxToolRounds,
      systemPrompt: systemPromptWithNow(),
      tools: [
        for (final tool in aiReadTools)
          AiConversationTool(
            name: tool.name,
            label: tool.label,
            schema: tool.toSchema(),
            execute: (args) => tool.execute(ref, args),
          ),
        for (final tool in aiWriteTools)
          AiConversationTool(
            name: tool.name,
            label: tool.label,
            schema: tool.toSchema(),
            execute: (args) => tool.execute(ref, args),
            validate: tool.validate,
            intentKey: tool.intentKey,
            describe: (args) => tool.describe(ref, args),
          ),
      ],
      confirmWrites: (proposals) async {
        if (!mounted) return [for (final _ in proposals) null];
        final items = <AiWriteConfirmItem>[
          for (final proposal in proposals)
            AiWriteConfirmItem(
              tool: findAiWriteTool(proposal.tool.name)!,
              args: Map<String, dynamic>.from(proposal.args),
              description: proposal.description,
              swatchHex: findAiWriteTool(proposal.tool.name)!.swatchHexOf
                  ?.call(proposal.args),
            ),
        ];
        return showAiWriteConfirmSheet(context, items: items);
      },
      onState: (state) {
        if (!mounted) return;
        _streamText.value = state.text;
        _setProgress(state.progress, switch (state.phase) {
          AiConversationPhase.thinking => AiTracePhase.thinking,
          AiConversationPhase.querying => AiTracePhase.querying,
          AiConversationPhase.editing => AiTracePhase.editing,
          AiConversationPhase.writing => AiTracePhase.writing,
          AiConversationPhase.summarizing => AiTracePhase.summarizing,
        });
        _keepStreamBottom();
      },
      onMessagesChanged: () {
        if (!mounted) return;
        ref.invalidate(messagesProvider(sessionId));
        ref.invalidate(sessionsProvider);
        _scrollToBottom();
      },
    );
    _conversation = controller;
    await controller.run(
      messages: wire,
      userText: raw,
      writeEnabled: writeEnabled,
    );
  }

  /// 首条消息截取为会话标题（最长 24 字）。
  static String _deriveTitle(String raw) {
    final String one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 24 ? one : one.substring(0, 24);
  }

  /// 快照缓存用的「今天」（跨天即失效，日期块要换）。
  static String _todayKey() {
    final DateTime d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  /// 两条消息列表是否等价（比 id 序列 + 条数，够用且不看内容）。
  static bool _sameMessages(List<ChatMessage>? a, List<ChatMessage> b) {
    if (a == null || a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _showConfigHint() {
    _showSnackWithAction(
      '尚未启用或未配置对话模型，请先到「AI 服务」设置',
      onAction: () =>
          Navigator.of(context).pushNamed(AppRoutes.aiServiceSettings),
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
      _streamText.value = '';
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
    ref.listen(sessionsProvider, (
      AsyncValue<List<ChatSession>>? prev,
      AsyncValue<List<ChatSession>> next,
    ) {
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
    final AsyncValue<List<ChatMessage>> messages = _sessionId == null
        ? const AsyncData(<ChatMessage>[])
        : ref.watch(messagesProvider(_sessionId!));

    final String title = _sessionId == null
        ? '新对话'
        : (_displayTitle(_sessionId!, sessions.valueOrNull ?? const []));

    final double panelWidth = _historyPanelWidth(
      MediaQuery.of(context).size.width,
    );

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
                final double t = Curves.easeOutCubic.transform(
                  _historyCtrl.value,
                );
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
                final double t = Curves.easeOutCubic.transform(
                  _historyCtrl.value,
                );
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
  Widget _buildMainPage(String title, AsyncValue<List<ChatMessage>> messages) {
    final bool isWide = WideLayoutScope.isWideOf(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: '历史对话',
          onPressed: _openHistory,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        // 平板宽屏时设置入口固定在左侧栏底部，避免同一功能出现两处；
        // 手机端仍保留这里的齿轮，符合原先的单页导航习惯。
        actions: isWide
            ? const <Widget>[]
            : <Widget>[
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: '设置',
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.settings),
                ),
              ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessagesArea(messages)),
          _buildPendingImagesBar(),
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
            Text(
              '消息加载失败',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
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
    final List<ChatMessage> list =
        messages.valueOrNull
            ?.where(
              (ChatMessage m) =>
                  m.role != ChatRole.tool &&
                  !(m.role == ChatRole.assistant &&
                      m.toolRecords.isNotEmpty &&
                      m.content.trim().isEmpty),
            )
            .toList() ??
        const <ChatMessage>[];
    if (list.isEmpty && !_isStreaming) return _buildEmpty(theme);

    // reverse 列表（聊天标准架构）：index 0 在视觉底部，最新消息/
    // 流式占位天然贴住输入框上方；键盘弹出视口收缩时无需滚动即保持对齐。
    final int itemCount = list.length + (_isStreaming ? 1 : 0);
    return ListView.builder(
      controller: _scrollCtl,
      reverse: true,
      // 拖动列表时收起键盘。
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (_isStreaming) {
          if (index == 0) {
            // 还没吐出任何文字（不管是首轮等模型、等 tool_calls、写操作确认
            // 后重新要一句收尾，还是查完等总结）都走进度行，让用户知道
            // 现在卡在哪一步；一有正文就换成流式气泡。
            return ValueListenableBuilder<String>(
              valueListenable: _streamText,
              builder: (BuildContext context, String text, _) {
                if (text.isNotEmpty) {
                  // 流式尾部气泡只监听 _streamText，token 到达仅它自身重建。
                  return AiMessageBubble(
                    role: ChatRole.assistant,
                    content: text,
                    streaming: true,
                  );
                }
                return ValueListenableBuilder<String>(
                  valueListenable: _progress,
                  builder: (BuildContext context, String progress, _) {
                    if (progress.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return AiToolTraceRow(
                      text: progress,
                      pending: true,
                      phase: _progressPhase.value,
                    );
                  },
                );
              },
            );
          }
          final ChatMessage m = list[list.length - index];
          return AiMessageBubble(
            role: m.role,
            content: m.content,
            attachments: m.attachments,
          );
        }
        final ChatMessage m = list[list.length - 1 - index];
        return AiMessageBubble(
          role: m.role,
          content: m.content,
          attachments: m.attachments,
        );
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
            Text('开始一段对话吧', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '对话内容会发送给你自配的第三方服务；\n'
              'AI 回答需要时会自动查询你的课表与日程。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选图（相机/系统相册选择器，压缩到可上传尺寸）后附带进输入框。
  Future<void> _pickAndAttachImage({required bool fromCamera}) async {
    if (_sending) return;
    final XFile? photo;
    try {
      photo = await ImagePicker().pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 1600,
      );
    } catch (_) {
      _showSnack('打开相机/相册失败，请检查权限', kind: PlaiToastKind.error);
      return;
    }
    if (photo == null) return; // 用户取消。
    if (!mounted) return;
    _attachImages(<String>[photo.path]);
  }

  /// 把选中的图片附加到输入框上方预览条（超出上限的忽略并提示）。
  void _attachImages(List<String> paths) {
    if (_sending || paths.isEmpty) return;
    setState(() {
      for (final String path in paths) {
        if (_pendingImages.length >= _maxPendingImages) {
          _showSnack('最多附带 $_maxPendingImages 张图片', kind: PlaiToastKind.error);
          break;
        }
        if (!_pendingImages.contains(path)) _pendingImages.add(path);
      }
    });
  }

  /// 待发送图片预览条：横排缩略图（× 删除）+「+」续加格（参考豆包）。
  Widget _buildPendingImagesBar() {
    if (_pendingImages.isEmpty) return const SizedBox.shrink();
    // 预览缩略图按显示尺寸 × DPR 解码，避免整张原图解码。
    final int thumbCacheSide = (68 * MediaQuery.of(context).devicePixelRatio)
        .round();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 76,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < _pendingImages.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          File(_pendingImages[i]),
                          width: 68,
                          height: 68,
                          cacheWidth: thumbCacheSide,
                          cacheHeight: thumbCacheSide,
                          fit: BoxFit.cover,
                          errorBuilder: (_, Object? e, _) => Container(
                            width: 68,
                            height: 68,
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _pendingImages.removeAt(i)),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.2,
                              ),
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_pendingImages.length < _maxPendingImages)
                GestureDetector(
                  onTap: _sending
                      ? null
                      : () => showAiAttachSheet(
                          context,
                          onCamera: () => _pickAndAttachImage(fromCamera: true),
                          onGalleryPicker: () =>
                              _pickAndAttachImage(fromCamera: false),
                          onAttachPhotos: _attachImages,
                          source: ref.read(aiGallerySourceProvider),
                        ),
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.add,
                      size: 30,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标签式输入栏：大圆角胶囊、白底轻投影，左相机钮（S9 接入）+
  /// 右端圆形发送按钮（参考主流聊天 App 输入栏布局）。
  Widget _buildInputBar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canSend =
        !_sending &&
        (_inputCtl.text.trim().isNotEmpty || _pendingImages.isNotEmpty);
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
                tooltip: '拍照附到消息',
                icon: const Icon(Icons.photo_camera_outlined, size: 24),
                onPressed: _sending
                    ? null
                    : () => _pickAndAttachImage(fromCamera: true),
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
                      horizontal: 10,
                      vertical: 13,
                    ),
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
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send, size: 20),
                onPressed: canSend ? _handleSend : null,
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(Icons.add, size: 28),
                onPressed: _sending
                    ? null
                    : () => showAiAttachSheet(
                        context,
                        onCamera: () => _pickAndAttachImage(fromCamera: true),
                        onGalleryPicker: () =>
                            _pickAndAttachImage(fromCamera: false),
                        onAttachPhotos: _attachImages,
                        source: ref.read(aiGallerySourceProvider),
                      ),
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

  /// 流式期间的跟随：每 token 都 animateTo 会反复打断滚动动画（jank）。
  /// 贴近底部（≤160）直接 jumpTo；只有离底部远才用一次平滑滚动。
  void _keepStreamBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtl.hasClients) return;
      final double offset = _scrollCtl.offset;
      if (offset <= 0) return;
      if (offset <= 160) {
        _scrollCtl.jumpTo(0);
      } else {
        _scrollCtl.animateTo(
          0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String message, {PlaiToastKind kind = PlaiToastKind.normal}) {
    if (!mounted) return;
    showPlaiToast(context, message, kind: kind);
  }

  void _showSnackWithAction(String message, {required VoidCallback onAction}) {
    if (!mounted) return;
    showPlaiToast(
      context,
      message,
      kind: PlaiToastKind.error,
      actionLabel: '去设置',
      onAction: onAction,
    );
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
