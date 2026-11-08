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
import 'ai_task_photos.dart';
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
      final requestContext = context.forRequest(
        requestId: 'queue:${entry.id}',
        imagePaths: entry.imagePaths,
        userText: entry.text,
      );
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
      // 恢复已有操作时只使用持久草稿；不再次识图，缺失图也可在卡片中移除。
      final hasOperations =
          (entry.checkpoint['operations'] as List? ?? const []).isNotEmpty;
      final images = hasOperations
          ? <String>[]
          : await ref
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
      final requestPrompt =
          '${systemPromptWithNow()}\n'
          '本次发送有 ${entry.imagePaths.length} 张照片，照片编号按出现顺序从1开始。'
          '只有本次照片能附入日程；更早聊天照片不能沿用，请用户重新发送。'
          '创建日程默认附本次照片，批量创建时为每项给出photo_indices；'
          '无法判断图片归属可不传，由用户在确认卡选择，不得虚构图片序号。'
          '修改已有任务只有用户明确要求补图、换图、删图时才设置photo_mode；'
          '普通标题、日期、提醒修改保留原图。旧任务照片本轮仅供用户本地预览，你不能识读。';
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
        systemPrompt: requestPrompt,
        checkpoint: entry.checkpoint,
        onCheckpoint: checkpoint,
        tools: [
          for (final tool in aiReadTools)
            AiConversationTool(
              name: tool.name,
              label: tool.label,
              schema: tool.toSchema(),
              execute: (args) => tool.execute(requestContext, args),
            ),
          for (final tool in aiWriteTools)
            AiConversationTool(
              name: tool.name,
              label: tool.label,
              schema: tool.toSchema(),
              execute: (args) => tool.execute(requestContext, args),
              validate: tool.validate,
              intentKey: tool.intentKey,
              describe: (args) => tool.describe(requestContext, args),
            ),
        ],
        prepareWrites: (proposals) async {
          final creates = proposals
              .where(
                (p) =>
                    p.tool.name == 'save_task' &&
                    (p.args['action'] as String?)?.trim().toLowerCase() ==
                        'create',
              )
              .length;
          final prepared = <AiWriteProposal>[];
          for (final proposal in proposals) {
            final args =
                proposal.tool.name == 'save_task' &&
                    const ['create', 'update'].contains(
                      (proposal.args['action'] as String?)
                          ?.trim()
                          .toLowerCase(),
                    )
                ? await prepareTaskPhotoArgs(
                    requestContext,
                    proposal.args,
                    createCount: creates,
                  )
                : proposal.args;
            prepared.add(
              AiWriteProposal(
                tool: proposal.tool,
                args: args,
                description: await proposal.tool.describe!(args),
              ),
            );
          }
          return prepared;
        },
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
            systemPrompt: requestPrompt,
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
