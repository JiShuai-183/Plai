import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/models/chat_message.dart';
import '../../data/models/chat_session.dart';
import '../../data/repositories/chat_repository.dart';
import '../settings/settings_providers.dart';
import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/models/ai_message.dart';
import '../../services/ai/models/ai_tool.dart';
import 'ai_settings_keys.dart';

/// AI 对话仓库（数据层 chat_session / chat_message CRUD）。
final chatRepositoryProvider = Provider<IChatRepository>(
  (ref) => ChatRepository(AppDatabase.instance),
);

/// 全部会话，已按置顶 → 最近活跃排序。
final sessionsProvider = FutureProvider<List<ChatSession>>(
  (ref) => ref.watch(chatRepositoryProvider).listSessions(),
);

/// 某会话的全部消息（插入序）。
final messagesProvider =
    FutureProvider.family<List<ChatMessage>, int>((ref, sessionId) {
  return ref.watch(chatRepositoryProvider).messagesFor(sessionId);
});

/// 对话 LLM 配置（读 `ai.*` 键；失败回退全关全空，页面兜底提示）。
class LlmConfig {
  const LlmConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  final bool enabled;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// 可用 = 开关开 且 baseUrl / model 均已填。
  bool get usable =>
      enabled && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;
}

final llmConfigProvider = FutureProvider<LlmConfig>((ref) async {
  bool enabled = false;
  String baseUrl = '';
  String apiKey = '';
  String model = '';
  try {
    final s = ref.watch(settingsRepositoryProvider);
    enabled = await s.getValue(AiSettingsKeys.llmEnabled) != 'false';
    baseUrl = await s.getValue(AiSettingsKeys.llmBaseUrl) ?? '';
    apiKey = await s.getValue(AiSettingsKeys.llmApiKey) ?? '';
    model = await s.getValue(AiSettingsKeys.llmModel) ?? '';
  } catch (_) {
    // 设置仓库不可用（如测试环境无 DB）→ 兜底不可用配置。
  }
  return LlmConfig(enabled: enabled, baseUrl: baseUrl, apiKey: apiKey, model: model);
});

/// LLM 客户端工厂（widget 测试 override 注入 fake，避免真网络）。
///
/// 与数据仓库同思路：页面只依赖「给我一个按配置构造的 [LlmClient]」，
/// 具体构造/释放由实现负责。
typedef LlmClientFactory = LlmClient Function({
  required String baseUrl,
  String apiKey,
  required String model,
});

final llmClientFactoryProvider = Provider<LlmClientFactory>(
  (ref) => ({
        required String baseUrl,
        String apiKey = '',
        required String model,
      }) =>
          LlmClient(baseUrl: baseUrl, apiKey: apiKey, model: model),
);

