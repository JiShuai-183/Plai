import 'package:flutter/material.dart';

import '../../data/models/chat_message.dart';

/// 单条消息气泡。
///
/// - user：右侧，主色容器；
/// - assistant：左侧，中性容器（流式中末尾带光标 ▍）；
/// - tool：左侧弱化样式（S6 起真实出现，这里先占分支）。
class AiMessageBubble extends StatelessWidget {
  const AiMessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.streaming = false,
  });

  final ChatRole role;
  final String content;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final Alignment alignment;
    final Color bubbleColor;
    final Color textColor;
    final String avatarLetter;
    switch (role) {
      case ChatRole.user:
        alignment = Alignment.centerRight;
        bubbleColor = scheme.primaryContainer;
        textColor = scheme.onPrimaryContainer;
        avatarLetter = '';
      case ChatRole.assistant:
        alignment = Alignment.centerLeft;
        bubbleColor = scheme.surfaceContainerHighest;
        textColor = scheme.onSurface;
        avatarLetter = 'A';
      case ChatRole.tool:
        alignment = Alignment.centerLeft;
        bubbleColor = scheme.surfaceContainerLow;
        textColor = scheme.onSurfaceVariant;
        avatarLetter = 'T';
    }

    final String body =
        streaming && content.isEmpty ? '…' : content + (streaming ? ' ▍' : '');

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (role != ChatRole.user) ...[
              CircleAvatar(
                radius: 14,
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: Text(
                  avatarLetter,
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  body,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: textColor, height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 查询本地数据时的等待指示行（function-calling 进行中，仅转圈占位）。
///
/// 只表达「正在查询」这一状态，不展示查了什么（结果由回答文本直接给出；
/// AI 实际修改数据时也在回答中说明）。
class AiToolTraceRow extends StatelessWidget {
  const AiToolTraceRow({super.key, required this.text, this.pending = false});

  final String text;

  /// true = 查询进行中（附小转圈）。
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Icon(
                Icons.manage_search,
                size: 16,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 8),
            if (pending) ...[
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
