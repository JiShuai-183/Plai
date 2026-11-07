import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/chat_session.dart';
import '../../data/models/chat_queue_entry.dart';
import '../../shared/plai_toast.dart';
import 'ai_providers.dart';
import 'ai_queue_providers.dart';

/// AI Tab 的起始页。历史选择是明确状态，不自动进入排序第一项。
class AiSessionsView extends ConsumerStatefulWidget {
  const AiSessionsView({
    super.key,
    required this.onOpen,
    required this.onNew,
    required this.onDeleted,
    this.query = '',
  });
  final ValueChanged<int> onOpen;
  final VoidCallback onNew;
  final ValueChanged<List<int>> onDeleted;
  final String query;

  @override
  ConsumerState<AiSessionsView> createState() => _AiSessionsViewState();
}

class _AiSessionsViewState extends ConsumerState<AiSessionsView> {
  bool _managing = false;
  bool _deleting = false;
  final _selected = <int>{};

  @override
  void didUpdateWidget(covariant AiSessionsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _selected.clear();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final previews = ref.watch(sessionPreviewsProvider);
    final queue = ref.watch(aiQueueControllerProvider);
    final theme = Theme.of(context);

    final list = (sessions.valueOrNull ?? const <ChatSession>[])
        .where(
          (s) => s.title.toLowerCase().contains(widget.query.toLowerCase()),
        )
        .toList();
    final selectable = list
        .where((s) => s.id != null && !queue.sessionLocked(s.id!))
        .map((s) => s.id!)
        .toSet();
    _selected.removeWhere((id) => !selectable.contains(id));
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _managing ? '已选 ${_selected.length} 项' : '最近会话',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          if (_managing)
                            TextButton(
                              onPressed: _deleting
                                  ? null
                                  : () => setState(() {
                                      if (_selected.containsAll(selectable)) {
                                        _selected.clear();
                                      } else {
                                        _selected.addAll(selectable);
                                      }
                                    }),
                              child: Text(
                                selectable.isNotEmpty &&
                                        _selected.containsAll(selectable)
                                    ? '取消全选'
                                    : '全选',
                              ),
                            ),
                          TextButton(
                            onPressed: _deleting
                                ? null
                                : () => setState(() {
                                    _managing = !_managing;
                                    _selected.clear();
                                  }),
                            child: Text(_managing ? '完成' : '管理'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (sessions.isLoading && !sessions.hasValue)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (sessions.hasError && !sessions.hasValue)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: TextButton(
                          onPressed: () => ref.invalidate(sessionsProvider),
                          child: const Text('会话加载失败，点击重试'),
                        ),
                      ),
                    )
                  else if (list.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          widget.query.isEmpty ? '还没有历史对话，开始聊聊吧' : '没有匹配的会话',
                        ),
                      ),
                    )
                  else
                    SliverList.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (_, index) => _tile(
                        list[index],
                        previews.valueOrNull?[list[index].id] ?? '',
                      ),
                    ),
                  if (!_managing)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 104 + MediaQuery.paddingOf(context).bottom,
                      ),
                    ),
                ],
              ),
            ),
            if (_managing)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _selected.isEmpty || _deleting
                        ? null
                        : () => _delete(_selected.toList()),
                    icon: const Icon(Icons.delete_outline),
                    label: Text('删除所选（${_selected.length}）'),
                  ),
                ),
              ),
          ],
        ),
        if (!_managing)
          Positioned(
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              left: false,
              child: FloatingActionButton.extended(
                key: const Key('ai_new_conversation'),
                heroTag: null,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                onPressed: _deleting ? null : widget.onNew,
                icon: const Icon(Icons.add),
                label: const Text('新建对话'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tile(ChatSession session, String preview) {
    final queue = ref.read(aiQueueControllerProvider);
    final id = session.id!;
    final locked = queue.sessionLocked(id);
    final jobs = queue.entries.where((e) => e.sessionId == id).toList();
    String? status;
    if (jobs.any((e) => e.status == ChatQueueStatus.waitingConfirmation)) {
      status = '等待确认';
    } else if (jobs.any((e) => e.status == ChatQueueStatus.running)) {
      status = '处理中';
    } else if (jobs.any(
      (e) =>
          e.status == ChatQueueStatus.failed ||
          e.status == ChatQueueStatus.interrupted,
    )) {
      status = '等待处理';
    } else {
      final n = jobs.where((e) => e.status == ChatQueueStatus.queued).length;
      if (n > 0) status = '排队 $n 条';
    }
    return ListTile(
      key: ValueKey('ai_session_$id'),
      dense: true,
      leading: _managing
          ? Checkbox(
              value: _selected.contains(id),
              onChanged: locked ? null : (_) => _toggle(id),
            )
          : Icon(
              session.pinned
                  ? Icons.push_pin_outlined
                  : Icons.chat_bubble_outline,
            ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              session.title.trim().isEmpty ? '新对话' : session.title,
              key: ValueKey('ai_session_title_$id'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              _relativeTime(session.lastActiveAt),
              key: ValueKey('ai_session_time_$id'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      subtitle: preview.isEmpty && status == null
          ? null
          : Text(
              '${status == null ? '' : '$status${preview.isEmpty ? '' : ' · '}'}$preview',
              key: ValueKey('ai_session_preview_$id'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: _managing
          ? null
          : PopupMenuButton<String>(
              tooltip: '会话操作',
              onSelected: (action) => _action(action, session),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(
                  value: 'pin',
                  child: Text(session.pinned ? '取消置顶' : '置顶'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: !locked,
                  child: Text(locked ? '处理中，暂不可删除' : '删除'),
                ),
              ],
            ),
      onLongPress: _deleting
          ? null
          : () => setState(() {
              _managing = true;
              if (!locked) _selected.add(id);
            }),
      onTap: _deleting
          ? null
          : _managing
          ? (locked ? null : () => _toggle(id))
          : () => widget.onOpen(id),
    );
  }

  void _toggle(int id) => setState(() {
    if (!_selected.add(id)) _selected.remove(id);
  });

  Future<void> _action(String action, ChatSession s) async {
    try {
      if (action == 'delete') {
        await _delete([s.id!]);
        return;
      }
      final repo = ref.read(chatRepositoryProvider);
      if (action == 'pin') {
        await repo.setPinned(s.id!, !s.pinned);
      }
      if (action == 'rename') {
        if (!mounted) return;
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => _RenameSessionDialog(title: s.title),
        );
        if (name == null || name.isEmpty) return;
        await repo.renameSession(s.id!, name);
      }
      ref.invalidate(sessionsProvider);
    } catch (_) {
      if (mounted) {
        showPlaiToast(context, '会话操作失败，请重试', kind: PlaiToastKind.error);
      }
    }
  }

  Future<void> _delete(List<int> ids) async {
    final queue = ref.read(aiQueueControllerProvider);
    if (ids.any(queue.sessionLocked)) return;
    final pending = queue.entries
        .where(
          (e) =>
              ids.contains(e.sessionId) && e.status == ChatQueueStatus.queued,
        )
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${ids.length} 个会话？'),
        content: Text(
          '会话及聊天记录将被删除，无法恢复。${pending == 0 ? '' : '同时取消 $pending 条排队消息。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await queue.deleteSessions(ids);
      widget.onDeleted(ids);
      if (mounted) {
        setState(() {
          _selected.removeAll(ids);
          _managing = false;
        });
      }
    } catch (_) {
      if (mounted) {
        showPlaiToast(context, '删除未完成，请重试', kind: PlaiToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }
}

class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.title});
  final String title;
  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final controller = TextEditingController(text: widget.title);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名会话'),
    content: TextField(controller: controller, autofocus: true, maxLength: 80),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}

String _relativeTime(DateTime value) {
  final now = DateTime.now();
  final diff = now.difference(value);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (DateTime(
        now.year,
        now.month,
        now.day,
      ).difference(DateTime(value.year, value.month, value.day)).inDays ==
      1) {
    return '昨天';
  }
  return '${value.month}月${value.day}日';
}
