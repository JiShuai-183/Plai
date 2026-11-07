import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/chat_message.dart';
import '../../data/models/chat_queue_entry.dart';
import '../../data/repositories/chat_queue_repository.dart';
import 'ai_conversation_controller.dart';
import 'ai_queue_attachments.dart';

typedef AiQueuedRunner = Future<bool> Function(
  ChatQueueEntry entry,
  void Function(AiConversationState) onState,
  AiConfirmWrites confirm,
  Future<void> Function(Map<String, dynamic>) checkpoint,
);

class AiPendingConfirmation {
  AiPendingConfirmation(this.entryId, this.sessionId, this.proposals);
  final int entryId;
  final int sessionId;
  final List<AiWriteProposal> proposals;
  final result = Completer<List<Map<String, dynamic>?>>();
}

/// ProviderScope 生命周期内的唯一串行调度器；页面切换不影响运行。
class AiQueueController extends ChangeNotifier {
  AiQueueController({
    required this.repository,
    required this.run,
    required this.attachments,
    required this.onMessagesChanged,
    required this.errorMessage,
  });

  final IChatQueueRepository repository;
  final AiQueuedRunner run;
  final AiQueueAttachments attachments;
  final void Function(int sessionId) onMessagesChanged;
  final String Function(Object error) errorMessage;
  final activity = ValueNotifier<AiConversationState>(
    const AiConversationState(),
  );
  List<ChatQueueEntry> entries = const [];
  AiPendingConfirmation? confirmation;
  int? activeId;
  bool paused = false;
  bool restored = false;
  bool loading = true;
  String? storageError;
  bool _draining = false;
  bool _disposed = false;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      // 读取失败也可能发生在另一条消息仍执行时。仅无调度器运行时恢复
      // 遗留状态，不能把当前进程的执行项改成可跳过的中断项。
      if (!_draining) await repository.recoverInterrupted();
      await _reload();
      restored = entries.any((e) => !isTerminal(e));
      paused = restored;
      storageError = null;
    } catch (_) {
      storageError = '待发送消息加载失败，请重试';
      paused = true;
    }
    loading = false;
    _notify();
  }

  Future<void> reloadStorage() async {
    _initialization = null;
    loading = true;
    _notify();
    await initialize();
  }

  static bool isTerminal(ChatQueueEntry e) =>
      e.status == ChatQueueStatus.completed ||
      e.status == ChatQueueStatus.cancelled;
  ChatQueueEntry? get active => _entry(activeId);
  ChatQueueEntry? get blocked {
    for (final e in entries) {
      if (e.status == ChatQueueStatus.failed ||
          e.status == ChatQueueStatus.interrupted) {
        return e;
      }
    }
    return null;
  }

  int get queuedCount =>
      entries.where((e) => e.status == ChatQueueStatus.queued).length;
  bool sessionLocked(int id) =>
      active?.sessionId == id ||
      entries.any(
        (e) =>
            e.sessionId == id &&
            (e.status == ChatQueueStatus.running ||
                e.status == ChatQueueStatus.waitingConfirmation),
      );

  ChatQueueEntry? _entry(int? id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _reload() async {
    final next = await repository.list();
    if (!_disposed) entries = List.unmodifiable(next);
  }

  Future<ChatQueueEntry> enqueue({
    required int sessionId,
    required String text,
    List<String> imagePaths = const [],
  }) async {
    final frozen = List<String>.of(imagePaths);
    await initialize();
    if (storageError != null) throw StateError(storageError!);
    final retained = await attachments.retain(frozen);
    final ChatQueueEntry entry;
    try {
      entry = await repository.enqueue(
        sessionId: sessionId,
        text: text,
        imagePaths: retained,
        includeAppState: true,
      );
    } catch (_) {
      await attachments.remove(retained);
      rethrow;
    }
    // 入队事务已提交。后续刷新失败也不能让页面把它当成未发送而重复入队。
    entries = List.unmodifiable(
      [...entries, entry]..sort((a, b) => a.id.compareTo(b.id)),
    );
    try {
      await _reload();
    } catch (_) {
      storageError = '消息已保存，队列读取失败，请重新加载';
      paused = true;
    }
    onMessagesChanged(sessionId);
    _notify();
    unawaited(_drain());
    return entry;
  }

  Future<void> _drain() async {
    if (_disposed || _draining || paused || loading || storageError != null) {
      return;
    }
    _draining = true;
    try {
      while (!_disposed && !paused) {
        await _reload();
        if (_disposed || paused) break;
        if (blocked != null) {
          paused = true;
          break;
        }
        ChatQueueEntry? next;
        for (final e in entries) {
          if (e.status == ChatQueueStatus.queued) {
            next = e;
            break;
          }
        }
        if (next == null) break;
        final entry = next;
        activeId = entry.id;
        final changed = await repository.update(
          entry.id,
          status: ChatQueueStatus.running,
          clearError: true,
        );
        if (changed != 1) {
          activeId = null;
          continue;
        }
        await _reload();
        _notify();
        var checkpoint = Map<String, dynamic>.from(entry.checkpoint);
        try {
          final success = await run(
            entry,
            (state) {
              if (!_disposed) activity.value = state;
            },
            (proposals) async {
              if (_disposed) return [for (final _ in proposals) null];
              await repository.update(
                entry.id,
                status: ChatQueueStatus.waitingConfirmation,
              );
              final request = AiPendingConfirmation(
                entry.id,
                entry.sessionId,
                proposals,
              );
              confirmation = request;
              await _reload();
              _notify();
              final decisions = await request.result.future;
              if (_disposed) return [for (final _ in proposals) null];
              confirmation = null;
              await repository.update(
                entry.id,
                status: ChatQueueStatus.running,
              );
              await _reload();
              _notify();
              return decisions;
            },
            (value) async {
              checkpoint = Map<String, dynamic>.from(value);
              final saved = await repository.update(
                entry.id,
                checkpoint: value,
              );
              if (saved != 1) throw StateError('执行记录未保存，停止处理');
            },
          );
          if (_disposed) return;
          await repository.update(
            entry.id,
            status: success
                ? ChatQueueStatus.completed
                : ChatQueueStatus.failed,
            error: success ? null : '本条消息有未完成的操作，请核对结果后重试或跳过',
            clearError: success,
            checkpoint: checkpoint,
          );
          if (!success) paused = true;
        } catch (error) {
          if (_disposed) return;
          // checkpoint 中 running 表示业务可能已写入，不能默默整轮重放。
          final ops = checkpoint['operations'] as List? ?? const [];
          final uncertain = ops.any(
            (op) => op is Map && op['status'] == 'running',
          );
          await repository.update(
            entry.id,
            status: uncertain
                ? ChatQueueStatus.interrupted
                : ChatQueueStatus.failed,
            error: errorMessage(error),
            checkpoint: checkpoint,
          );
          paused = true;
        } finally {
          activeId = null;
          confirmation = null;
          if (!_disposed) {
            activity.value = const AiConversationState();
            onMessagesChanged(entry.sessionId);
          }
        }
        await _reload();
        _notify();
      }
    } catch (_) {
      paused = true;
      storageError = '队列保存失败，请重新加载并核对处理结果';
    } finally {
      activeId = null;
      confirmation = null;
      if (!_disposed) activity.value = const AiConversationState();
      _draining = false;
      _notify();
    }
  }

  void confirm(List<Map<String, dynamic>?> decisions) {
    final request = confirmation;
    if (request == null || request.result.isCompleted) return;
    if (decisions.length != request.proposals.length) return;
    request.result.complete(decisions);
  }

  Future<void> resume() async {
    await initialize();
    if (storageError != null || blocked != null) return;
    restored = false;
    paused = false;
    _notify();
    unawaited(_drain());
  }

  Future<void> retry(int id) async {
    if (_draining || activeId != null) return;
    final e = _entry(id);
    if (e == null ||
        (e.status != ChatQueueStatus.failed &&
            e.status != ChatQueueStatus.interrupted)) {
      return;
    }
    await repository.update(
      id,
      status: ChatQueueStatus.queued,
      clearError: true,
    );
    await _reload();
    restored = false;
    paused = false;
    _notify();
    unawaited(_drain());
  }

  Future<void> skip(int id) async {
    if (activeId == id) return;
    final e = _entry(id);
    if (e == null ||
        (e.status != ChatQueueStatus.failed &&
            e.status != ChatQueueStatus.interrupted)) {
      return;
    }
    await repository.update(id, status: ChatQueueStatus.cancelled);
    await _reload();
    onMessagesChanged(e.sessionId);
    await resume();
  }

  Future<ChatQueueEntry?> withdraw(int id) async {
    if (activeId == id) return null;
    final entry = await repository.withdraw(id);
    await _reload();
    if (entry != null) onMessagesChanged(entry.sessionId);
    _notify();
    return entry;
  }

  Future<void> cancelQueued(int id) async {
    final e = await withdraw(id);
    if (e != null) await attachments.remove(e.imagePaths);
  }

  Future<void> deleteSessions(List<int> ids) async {
    if (ids.any(sessionLocked)) throw StateError('正在处理或等待确认的会话暂不可删除');
    // 暂停取下一项，避免确认删除之后、事务开始之前队列选中待删会话。
    final wasPaused = paused;
    paused = true;
    try {
      final paths = await repository.deleteSessions(ids);
      await attachments.remove(paths);
      await _reload();
      for (final id in ids) {
        onMessagesChanged(id);
      }
    } finally {
      paused = wasPaused && (restored || blocked != null);
      _notify();
      if (!paused) unawaited(_drain());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final request = confirmation;
    if (request != null && !request.result.isCompleted) {
      request.result.complete([for (final _ in request.proposals) null]);
    }
    activity.dispose();
    super.dispose();
  }
}

/// 入队用户消息可能早于上一条回答落库；按所属请求恢复对话顺序。
List<ChatMessage> orderAiMessages(
  List<ChatMessage> messages,
  List<ChatQueueEntry> entries,
) {
  final source = {for (final e in entries) e.id: e.userMessageId};
  int group(ChatMessage m) {
    for (final rec in m.toolRecords) {
      if (rec['type'] == 'queue' && source.containsKey(rec['id'])) {
        return source[rec['id']]!;
      }
    }
    return m.id ?? 0;
  }

  return List.of(messages)..sort((a, b) {
    final byGroup = group(a).compareTo(group(b));
    return byGroup != 0 ? byGroup : (a.id ?? 0).compareTo(b.id ?? 0);
  });
}
