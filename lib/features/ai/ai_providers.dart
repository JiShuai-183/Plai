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
final messagesProvider = FutureProvider.family<List<ChatMessage>, int>((
  ref,
  sessionId,
) {
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
  return LlmConfig(
    enabled: enabled,
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
  );
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
  (ref) =>
      ({required String baseUrl, String apiKey = '', required String model}) =>
          LlmClient(baseUrl: baseUrl, apiKey: apiKey, model: model),
);

/// 系统提示词（首条，固定）。
const String chatSystemPrompt =
    '你是 Plai 助手：一位了解用户课表与日程的学习生活助理。'
    '请用简体中文、简洁友好地回答问题。'
    '你可以调用只读工具 query 查询用户的学期、课程、任务、节次等本地数据'
    '（用 action 指定维度：day=某天安排、courses=课程表、tasks=日程任务、'
    'periods=节次、semester=学期、date=今天日期与周次）；'
    '涉及这类事实（尤其是具体某天的课表/任务）时，先调用工具查询再回答，'
    '不要凭空猜测；需要日期推算时先查 query（action=date）。'
    '你也可以调用两个写工具替用户修改数据（都必须带 action，缺了会被拒绝）：'
    'save_task 动日程——action=create 新建、update 修改已有日程'
    '（task_id 先从 query 查）、complete 改完成状态、delete 删除'
    '（task_id 先从 query 查、不可恢复）；'
    'save_course 动课表——action=create 新建课程、update 修改课程'
    '（course_id 先从 query 查）、delete 删除课程（course_id 先从 query 查）。'
    '用户的提醒要求用 save_task 的 create / update 两个参数表达，'
    '**二者互斥、只能传一个**，也不要写进标题或描述：'
    'remind_time（HH:mm，24 小时制）= **每天**重复——用户只说某个钟点、'
    '或说“每天提醒我”“提醒我”时用它（“X点提醒我”→ remind_time）；'
    'remind_at（"yyyy-MM-dd HH:mm"）= **只提醒一次**——用户说'
    '“X月X日X点提醒我一次”“只在X号提醒我”“那天叫我一下”时用它，'
    '日期必须换算成具体年月日且晚于现在；'
    '“提前X分钟提醒”且已知起始/截止时刻时，换算成时刻再传'
    '（如 8:00 提前 10 分钟 → "07:50"）；'
    '要取消提醒就传空串（remind_time: ""）；'
    '没有提醒要求就不要传这两个参数（会保持原值，不会误删已设提醒）。\n'
    '关键认知：对用户而言你没有"函数/工具"这层概念——工具由 App 在后台'
    '替你执行，用户看不到也不需要知道。回复永远只陈述用户关心的结果，'
    '绝不提任何调用机制。\n'
    '重要规则：\n'
    '1. 确认由 App 自动弹出确认面板完成：你只要发起工具调用即可，'
    '**绝对不要**在回复文字里向用户请求确认、询问"是否执行此操作"；\n'
    '2. 工具执行结果会回传给你：成功就直接简短汇报（如"已创建"），'
    '失败就按错误提示修正参数后重新调用同一条工具，不要转成文字去问用户；\n'
    '3. 只做用户明确要求的操作，不要画蛇添足：创建日程/任务后'
    '**不要**顺手把它标记为完成，也不要追加用户没提的其他修改；\n'
    '3a. 删除不可恢复（没有回收站）：**只有用户明确要求删除**时才用 '
    'save_task / save_course 的 action=delete，且必须先查出 id、不要凭记忆编造。'
    '用户指代不清时（如"这条不想做了""有门课不上了"）先问清楚删哪一条，'
    '不要替用户猜；只想改内容或改状态就用 save_task 的 action=update / '
    'action=complete，或 save_course 的 action=update。'
    '也不要顺手清理用户没让删的过期任务；\n'
    '3b. 用户一次性给出多件安排（计划、清单、课表文本等）要建成日程时，'
    '在一条回复里**并行发起全部** action=create 的 save_task 调用'
    '（一条消息多个工具调用），不要拆成多轮逐条调用——App 会一次性列出草稿供用户核对；\n'
    '4. 被用户拒绝或跳过的操作不要重试，尊重用户决定；\n'
    '5. 回复是给用户看的结果，不是你的工作日志。只讲"做了什么、结果如何"，'
    '绝不允许出现：任何函数/工具名（save_task、save_course、query 等）、'
    '"我将调用""我会调用""我来调用""需要调用""通过 xx 函数""使用工具"这类'
    '宣布句，以及"先查一下""我正在""分几步"等过程描述。'
    '调用前不要输出任何文字，直接发起调用；等全部完成后，用一句用户视角'
    '的话报告结果：\n'
    '  ✗ "好的，我将调用 save_task 函数创建任务。"\n'
    '  ✗ "已通过 save_task 把截止时间改到明天。"\n'
    '  ✗ "我先用 query 查了课表……"\n'
    '  ✓ "已创建任务「交高数作业」。"/"已把「交高数作业」截止时间改到明天。"\n'
    '  ✓ 查询类：直接给出答案与关键事实，不交代查询过程。\n'
    '需要转述工具报错时也只用自然语言概括（如"信息不完整，已跳过"）。\n'
    '6. 用户可能附带图片：图片内容用视觉直接读取。'
    '若用户要求核对课表：先读出图中全部课程，再调用 query（action=courses）查询'
    '本地课表，逐条比对后明确列出差异（图中多出 / 本地多出 / 信息不一致），'
    '并按用户意图用 save_course 的 action=update / create 发起修改（会经用户确认）；'
    '若用户要求把图中课程加入课表，并行发起多条 action=create 的 save_course。\n'
    '若用户消息附带课表/日程上下文，回答时优先结合它；'
    '若未附带也未查到，不得编造用户的课表或日程信息。\n'
    '7. 时间范围必须按用户原话兑现，不要擅自放大或缩小：\n'
    '  · 用户指**某一个具体日期**（"今天晚上""明天上午""这周六"）说要上课/加一节课，'
    '就只加那一天：save_course 的 start_week 和 end_week '
    '都填那一天的学期周次（先查 query（action=date）确认当前是第几周），'
    'weekday 填那一天是星期几；**不要**省略周次（省略=整学期）。\n'
    '  · 用户说"以后每周都要"或没说时间范围，才按整学期建课。\n'
    '  · 用户说"只改/只调本周""就这一次"，表示原课程其余周次必须保留：'
    '先用 action=update 把原课程的这段周次让出来（如原为第9-18周、本周第9周被调走，'
    '就改成第10-18周），再用 action=create 新建仅覆盖本周那条；'
    '**不要**直接把整门课改成新时间/新周次，那样会把学期里其余周次一起改掉。\n'
    '  · 拿不准是哪一周时先查 query（action=date）或直接问用户，不要默认整学期。\n'
    '8. 改课周次、调课、删课这类会影响多周的操作，执行前先用一句话说明影响范围'
    '（"这会把第9-18周都改掉"），让用户在确认面板上能看懂代价；'
    '用户只要求调一周时，必须按第 7 条保留其余周次。\n'
    '9. 调课（把某节课挪到别的时间）时，若原课程覆盖多个周次，'
    '**默认新建一门只覆盖被调那几周的课，不移动原课**：'
    '原课程的其余周次必须原样保留，不能被改掉。'
    '只有当用户明确说"以后都改到周六""整学期都调"时，才用 action=update 移动原课程。\n'
    '  · 例：高等数学周一 9-10 节、第9-18周，用户说"把今晚的课调到周六"，'
    '就 create 一门周六 9-10 节、第9周的课，'
    '再把原课程 update 成第10-18周（让出第9周）；'
    '**不要**把原课的 weekday 直接改成周六，那样第10-18周也跟着搬走了。';

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
          openToolGroup!.add(
            AiMessage.tool(toolCallId: _toolCallIdOf(m), content: m.content),
          );
          pendingResults--;
        }
      // 孤儿 tool（找不到所属工具轮）：丢弃。
    }
  }
  closeToolGroup();
  return groups;
}