/// 系统提示词（首条，固定）。
const String chatSystemPrompt =
    '你是 Plai 助手：一位了解用户课表与日程的学习生活助理。'
    '请用简体中文、简洁友好地回答问题。'
    '你可以调用只读工具查询用户的学期、课程、任务、节次等本地数据；'
    '涉及这类事实（尤其是具体某天的课表/任务）时，先调用工具查询再回答，'
    '不要凭空猜测；需要日期推算时先查 get_date_info。'
    '你也可以调用写工具替用户修改数据：create_task 新建日程、'
    'update_task 修改已有日程（task_id 先从 get_tasks 查）、'
    'update_course 修改课表课程（course_id 先从 get_courses 查）、'
    'set_task_completed 改完成状态；'
    '用户说"提醒/提前X分钟提醒"时用 create_task 的 '
    'remind_minutes 参数表达，不要写进标题或描述。\n'
    '重要规则：\n'
    '1. 确认由 App 自动弹出确认面板完成：你只要发起工具调用即可，'
    '**绝对不要**在回复文字里向用户请求确认、询问"是否执行此操作"；\n'
    '2. 工具执行结果会回传给你：成功就直接简短汇报（如"已创建"），'
    '失败就按错误提示修正参数后重新调用同一条工具，不要转成文字去问用户；\n'
    '3. 只做用户明确要求的操作，不要画蛇添足：创建日程/任务后'
    '**不要**顺手把它标记为完成，也不要追加用户没提的其他修改；\n'
    '3b. 用户一次性给出多件安排（计划、清单、课表文本等）要建成日程时，'
    '在一条回复里**并行发起全部** create_task 调用（一条消息多个工具调用），'
    '不要拆成多轮逐条调用——App 会一次性列出草稿供用户核对；\n'
    '4. 被用户拒绝或跳过的操作不要重试，尊重用户决定；\n'
    '5. 回答时直接给出结果，不要描述你的工作过程'
    '（不要提及调用了什么工具、分几步查询）；'
    '实际修改了数据时逐条简短确认改了什么。\n'
    '6. 用户可能附带图片：图片内容用视觉直接读取。'
    '若用户要求核对课表：先读出图中全部课程，再调用 get_courses 查询'
    '本地课表，逐条比对后明确列出差异（图中多出 / 本地多出 / 信息不一致），'
    '并按用户意图用 update_course / create_course 发起修改（会经用户确认）；'
    '若用户要求把图中课程加入课表，并行发起多条 create_course。\n'
    '若用户消息附带课表/日程上下文，回答时优先结合它；'
    '若未附带也未查到，不得编造用户的课表或日程信息。';

/// 单次发给模型的对话轮数上限（一轮 = 一次用户/AI 交互，
/// 含其中的工具调用与结果消息，截断时整轮丢弃）。
const int maxWireTurns = 20;

/// function-calling 循环轮数上限：单条用户消息内最多发起这么多次工具调用
/// 请求；达到上限后不再提供工具，强制模型基于已有结果文本收尾。
const int maxToolRounds = 4;

/// assistant 消息 toolRecords 中「工具调用」记录的 calls 元素 → wire 结构。
List<AiToolCall> _toolCallsOf(ChatMessage m) {
  for (final Map<String, dynamic> rec in m.toolRecords) {
    if (rec['type'] != 'tool_calls') continue;
    final Object? calls = rec['calls'];
    if (calls is! List) continue;
    return <AiToolCall>[
      for (final Object? c in calls)
        if (c is Map)
          AiToolCall(
            id: (c['id'] as String?) ?? '',
            name: (c['name'] as String?) ?? '',
            argumentsJson: (c['arguments'] as String?) ?? '',
          ),
    ];
  }
  return const <AiToolCall>[];
}

/// tool 消息 toolRecords 中「工具结果」记录的 tool_call_id（缺失给占位 id，
/// 避免 wire 上 tool 消息缺 id 被服务端拒绝）。
String _toolCallIdOf(ChatMessage m) {
  for (final Map<String, dynamic> rec in m.toolRecords) {
    if (rec['type'] != 'tool_result') continue;
    final Object? id = rec['tool_call_id'];
    if (id is String && id.isNotEmpty) return id;
  }
  return 'tool_call';
}

