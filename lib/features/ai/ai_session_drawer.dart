import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/chat_session.dart';
import '../../shared/plai_toast.dart';
import 'ai_providers.dart';

/// 历史会话面板（AI 页左侧推挤面板，容器由页面提供）。
///
/// - 排序沿用 [sessionsProvider]（置顶 → 最近活跃）；
/// - 点击切换会话；长按或点「…」弹菜单：置顶/取消置顶、删除（二次确认）；
/// - 顶部「新建对话」进入空会话；选中/新建后经 [onClose] 请求收起面板。
class AiSessionDrawer extends ConsumerWidget {
  const AiSessionDrawer({
    super.key,
    required this.selectedId,
    this.enabled = true,
    required this.onClose,
    required this.onSelect,
    required this.onDeleted,
  });

  /// 当前选中会话 id（可为 null = 空会话/新对话）。
  final int? selectedId;

  /// false 时禁止切换（发送流式进行中）。
  final bool enabled;

  /// 请求收起面板（选中/新建会话后由页面收起）。
  final VoidCallback onClose;

  /// 选择某会话（id 为 null 表示新建对话）。
  final ValueChanged<int?> onSelect;

  /// 会话被删除（页面据此清掉已选中项）。
  final ValueChanged<int> onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<ChatSession>> sessions = ref.watch(sessionsProvider);
    final List<ChatSession> list = sessions.valueOrNull ?? const [];

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text(
                  '历史对话',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: enabled
                    ? () {
                        onClose();
                        onSelect(null);
                      }
                    : null,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('新建对话'),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: sessions.isLoading && list.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : sessions.hasError && list.isEmpty
                    ? Center(
                        child: Text(
                          '历史对话加载失败',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      )
                    : list.isEmpty
                        ? Center(
                            child: Text(
                              '还没有历史对话',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          )
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (BuildContext context, int index) {
                              final ChatSession s = list[index];
                              return _SessionTile(
                                session: s,
                                selected: s.id != null && s.id == selectedId,
                                enabled: enabled,
                                onTap: () {
                                  final int? id = s.id;
                                  if (id == null) return;
                                  if (!enabled) {
                                    _showSnack(context, '正在生成，请稍候');
                                    return;
                                  }
                                  onClose();
                                  onSelect(id);
                                },
                                onMenu: () => _showActions(context, ref, s),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  void _showActions(
    BuildContext context,
    WidgetRef ref,
    ChatSession session,
  ) {
    final int? id = session.id;
    if (id == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.chat_outlined),
                title: Text(_displayTitle(session)),
                subtitle: Text(_relativeTime(session.lastActiveAt)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  session.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(session.pinned ? '取消置顶' : '置顶'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  ref.read(chatRepositoryProvider).setPinned(id, !session.pinned);
                  ref.invalidate(sessionsProvider);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: Text('删除', style: TextStyle(color: Colors.red[700])),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _confirmDelete(context, ref, session);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ChatSession session,
  ) async {
    final int? id = session.id;
    if (id == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('删除会话'),
          content: Text('确定删除「${_displayTitle(session)}」吗？其下对话记录将一并删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    await ref.read(chatRepositoryProvider).deleteSession(id);
    ref.invalidate(sessionsProvider);
    ref.invalidate(messagesProvider(id));
    onDeleted(id);
  }

  void _showSnack(BuildContext context, String message,
      {PlaiToastKind kind = PlaiToastKind.normal}) {
    showPlaiToast(context, message, kind: kind);
  }
}

/// 单条会话行。
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onMenu,
  });

  final ChatSession session;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      selected: selected,
      leading: session.pinned
          ? const Icon(Icons.push_pin, size: 18)
          : const Icon(Icons.chat_bubble_outline, size: 20),
      title: Text(
        _displayTitle(session),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _relativeTime(session.lastActiveAt),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        tooltip: '会话操作',
        onPressed: enabled ? onMenu : null,
      ),
      onTap: onTap,
      onLongPress: enabled ? onMenu : null,
    );
  }
}

String _displayTitle(ChatSession session) =>
    session.title.trim().isEmpty ? '新对话' : session.title;

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / M月d日。
String _relativeTime(DateTime t) {
  final Duration diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && diff.inDays < 1) return '${diff.inHours} 小时前';
  final DateTime now = DateTime.now();
  final DateTime day = DateTime(t.year, t.month, t.day);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int days = today.difference(day).inDays;
  if (days == 1) return '昨天';
  return '${t.month}月${t.day}日';
}