/// 系统提示词 + 本次发送时刻的真实日期锚点。
///
/// 跨天/隔天继续旧会话时，历史消息里可能残留更早日期的文本（如昨天的
/// query(action=date) 结果），模型容易据此把「今天」当成昨天。故每次发送都在
/// system 里带上**当前真实日期**并要求以其为准，覆盖陈旧日期。
String _systemPromptWithNow() {
  final DateTime now = DateTime.now();
  const List<String> weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
  final String date =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  return '$chatSystemPrompt\n'
      '当前真实日期（涉及「今天/明天/周几/第几周」一律以本条为准；'
      '历史消息里出现的更早日期视为已过时）：今天是 $date（周'
      '${weekdays[now.weekday - 1]}）。需要学期周次等细节再调用 query（action=date）核实。';
}

/// 组装发给 LLM 的 messages：
/// `system 提示` →（可选）`当前状态快照` → `最近 [maxWireTurns] 轮历史`
/// （超长时补一条截断说明，且工具轮与其结果消息永不拆散）→ `本次 user 消息`。
///
/// [imageDataUris] 非空时，本次 user 消息为多模态（文本 + 图片 data URI）；
/// 仅本次发送的图片进入 wire（历史消息的图片不回放，控制上下文体积）。
///
/// [appState] 是发送前预取的本地状态摘要（见 `buildAppStateSnapshot`），
/// 为空串则不注入。
List<AiMessage> composeWireMessages({
  required String userText,
  required List<ChatMessage> history,
  int maxTurns = maxWireTurns,
  List<String> imageDataUris = const <String>[],
  String appState = '',
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
    AiMessage.system(_systemPromptWithNow()),
  ];
  if (appState.trim().isNotEmpty) {
    wire.add(AiMessage.system(_appStateBlock(appState.trim())));
  }
  if (dropped > 0) {
    wire.add(AiMessage.system('以上只保留最近 $maxTurns 轮对话（更早的 $dropped 条消息已省略）。'));
  }
  for (final List<AiMessage> g in kept) {
    wire.addAll(g);
  }
  wire.add(
    imageDataUris.isEmpty
        ? AiMessage.user(userText)
        : AiMessage.userImages(
            text: userText,
            images: <AiImagePart>[
              for (final String uri in imageDataUris) AiImagePart.uri(uri),
            ],
          ),
  );
  return wire;
}

