import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/models/chat_message.dart';
import '../../data/models/chat_session.dart';
import '../../data/repositories/chat_repository.dart';
import '../settings/settings_providers.dart';
import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/models/ai_message.dart';
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
    '请用简体中文、简洁友好地回答问题。若用户附带课表/任务上下文，'
    '回答时优先结合它；若未附带，不得编造用户的课表或日程信息。';

/// 单次发给模型的上下文窗口长度（历史消息条数上限）。
const int maxWireHistory = 20;

/// 组装发给 LLM 的 messages：
/// `system 提示` → `最近 [maxWireHistory] 条历史`（超长时补一条截断说明）
/// → `本次 user 消息`。历史中 tool 角色先跳过（S6 前不会真实出现）。
List<AiMessage> composeWireMessages({
  required String userText,
  required List<ChatMessage> history,
  int maxTurns = maxWireHistory,
}) {
  final List<ChatMessage> eligible = history
      .where((ChatMessage m) => m.role != ChatRole.tool)
      .toList(growable: false);

  final List<AiMessage> wire = <AiMessage>[
    AiMessage.system(chatSystemPrompt),
  ];
  if (eligible.length > maxTurns) {
    final int dropped = eligible.length - maxTurns;
    wire.add(AiMessage.system(
      '以上只保留最近 $maxTurns 条对话（共截断 $dropped 条较早消息）。',
    ));
    eligible.removeRange(0, dropped);
  }
  for (final ChatMessage m in eligible) {
    wire.add(switch (m.role) {
      ChatRole.user => AiMessage.user(m.content),
      ChatRole.assistant => AiMessage.assistantText(m.content),
      ChatRole.tool => AiMessage.user(m.content), // 理论不可达，兜底不丢内容
    });
  }
  wire.add(AiMessage.user(userText));
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
