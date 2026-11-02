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
import '../../services/ai/models/ai_tool.dart';
import '../../shared/layout_breakpoints.dart';
import '../../shared/plai_toast.dart';
import '../settings/settings_providers.dart';
import 'ai_attach_panel.dart';
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
    final String raw = _inputCtl.text.trim();
    final bool hasImages = _pendingImages.isNotEmpty;
    if ((raw.isEmpty && !hasImages) || _sending) return;
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

    final LlmClient client = ref.read(llmClientFactoryProvider)(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
    final List<AiReadTool> tools = aiReadTools;
    // 写工具受 ai.write_enabled 门控：开关关闭时不向模型提供写工具。
    bool writeEnabled = false;
    try {
      writeEnabled =
          await ref
              .read(settingsRepositoryProvider)
              .getValue(AiSettingsKeys.writeEnabled) ==
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
    // 本次发送里：是否发生过「用户确认后执行的写操作」，以及它们的结果行。
    // 只写不查时，这些结果行就是完整的答复，不必再向模型要一句总结（B）。
    bool wrote = false;
    final List<String> doneLines = <String>[];
    // 本次发送里是否跑过只读查询（决定写操作后还要不要请模型成文）。
    final Set<int> readIndexesSeen = <int>{};
    // 收尾时判断「短答是不是敷衍」用：只要这次查过，短答就可能是合理概括。
    bool hasReadSoFarInSend = false;
    // 最后一轮工具调用的原始输出（模型短答敷衍时的兜底展示）。
    final List<String> lastToolOutputs = <String>[];
    // 上一轮查询的原始输出：本轮（工具轮）开始前先记下来，只有「查完却
    // 只回几个字」时才用得到，正常回答一律忽略。
    try {
      // function-calling 循环：模型发起工具调用 → 本地执行只读查询 →
      // 结果回传，直到给出最终回答；达 [maxToolRounds] 轮后不再提供工具，
      // 强制模型基于已有结果文本收尾。
      for (int round = 0; ; round++) {
        final bool allowTools = round < maxToolRounds;
        // 上一轮（或更早）是否跑过只读查询：写操作收尾时据此决定还要不要
        // 请模型成文。只写不查 → 结果行已足够，直接收尾省掉一整轮。
        final bool hasReadSoFar = readIndexesSeen.isNotEmpty;
        if (round > 0 &&
            wrote &&
            !hasReadSoFar &&
            _streamText.value.trim().isEmpty) {
          break;
        }
        final LlmChatResult result = await client.chatStream(
          messages: wire,
          tools: allowTools ? toolSchemas : null,
          timeout: const Duration(seconds: 60),
          onDelta: (LlmDelta delta) {
            final String? part = delta.contentDelta;
            if (part == null || part.isEmpty) return;
            if (!mounted) return;
            // 只更新尾部气泡（ValueNotifier），不再整页 setState。
            // 已经有了一段结论（模型在工具轮的前言里直接回答了用户）就不再
            // 叠加：否则会打印出两段意思相近的话（2026-11-02 真机「已改好…
            // 已删除…」连着两条）。
            if (_streamText.value.trim().isNotEmpty) return;
            _streamText.value += part;
            _keepStreamBottom();
          },
        );
        final List<AiToolCall> calls = result.toolCalls;
        if (!allowTools || calls.isEmpty) break;

        // ---- 工具轮：assistant(tool_calls) 落库 → 执行 → tool 结果落库回传。
        // 本轮若流出了前言文字（如"我将调用 save_task…"），那是模型对
        // "怎么做"的过程叙述——用户不该看到：不落库、不进 wire，仅清除显示。
        // （最终结果由后续文字轮给出，前置叙述无保留价值。）
        final List<AiToolCall> normalized = <AiToolCall>[
          for (int i = 0; i < calls.length; i++)
            calls[i].id.isEmpty
                ? AiToolCall(
                    id: 'call_${round}_$i',
                    name: calls[i].name,
                    argumentsJson: calls[i].argumentsJson,
                  )
                : calls[i],
        ];
        await repo.appendMessage(
          ChatMessage(
            sessionId: sessionId,
            role: ChatRole.assistant,
            content: '',
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
          ),
        );
        wire.add(AiMessage(role: AiRole.assistant, toolCalls: normalized));
        if (!mounted) return;
        setState(() {
          _streamText.value = '';
        });
        _setProgress('正在处理…', AiTracePhase.querying);
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
        readIndexesSeen.addAll(readIndexes);
        if (readIndexes.isNotEmpty) hasReadSoFarInSend = true;

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
        // 确认卡片（也是后面「已完成：…」结果行的文案来源，故提到外层）。
        final List<AiWriteConfirmItem> items = <AiWriteConfirmItem>[];
        if (pendingIndexes.isNotEmpty) {
          _setProgress(
            readIndexes.isEmpty ? '准备修改…' : '正在查询，随后需要你确认修改…',
            readIndexes.isEmpty ? AiTracePhase.editing : AiTracePhase.querying,
          );
          for (final int i in pendingIndexes) {
            String desc;
            try {
              desc = await writeByIndex[i]!.describe(ref, writeArgs[i]!);
            } catch (_) {
              desc = writeByIndex[i]!.label;
            }
            items.add(
              AiWriteConfirmItem(
                tool: writeByIndex[i]!,
                args: writeArgs[i]!,
                description: desc,
                // 颜色预览：从参数直取（不解析文案），无颜色变更 → null。
                swatchHex: writeByIndex[i]!.swatchHexOf?.call(writeArgs[i]!),
              ),
            );
          }
          if (!mounted) return;
          final List<Map<String, dynamic>?> decisions =
              await showAiWriteConfirmSheet(context, items: items);
          if (!mounted) return;
          for (int k = 0; k < pendingIndexes.length; k++) {
            approved[pendingIndexes[k]] = decisions[k];
          }
          if (!mounted) return;
          _setProgress('正在执行…', AiTracePhase.writing);
        }

        // 用户确认过的写操作：确认文案（describe）在弹面板前就算好了，
        // 写库成功后立刻记下来，本轮结束后一次性落成结果消息——不必等模型
        // 再发一轮「已创建」（那一轮实测要 3~24 秒，而数据早就写进去了）。

        // 写调用 → 它在确认卡片列表里的下标（卡片按 pendingIndexes 顺序排放，
        // 且只有待确认的调用才有卡片）。
        final Map<int, int> cardIndexOf = <int, int>{
          for (int k = 0; k < pendingIndexes.length; k++) pendingIndexes[k]: k,
        };
          lastToolOutputs.clear();

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
              // 写成功 → 立刻把「做成了什么」记下来，循环结束时统一落成一条
              // 结果消息：模型那句更自然的话回来后另起一条新气泡，不再顶替
              // 这一条（用户先生成确认，再看到最终答复）。
              final String status = _statusOf(output) ?? '';
              if (status == 'error' || status == 'not_found') {
                // 失败不是「答复」：带 error 的产物不该免掉收尾回复。
                lastToolOutputs.add(output);
              } else {
                doneLines.add(
                  _doneLineOf(wt, output, items, cardIndexOf[i] ?? -1),
                );
                wrote = true;
              }
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
              'error': '写工具未开启，请用户到「AI 服务」设置打开「允许 AI 操作 App」',
            });
          } else {
            output = jsonEncode(<String, dynamic>{
              'status': 'error',
              'error': '未知工具 ${call.name}',
            });
          }
          if (!mounted) return;
          await repo.appendMessage(
            ChatMessage(
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
            ),
          );
          wire.add(AiMessage.tool(toolCallId: call.id, content: output));
          // 只收读工具的产出：写工具的「成品」是 doneLines 里的结果行，
          // 写失败的错误已在上面单独收。
          if (readIndexes.contains(i)) {
            lastToolOutputs.add(output);
          }
        }
        // 结果消息先落库：用户点完确认就能看到「做成了什么」，下一轮
        // 模型请求（如果还需要）仍在后台跑。
        if (doneLines.isNotEmpty && mounted) {
          await repo.appendMessage(
            ChatMessage(
              sessionId: sessionId,
              role: ChatRole.assistant,
              content: doneLines.join('\n'),
            ),
          );
          doneLines.clear();
        }
        ref.invalidate(messagesProvider(sessionId));
        if (!mounted) return;
        // 工具已跑完，下一趟只是让模型把结果说成人话（这一轮同样可能等十几秒）。
        _setProgress('正在整理结果…', AiTracePhase.summarizing);
      }

      // 最终回答：一次性落库。只写不查时这一轮已经跳过（见循环开头），
      // 此时 reply 为空、由上面的「已完成」结果行承载全部信息。
      final String reply = _streamText.value.trim();
      if (!mounted) return;
      setState(() {
        _streamText.value = '';
        _streamSessionId = null;
      });
      _setProgress('', AiTracePhase.thinking);
      // 只有几个字的「回答」等于没回答（2026-11-02 真机：问「我这个月还有
      // 什么没做完的」，模型回了两个字「这个」）。不把这种半截话留在对话里，
      // 换成一句用户能据此继续操作的说明。
      //
      // 判据必须同时满足三条，否则会误伤正常回答：
      //   · 本次既没执行写操作（写操作的结果行本身就是答复，reply 为空是
      //     应该的——早前漏了这条，把「已完成：新建课程…」也顶掉了）；
      //   · 也没跑过只读查询（查了就有结果，短答可能是合理概括）；
      //   · 原文确实非空且极短（空答复走下面的「（无文本回复）」）。
      final bool tooShort = reply.isNotEmpty && reply.length < 4;
      // 走过一轮「查询 → 却只回两三个字」时，不替模型编造答案（数据是它的
      // 事），把工具实际查到的内容原样摆出来，至少让用户看到事实，而不是
      // 对着「这个」发呆（2026-11-02 真机：问本月未完成，查到了 3 条却只
      // 回了「这个回报」）。
      final String body;
      if (tooShort && hasReadSoFarInSend && !wrote) {
        body =
            '这次没能整理成完整的回答，下面是我查到的原始内容：\n\n'
            '${lastToolOutputs.join('\n\n')}';
      } else if (tooShort && !wrote) {
        body =
            '这个回答不完整，请把问题说得更具体一些（例如"本月还有哪些没做完的日程"），或者直接说你要改什么。';
      } else {
        body = reply;
      }
      if (body.isNotEmpty || !wrote) {
        await repo.appendMessage(
          ChatMessage(
            sessionId: sessionId,
            role: ChatRole.assistant,
            content: body.isEmpty ? '（无文本回复）' : body,
          ),
        );
      }
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
      return jsonEncode(<String, dynamic>{'error': '工具参数不是合法 JSON 对象'});
    }
    try {
      return await tool.execute(ref, args);
    } catch (_) {
      return jsonEncode(<String, dynamic>{'error': '数据读取失败'});
    }
  }

  /// 写工具输出 JSON 里的 status（解析失败返回 null）。
  static String? _statusOf(String output) {
    try {
      final Object? v = (jsonDecode(output) as Map<String, dynamic>)['status'];
      return v is String ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 写操作成功后的结果行：优先用确认面板上那句人话（用户已经看过并点
  /// 过「执行」，与最终结果一致），取不到再退回工具输出里的标题。
  ///
  /// 按 [argIndex] 在确认卡片里定位，而不是按工具名：工具合并成 save_task /
  /// save_course 之后，同一批里的多条写调用工具名相同，按名找会全部命中
  /// 第一张卡片，把「新增 A」「删除 B」都说成「新增 A」。
  static String _doneLineOf(
    AiWriteTool tool,
    String output,
    List<AiWriteConfirmItem> items,
    int argIndex,
  ) {
    String desc = argIndex >= 0 && argIndex < items.length
        ? items[argIndex].description
        : '';
    if (desc.trim().isEmpty) {
      try {
        final Object? t = (jsonDecode(output) as Map<String, dynamic>)['title'];
        desc = t is String && t.trim().isNotEmpty
            ? '${tool.label}「${t.trim()}」'
            : tool.label;
      } catch (_) {
        desc = tool.label;
      }
    }
    return '已完成：$desc';
  }

  /// 流式中断：已生成部分保留为 assistant 消息，再给可理解错误条。
  Future<void> _handleStreamError({
    required IChatRepository repo,
    required int sessionId,
    required AiError error,
  }) async {
    final String partial = _streamText.value.trim();
    if (mounted) {
      setState(() {
        _streamText.value = '';
        _streamSessionId = null;
      });
      _setProgress('', AiTracePhase.thinking);
    }
    if (partial.isNotEmpty) {
      await repo.appendMessage(
        ChatMessage(
          sessionId: sessionId,
          role: ChatRole.assistant,
          content: partial,
        ),
      );
    }
    if (!mounted) return;
    await repo.touchSession(sessionId);
    ref.invalidate(messagesProvider(sessionId));
    ref.invalidate(sessionsProvider);
    setState(() => _sending = false);
    _showSnack(friendlyAiErrorMessage(error), kind: PlaiToastKind.error);
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