/// 把预取的状态快照包成一条 system 消息。
///
/// 明确写成「发送时的快照」并允许模型在需要更细的信息时仍去查工具——
/// 快照是加速用的顺手事实，不是权威来源；数据刚被写工具改过时，
/// 快照必然落后于真实状态，不能让模型拿它当答案。
String _appStateBlock(String state) {
  return '以下是 App 在你收到本条消息的同一时刻为用户预取的本地状态快照'
      '（只读，用户看不到这段话）：\n'
      '$state\n'
      '用时遵守：\n'
      '1. 用户问的正好是这些事实（今天有什么课、有哪些没做的事、某条任务/'
      '课程的信息、提醒是怎么设的）时，**直接依据快照回答，不要再调用工具**；\n'
      '1.1 但快照里的「未完成的日程」是**全部**未完成项，没有按任何时间范围'
      '（本周/本月/某几天）过滤。用户的问题带时间范围时（"这个月""本周"'
      '"国庆那几天"），不能拿这个列表直接当答案，必须调用 query 查询；'
      '也**绝对不要**只回「这个」「好的」这类不构成回答的话——'
      '要么给出具体内容，要么说明还缺什么信息；\n'
      '2. 快照没有覆盖的信息，照旧调用相应工具查询；\n'
      '3. 快照是发送那一刻的状态：本次对话里已经执行过写操作之后，'
      '涉及被改动对象的问题一律重新查询，不要引用旧快照；\n'
      '4. 不要向用户提起「快照」「预取」这类字样。';
}

