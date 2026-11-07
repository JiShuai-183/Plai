import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/chat_message.dart';

/// 单条消息气泡。
///
/// - user：右侧，主色容器（带图片附件时上方横排缩略图）；
/// - assistant：左侧，中性容器（流式中末尾带光标 ▍）；
/// - tool：左侧弱化样式（内部过程，列表渲染时会跳过）。
class AiMessageBubble extends StatelessWidget {
  const AiMessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.attachments = const <String>[],
    this.streaming = false,
  });

  final ChatRole role;
  final String content;

  /// 随消息附带的图片本地路径（user 消息）。
  final List<String> attachments;
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

    // 缩略图按显示尺寸 × DPR 解码，避免整张原图解码后再缩小（内存/耗时优化）。
    final double pr = MediaQuery.of(context).devicePixelRatio;
    final int thumbCacheSide = (76 * pr).round();

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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: role == ChatRole.user
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            for (final String path in attachments)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(path),
                                  width: 76,
                                  height: 76,
                                  cacheWidth: thumbCacheSide,
                                  cacheHeight: thumbCacheSide,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, Object? e, _) => Container(
                                    width: 76,
                                    height: 76,
                                    color:
                                        scheme.surfaceContainerHighest,
                                    child: const Icon(
                                        Icons.broken_image_outlined,
                                        size: 20),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (content.isNotEmpty)
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: textColor, height: 1.4),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 等待行的阶段：决定图标，也决定文案里能出现什么。
///
/// 图标只提示「现在大概在做什么」，文案本身由页面按用户视角写好，
/// 不出现任何函数名 / 工具名。
enum AiTracePhase {
  /// 等模型开口（请求已发出，尚未收到内容）。
  thinking,

  /// 正在查询本地数据（读工具执行中）。
  querying,

  /// 待用户确认修改。
  editing,

  /// 正在写入本地数据（用户已确认）。
  writing,

  /// 结果已出，正在整理文字。
  summarizing,
}

/// AI 处理中的等待指示行（function-calling 进行中，转圈 + 阶段文案）。
///
/// 只表达「现在到哪一步了」，不展示调用了什么（结果由回答文本直接给出；
/// AI 实际修改数据时也在回答中说明）。
class AiToolTraceRow extends StatelessWidget {
  const AiToolTraceRow({
    super.key,
    required this.text,
    this.pending = false,
    this.phase = AiTracePhase.querying,
  });

  final String text;

  /// true = 进行中（附小转圈）。
  final bool pending;

  /// 当前阶段（决定图标）。
  final AiTracePhase phase;

  IconData get _icon {
    switch (phase) {
      case AiTracePhase.thinking:
        return Icons.autorenew;
      case AiTracePhase.querying:
        return Icons.manage_search;
      case AiTracePhase.editing:
        return Icons.edit_outlined;
      case AiTracePhase.writing:
        return Icons.check_circle_outline;
      case AiTracePhase.summarizing:
        return Icons.notes;
    }
  }

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
                _icon,
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
