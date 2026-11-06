import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/chat_queue_repository.dart';
import '../../services/ai/ai_error.dart';
import '../settings/settings_providers.dart';
import 'ai_conversation_controller.dart';
import 'ai_providers.dart';
import 'ai_queue_attachments.dart';
import 'ai_queue_controller.dart';
import 'ai_read_tools.dart';
import 'ai_settings_keys.dart';
import 'ai_tool_context.dart';
import 'ai_write_tools.dart';

final chatQueueRepositoryProvider = Provider<IChatQueueRepository>(
  (ref) => ChatQueueRepository(AppDatabase.instance),
);
final aiQueueAttachmentsProvider = Provider<AiQueueAttachments>(
  (ref) => AiQueueAttachments(),
);
final sessionPreviewsProvider = FutureProvider<Map<int, String>>(
  (ref) => ref.watch(chatQueueRepositoryProvider).sessionPreviews(),
);

final aiQueueControllerProvider = ChangeNotifierProvider<AiQueueController>((
  ref,
) {
  final context = AiToolContext.fromRef(ref);
  AiConversationController? running;
  ref.onDispose(() => running?.cancel());
  void changed(int id) {
    ref.invalidate(messagesProvider(id));
    ref.invalidate(sessionsProvider);
    ref.invalidate(sessionPreviewsProvider);
  }

  return AiQueueController(
    repository: ref.read(chatQueueRepositoryProvider),
    attachments: ref.read(aiQueueAttachmentsProvider),
    onMessagesChanged: changed,
    errorMessage: (error) =>
        error is AiError ? friendlyAiErrorMessage(error) : '这次处理未完成，请核对数据后重试',
    run: (entry, onState, confirm, checkpoint) async {
      final cfg = await ref.read(llmConfigProvider.future);
      if (!cfg.usable) {
        throw const AiError(AiErrorKind.config, '请先到「AI 服务」启用并配置模型');
      }
      final repo = ref.read(chatRepositoryProvider);
      final all = await ref.read(chatQueueRepositoryProvider).list();
      final excluded = {
        entry.userMessageId,
        for (final e in all)
          if (e.id != entry.id && e.status.name == 'queued') e.userMessageId,
      };
      final history = orderAiMessages(
        await repo.messagesFor(entry.sessionId),
        all,
      ).where((m) => !excluded.contains(m.id)).toList();
      final images = await ref
          .read(aiQueueAttachmentsProvider)
          .dataUris(entry.imagePaths);
      final appState = entry.includeAppState
          ? await buildAppStateSnapshot(context)
          : '';
      final writeEnabled =
          await ref
              .read(settingsRepositoryProvider)
              .getValue(AiSettingsKeys.writeEnabled) ==
          'true';
      final controller = AiConversationController(
        client: ref.read(llmClientFactoryProvider)(
          baseUrl: cfg.baseUrl,
          apiKey: cfg.apiKey,
          model: cfg.model,
        ),
        repository: repo,
        sessionId: entry.sessionId,
        queueId: entry.id,
        maxRounds: maxToolRounds,
        systemPrompt: systemPromptWithNow(),
        checkpoint: entry.checkpoint,
        onCheckpoint: checkpoint,
        tools: [
          for (final tool in aiReadTools)
            AiConversationTool(
              name: tool.name,
              label: tool.label,
              schema: tool.toSchema(),
              execute: (args) => tool.execute(context, args),
            ),
          for (final tool in aiWriteTools)
            AiConversationTool(
              name: tool.name,
              label: tool.label,
              schema: tool.toSchema(),
              execute: (args) => tool.execute(context, args),
              validate: tool.validate,
              intentKey: tool.intentKey,
              describe: (args) => tool.describe(context, args),
            ),
        ],
        confirmWrites: confirm,
        onState: onState,
        onMessagesChanged: () => changed(entry.sessionId),
      );
      running = controller;
      try {
        await controller.run(
          messages: composeWireMessages(
            userText: entry.text,
            history: history,
            imageDataUris: images,
            appState: appState,
          ),
          userText: entry.text,
          writeEnabled: writeEnabled,
        );
        return !controller.hadFailures;
      } finally {
        running = null;
      }
    },
  );
});