/// 400 常见诱因关键词 → 人话提示（覆盖 Moonshot 等严格服务商/思考型模型）。
/// 未命中返回 null，由调用方回退通用文案。
String? ai400FriendlyHint(String raw) {
  final String m = raw.toLowerCase();
  if (m.contains('temperature')) {
    return '当前模型不支持自定义采样温度（思考/推理型模型常见），'
        '已改为不发送该参数；仍失败建议更换模型';
  }
  if (m.contains('tool') || m.contains('function') || raw.contains('工具')) {
    return '当前服务商/模型不支持工具调用（tools / function calling 参数），'
        'AI 对话依赖工具查询本地数据；请更换支持 tools 的模型或中转服务';
  }
  if (m.contains('schema')) {
    return '服务端对工具参数 schema 校验较严，需完整 JSON Schema'
        '（顶层 type:"object"）；工具定义已统一，仍失败建议更换模型';
  }
  if (m.contains('response_format') || m.contains('json_object')) {
    return '当前模型不支持 JSON 输出约束（response_format），建议更换模型';
  }
  if (m.contains('context length') ||
      m.contains('context_length') ||
      m.contains('maximum context') ||
      m.contains('too long') ||
      m.contains('token limit') ||
      m.contains('max_tokens') ||
      raw.contains('上下文') ||
      raw.contains('长度超限') ||
      raw.contains('超过最大')) {
    return '消息过长，超过当前模型上下文窗口：请精简内容或更换更长上下文的模型';
  }
  if (m.contains('quota') ||
      m.contains('insufficient') ||
      raw.contains('余额') ||
      raw.contains('额度')) {
    return '账户额度不足或密钥没有可用配额：请到服务商后台确认余额/额度'
        '（连接测试只花几个 token，能通过不代表对话还有额度）';
  }
  if (m.contains('image') ||
      m.contains('vision') ||
      m.contains('multimodal') ||
      m.contains('image_url')) {
    return '当前模型不支持图片/多模态输入，请更换支持视觉的模型';
  }
  return null;
}

/// 服务端原文摘要：压成单行并截断，把「泛化提示」变成可定位的线索。
///
/// 远程用户只能转述我们给的文案：400 只说「拒绝了该请求」时，
/// 排查只能靠猜；带上原文后，一眼就能看出是 tools 不支持、上下文超限还是额度问题。
String aiServerExcerpt(String raw, {int max = 200}) {
  final String one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (one.isEmpty) return '';
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

String _aiWithDetail(String head, String raw) {
  final String detail = aiServerExcerpt(raw);
  return detail.isEmpty ? head : '$head（原文：$detail）';
}

/// 把 [AiError] 转成对人类友好的单行中文提示（配置/网络/鉴权/限流/其它分流）。
String friendlyAiErrorMessage(AiError e) {
  switch (e.kind) {
    case AiErrorKind.config:
      return e.message;
    case AiErrorKind.network:
      return _aiWithDetail('网络连接失败，请检查网络或 Base URL', e.message);
    case AiErrorKind.timeout:
      return _aiWithDetail('连接超时，请检查网络或 Base URL', e.message);
    case AiErrorKind.format:
      return '服务响应格式异常：${e.message}';
    case AiErrorKind.http:
      switch (e.statusCode) {
        case 400:
          return _aiWithDetail(
            ai400FriendlyHint(e.message) ??
                '服务端拒绝了该请求（400），请检查 Base URL / 模型配置或更换模型',
            e.message,
          );
        case 401:
          return 'API 密钥无效或未授权（401），请到「AI 服务」检查';
        case 403:
          return '无访问权限（403），请检查密钥或额度';
        case 404:
          return '接口地址不存在（404），请检查 Base URL';
        case 429:
          return '请求过于频繁或额度不足（429），请稍后再试';
        case 503:
          return '服务繁忙或暂时不可用（503），请稍后再试';
        default:
          return '服务端错误 HTTP ${e.statusCode}：${aiServerExcerpt(e.message)}';
      }
  }
}