/// 把历史 [ChatMessage] 组装成 wire 消息组（截断的原子单位）：
/// - user / 纯文本 assistant：单消息组；
/// - assistant 携带 tool_calls：开新组，后续连续 tool 结果并入同组；
/// - 前面没有工具轮的孤儿 tool 消息：丢弃；
/// - 收尾时工具轮没等齐结果（如中途失败）：降级为纯文本 assistant，
///   避免 wire 出现「assistant 带工具调用却无结果」的非法序列。
List<List<AiMessage>> _groupHistory(List<ChatMessage> history) {
  final List<List<AiMessage>> groups = <List<AiMessage>>[];
  List<AiMessage>? openToolGroup;
  int pendingResults = 0;

  // 工具轮结果没等齐就遇到别的角色（或历史结束）→ 降级为纯文本，
  // 避免 wire 出现「assistant 带工具调用却无完整结果」的非法序列。
  void closeToolGroup() {
    if (openToolGroup != null && pendingResults > 0) {
      final String head = openToolGroup!.first.text ?? '';
      openToolGroup!
        ..clear()
        ..add(AiMessage.assistantText(head));
    }
    openToolGroup = null;
    pendingResults = 0;
  }

  for (final ChatMessage m in history) {
    switch (m.role) {
      case ChatRole.user:
        closeToolGroup();
        groups.add(<AiMessage>[AiMessage.user(m.content)]);
      case ChatRole.assistant:
        closeToolGroup();
        final List<AiToolCall> calls = _toolCallsOf(m);
        if (calls.isNotEmpty) {
          openToolGroup = <AiMessage>[
            AiMessage(
              role: AiRole.assistant,
              text: m.content.trim().isEmpty ? null : m.content,
              toolCalls: calls,
            ),
          ];
          pendingResults = calls.length;
          groups.add(openToolGroup!);
        } else {
          openToolGroup = null;
          groups.add(<AiMessage>[AiMessage.assistantText(m.content)]);
        }
      case ChatRole.tool:
        if (openToolGroup != null && pendingResults > 0) {
          openToolGroup!.add(AiMessage.tool(
            toolCallId: _toolCallIdOf(m),
            content: m.content,
          ));
          pendingResults--;
        }
        // 孤儿 tool（找不到所属工具轮）：丢弃。
    }
  }
  closeToolGroup();
  return groups;
}

/// 组装发给 LLM 的 messages：
/// `system 提示` → `最近 [maxWireTurns] 轮历史`（超长时补一条截断说明，
/// 且工具轮与其结果消息永不拆散）→ `本次 user 消息`。
///
/// [imageDataUris] 非空时，本次 user 消息为多模态（文本 + 图片 data URI）；
/// 仅本次发送的图片进入 wire（历史消息的图片不回放，控制上下文体积）。
List<AiMessage> composeWireMessages({
  required String userText,
  required List<ChatMessage> history,
  int maxTurns = maxWireTurns,
  List<String> imageDataUris = const <String>[],
}) {
  final List<List<AiMessage>> groups = _groupHistory(history);
  List<List<AiMessage>> kept = groups;
  int dropped = 0;
  if (groups.length > maxTurns) {
    kept = groups.sublist(groups.length - maxTurns);
    dropped = groups
        .take(groups.length - maxTurns)
        .fold(0, (int n, List<AiMessage> g) => n + g.length);
  }

  final List<AiMessage> wire = <AiMessage>[
    AiMessage.system(chatSystemPrompt),
  ];
  if (dropped > 0) {
    wire.add(AiMessage.system(
      '以上只保留最近 $maxTurns 轮对话（更早的 $dropped 条消息已省略）。',
    ));
  }
  for (final List<AiMessage> g in kept) {
    wire.addAll(g);
  }
  wire.add(imageDataUris.isEmpty
      ? AiMessage.user(userText)
      : AiMessage.userImages(
          text: userText,
          images: <AiImagePart>[
            for (final String uri in imageDataUris) AiImagePart.uri(uri),
          ],
        ));
  return wire;
}

/// 把 [AiError] 转成对人类友好的单行中文提示（配置/网络/鉴权/限流/其它分流）。
String friendlyAiErrorMessage(AiError e) {
  switch (e.kind) {
    case AiErrorKind.config:
      return e.message;
    case AiErrorKind.network:
      return '网络连接失败，请检查网络或 Base URL';
    case AiErrorKind.timeout:
      return '连接超时，请检查网络或 Base URL';
    case AiErrorKind.format:
      return '服务响应格式异常：${e.message}';
    case AiErrorKind.http:
      switch (e.statusCode) {
        case 401:
          return 'API 密钥无效或未授权（401），请到「AI 服务」检查';
        case 403:
          return '无访问权限（403），请检查密钥或额度';
        case 404:
          return '接口地址不存在（404），请检查 Base URL';
        case 429:
          return '请求过于频繁或额度不足（429），请稍后再试';
        default:
          return '服务端错误 HTTP ${e.statusCode}：${e.message}';
      }
  }
}
