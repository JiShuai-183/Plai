import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/models/chat_message.dart';
import '../../data/models/chat_session.dart';
import '../../data/models/chat_queue_entry.dart';
import '../../routes/app_routes.dart';
import '../../shared/layout_breakpoints.dart';
import '../../shared/plai_toast.dart';
import '../settings/settings_providers.dart';
import 'ai_attach_panel.dart';
import 'ai_conversation_controller.dart';
import 'ai_message_bubble.dart';
import 'ai_providers.dart';
import 'ai_queue_controller.dart';
import 'ai_queue_providers.dart';
import 'ai_sessions_view.dart';
import 'ai_settings_keys.dart';
import 'ai_write_confirm_sheet.dart';
import 'ai_write_tools.dart';

class AiPage extends ConsumerStatefulWidget {
  const AiPage({super.key});
  @override
  ConsumerState<AiPage> createState() => _AiPageState();
}

class _AiDraft {
  _AiDraft(this.text, List<String> images) : images = List.of(images);
  final String text;
  final List<String> images;
}

class _AiPageState extends ConsumerState<AiPage> {
  final _inputCtl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollCtl = ScrollController();
  final _drafts = <int?, _AiDraft>{};
  final _editing = <int?, _AiDraft>{};
  final _pendingImages = <String>[];
  static const _maxPendingImages = 4;
  int? _sessionId;
  bool _home = true;
  bool _preparing = false;
  bool _confirmationOpen = false;
  bool _withdrawing = false;
  int? _deferredConfirmation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(aiQueueControllerProvider).initialize());
    });
  }

  @override
  void dispose() {
    _inputFocus.dispose();
    _inputCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();
  void _saveDraft() =>
      _drafts[_sessionId] = _AiDraft(_inputCtl.text, _pendingImages);
  void _loadDraft() {
    final draft = _drafts[_sessionId];
    final text = draft?.text ?? '';
    _inputCtl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _pendingImages
      ..clear()
      ..addAll(draft?.images ?? const []);
  }

  void _selectSession(int? id) {
    _dismissKeyboard();
    _saveDraft();
    setState(() {
      _sessionId = id;
      _home = false;
      _loadDraft();
    });
    _scrollToBottom();
  }

  void _toHome() {
    _dismissKeyboard();
    _saveDraft();
    setState(() => _home = true);
  }

  Future<bool> _ensureOnboarded() async {
    bool mustShow = false;
    try {
      final s = ref.read(settingsRepositoryProvider);
      final String? v = await s.getValue(AiSettingsKeys.aiOnboarded);
      mustShow = v != '1';
    } catch (_) {
      return true; // 设置仓库不可用（如测试环境无 DB）→ 不打扰。
    }
    if (!mustShow) return true;
    if (!mounted) return false;

    final bool? go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.shield_outlined),
          title: const Text('关于 AI 对话'),
          content: const Text(
            '使用 AI 对话时，你输入的内容、发送的图片以及 AI 查询到的'
            '课表/日程数据，会发送给你在「AI 服务」中自己配置的第三方服务。\n\n'
            'AI 只在回答需要时自动查询你的课表与日程（只读；任何修改都需你逐条确认）；'
            '密钥等设置仅保存在本机。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('去设置'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开始使用'),
            ),
          ],
        );
      },
    );
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setValue(AiSettingsKeys.aiOnboarded, '1');
    } catch (_) {
      // 落库失败不阻断：下次再弹。
    }
    if (go == false && mounted) {
      Navigator.of(context).pushNamed(AppRoutes.aiServiceSettings);
      return false;
    }
    return true; // true 或点外关闭都视为已知情，可继续。
  }

  Future<void> _handleSend() async {
    if (_preparing) return;
    final text = _inputCtl.text.trim();
    final images = List<String>.of(_pendingImages);
    final source = _sessionId;
    if (text.isEmpty && images.isEmpty) return;
    setState(() => _preparing = true);
    int? createdSession;
    try {
      if (!await _ensureOnboarded() || !mounted) return;
      final cfg = await ref.read(llmConfigProvider.future);
      if (!cfg.usable) {
        _showSnackWithAction(
          '请先到「AI 服务」启用并配置模型',
          onAction: () =>
              Navigator.of(context).pushNamed(AppRoutes.aiServiceSettings),
        );
        return;
      }
      final repo = ref.read(chatRepositoryProvider);
      final id =
          source ??
          await repo.createSession(
            title: _deriveTitle(text.isEmpty ? '图片对话' : text),
          );
      if (source == null) createdSession = id;
      final queue = ref.read(aiQueueControllerProvider);
      await queue.enqueue(sessionId: id, text: text, imagePaths: images);
      if (!mounted) return;
      final sameView = _sessionId == source;
      final current = sameView
          ? _AiDraft(_inputCtl.text, _pendingImages)
          : _drafts[source];
      final unchanged =
          current?.text.trim() == text &&
          _sameImages(current?.images ?? const [], images);
      final prior = _editing.remove(source);
      _drafts[id] = unchanged
          ? (prior ?? _AiDraft('', const []))
          : (current ?? _AiDraft('', const []));
      if (source == null) {
        _drafts.remove(null);
        _editing.remove(null);
      }
      setState(() {
        if (sameView) {
          _sessionId = id;
          _loadDraft();
        }
      });
      _scrollToBottom();
    } catch (_) {
      if (createdSession != null) {
        try {
          final repo = ref.read(chatRepositoryProvider);
          if ((await repo.messagesFor(createdSession)).isEmpty) {
            await repo.deleteSession(createdSession);
            ref.invalidate(sessionsProvider);
          }
        } catch (_) {}
      }
      _showSnack('发送未保存，请检查图片或存储后重试', kind: PlaiToastKind.error);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  static bool _sameImages(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _deriveTitle(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return String.fromCharCodes(one.runes.take(24));
  }

  Future<void> _editQueued(ChatQueueEntry entry) async {
    if (_withdrawing || _editing.containsKey(entry.sessionId)) return;
    _withdrawing = true;
    try {
      final queue = ref.read(aiQueueControllerProvider);
      final removed = await queue.withdraw(entry.id);
      if (removed == null || !mounted) return;
      _saveDraft();
      _dismissKeyboard();
      _editing[entry.sessionId] =
          _drafts[entry.sessionId] ?? _AiDraft('', const []);
      _drafts[entry.sessionId] = _AiDraft(removed.text, removed.imagePaths);
      setState(() {
        _sessionId = entry.sessionId;
        _home = false;
        _loadDraft();
      });
      _focusInputAfterBuild(entry.sessionId);
    } catch (_) {
      _showSnack('撤回未完成，请重试', kind: PlaiToastKind.error);
    } finally {
      _withdrawing = false;
    }
  }

  void _cancelEdit() {
    final previous = _editing.remove(_sessionId);
    if (previous == null) return;
    setState(() {
      _drafts[_sessionId] = previous;
      _loadDraft();
    });
    _focusInputAfterBuild(_sessionId);
  }

  void _focusInputAfterBuild(int? sessionId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _home || _sessionId != sessionId) return;
      _inputFocus.requestFocus();
    });
  }

  Future<void> _showConfirmation(AiPendingConfirmation request) async {
    if (_confirmationOpen) return;
    _dismissKeyboard();
    _confirmationOpen = true;
    try {
      final decisions = await showAiWriteConfirmSheet(
        context,
        allowLater: true,
        items: [
          for (final p in request.proposals)
            AiWriteConfirmItem(
              tool: findAiWriteTool(p.tool.name)!,
              args: Map<String, dynamic>.from(p.args),
              description: p.description,
              swatchHex: findAiWriteTool(p.tool.name)!.swatchHexOf
                  ?.call(p.args),
            ),
        ],
      );
      if (!mounted) return;
      if (decisions.isEmpty) {
        _deferredConfirmation = request.entryId;
        return;
      }
      ref.read(aiQueueControllerProvider).confirm(decisions);
    } finally {
      _confirmationOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(aiQueueControllerProvider);
    ref.listen(aiQueueControllerProvider, (_, next) {
      final request = next.confirmation;
      if (request != null &&
          !_home &&
          request.sessionId == _sessionId &&
          !_confirmationOpen &&
          _deferredConfirmation != request.entryId) {
        unawaited(_showConfirmation(request));
      }
    });
    final sessions = ref.watch(sessionsProvider);
    final title = _home
        ? 'AI 对话'
        : _sessionId == null
        ? '新对话'
        : _displayTitle(_sessionId!, sessions.valueOrNull ?? const []);
    return PopScope(
      canPop: _home,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _toHome();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _home
              ? null
              : IconButton(
                  tooltip: '会话列表',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _toHome,
                ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (!_home)
              IconButton(
                tooltip: '新建对话',
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: () => _selectSession(null),
              ),
            if (!WideLayoutScope.isWideOf(context))
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () =>
                    Navigator.of(context).pushNamed(AppRoutes.settings),
              ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                _queueBanner(queue),
                Expanded(
                  child: _home
                      ? AiSessionsView(
                          onOpen: _selectSession,
                          onNew: () => _selectSession(null),
                          onDeleted: (ids) {
                            for (final id in ids) {
                              _drafts.remove(id);
                              _editing.remove(id);
                            }
                            if (ids.contains(_sessionId)) {
                              setState(() {
                                _sessionId = null;
                                _inputCtl.clear();
                                _pendingImages.clear();
                              });
                            }
                          },
                        )
                      : _buildConversation(queue),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversation(AiQueueController queue) {
    final messages = _buildMessagesArea(queue);
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(child: messages),
          if (_editing.containsKey(_sessionId) || _pendingImages.isNotEmpty)
            // 辅助区按实际内容占高，剩余空间全部留给消息列表。
            // 与 Expanded 并列的 loose Flexible 会把未用份额留在输入栏下方。
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (constraints.maxHeight - 112)
                    .clamp(0.0, 160.0)
                    .toDouble(),
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (_editing.containsKey(_sessionId))
                      Row(
                        children: [
                          const SizedBox(width: 16),
                          const Expanded(child: Text('正在修改撤回的消息')),
                          TextButton(
                            onPressed: _cancelEdit,
                            child: const Text('取消编辑'),
                          ),
                        ],
                      ),
                    _buildPendingImagesBar(),
                  ],
                ),
              ),
            ),
          _buildInputBar(
            maxLines: constraints.maxHeight < 320 ? 1 : 5,
            compact: constraints.maxHeight < 180,
          ),
        ],
      ),
    );
  }

  Widget _queueBanner(AiQueueController queue) {
    if (queue.loading) return const SizedBox.shrink();
    final request = queue.confirmation;
    final blocked = queue.blocked;
    final active = queue.active;
    final compact = MediaQuery.of(context).viewInsets.bottom > 0;
    String? label;
    VoidCallback? tap;
    final buttons = <Widget>[];
    if (queue.storageError != null) {
      label = queue.storageError;
      buttons.add(
        TextButton(onPressed: queue.reloadStorage, child: const Text('重新加载')),
      );
    } else if (request != null) {
      label = '会话「${_sessionTitle(request.sessionId)}」等待确认，队列已暂停';
      tap = () {
        _selectSession(request.sessionId);
        unawaited(_showConfirmation(request));
      };
      buttons.add(TextButton(onPressed: tap, child: const Text('查看确认')));
    } else if (blocked != null) {
      label =
          '${blocked.status == ChatQueueStatus.interrupted ? '处理已中断，请先核对结果' : '处理未完成'}：${blocked.error ?? '请查看原会话'}';
      tap = () => _selectSession(blocked.sessionId);
      buttons.addAll([
        TextButton(onPressed: () => _retry(blocked), child: const Text('重试这条')),
        TextButton(
          onPressed: () => _safeAction(() => queue.skip(blocked.id)),
          child: const Text('跳过并继续'),
        ),
      ]);
    } else if (queue.paused && queue.queuedCount > 0) {
      label = '有 ${queue.queuedCount} 条消息待恢复';
      buttons.add(
        TextButton(onPressed: queue.resume, child: const Text('继续队列')),
      );
    } else if (active != null) {
      label =
          '正在处理「${_sessionTitle(active.sessionId)}」${queue.queuedCount == 0 ? '' : ' · ${queue.queuedCount} 条排队中'}';
      tap = () => _selectSession(active.sessionId);
    } else if (queue.queuedCount > 0) {
      label = '${queue.queuedCount} 条消息排队中';
    }
    if (label == null) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: compact
            ? () {
                _dismissKeyboard();
                tap?.call();
              }
            : tap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.forum_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: compact ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (tap != null) const Icon(Icons.chevron_right, size: 18),
                ],
              ),
              if (buttons.isNotEmpty && !compact)
                Wrap(alignment: WrapAlignment.end, children: buttons),
            ],
          ),
        ),
      ),
    );
  }

  String _sessionTitle(int id) =>
      _displayTitle(id, ref.read(sessionsProvider).valueOrNull ?? const []);
  Future<void> _safeAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _showSnack('操作未完成，请重试', kind: PlaiToastKind.error);
    }
  }

  Future<void> _retry(ChatQueueEntry entry) async {
    final operations = entry.checkpoint['operations'] as List? ?? const [];
    final needsCheck =
        entry.status == ChatQueueStatus.interrupted ||
        operations.any(
          (op) =>
              op is Map &&
              (op['status'] == 'running' || op['status'] == 'unknown'),
        );
    if (needsCheck) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('核对后重试'),
          content: const Text(
            '中断前的操作可能已生效。请先检查任务或课程；重试会再次确认未完成或结果未知的操作，已记录成功的操作会保留。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('先去核对'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('已核对，继续重试'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _safeAction(
      () => ref.read(aiQueueControllerProvider).retry(entry.id),
    );
  }

  Widget _buildMessagesArea(AiQueueController queue) {
    if (_sessionId == null) return _buildEmpty();
    final messages = ref.watch(messagesProvider(_sessionId!));
    if (messages.hasError && !messages.hasValue) {
      return Center(
        child: TextButton(
          onPressed: () => ref.invalidate(messagesProvider(_sessionId!)),
          child: const Text('消息加载失败，点击重试'),
        ),
      );
    }
    if (messages.isLoading && !messages.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    final list =
        orderAiMessages(messages.valueOrNull ?? const [], queue.entries)
            .where(
              (m) =>
                  m.role != ChatRole.tool &&
                  !(m.role == ChatRole.assistant &&
                      m.content.trim().isEmpty &&
                      m.toolRecords.isNotEmpty),
            )
            .toList();
    final widgets = <Widget>[];
    final active = queue.active;
    bool inserted = false;
    for (final m in list) {
      // 当前回复放在之后排队的用户消息之前。
      if (!inserted &&
          active != null &&
          active.sessionId == _sessionId &&
          m.role == ChatRole.user &&
          (m.id ?? 0) > active.userMessageId) {
        widgets.add(_stream(queue));
        inserted = true;
      }
      ChatQueueEntry? job;
      for (final e in queue.entries) {
        if (e.userMessageId == m.id) {
          job = e;
          break;
        }
      }
      widgets.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AiMessageBubble(
              role: m.role,
              content: m.content,
              attachments: m.attachments,
            ),
            if (job != null &&
                job.status != ChatQueueStatus.completed &&
                job.status != ChatQueueStatus.cancelled)
              _queuedMessageActions(job),
          ],
        ),
      );
    }
    if (!inserted && active != null && active.sessionId == _sessionId) {
      widgets.add(_stream(queue));
    }
    if (widgets.isEmpty) return _buildEmpty();
    return ListView.builder(
      controller: _scrollCtl,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: widgets.length,
      itemBuilder: (_, i) => widgets[widgets.length - 1 - i],
    );
  }

  Widget _queuedMessageActions(ChatQueueEntry job) {
    final label = switch (job.status) {
      ChatQueueStatus.queued => '排队中',
      ChatQueueStatus.running => '处理中',
      ChatQueueStatus.waitingConfirmation => '等待确认',
      ChatQueueStatus.failed => '处理失败',
      ChatQueueStatus.interrupted => '已中断',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          if (job.status == ChatQueueStatus.queued) ...[
            TextButton(
              onPressed: _editing.containsKey(job.sessionId)
                  ? null
                  : () => _editQueued(job),
              child: const Text('撤回修改'),
            ),
            TextButton(
              onPressed: () => _safeAction(
                () => ref.read(aiQueueControllerProvider).cancelQueued(job.id),
              ),
              child: const Text('取消发送'),
            ),
          ],
          if (job.status == ChatQueueStatus.waitingConfirmation)
            TextButton(
              onPressed: () {
                final r = ref.read(aiQueueControllerProvider).confirmation;
                if (r != null) unawaited(_showConfirmation(r));
              },
              child: const Text('查看确认'),
            ),
        ],
      ),
    );
  }

  Widget _stream(AiQueueController queue) =>
      ValueListenableBuilder<AiConversationState>(
        valueListenable: queue.activity,
        builder: (context, state, _) => state.text.isNotEmpty
            ? AiMessageBubble(
                role: ChatRole.assistant,
                content: state.text,
                streaming: true,
              )
            : state.progress.isEmpty
            ? const SizedBox.shrink()
            : AiToolTraceRow(
                text: state.progress,
                pending: queue.confirmation == null,
                phase: switch (state.phase) {
                  AiConversationPhase.thinking => AiTracePhase.thinking,
                  AiConversationPhase.querying => AiTracePhase.querying,
                  AiConversationPhase.editing => AiTracePhase.editing,
                  AiConversationPhase.writing => AiTracePhase.writing,
                  AiConversationPhase.summarizing => AiTracePhase.summarizing,
                },
              ),
      );

  Widget _buildEmpty() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('开始一段对话吧', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '对话内容会发送给你自配的第三方服务；\nAI 回答需要时会自动查询你的课表与日程。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );

  /// 选图（相机/系统相册选择器，压缩到可上传尺寸）后附带进输入框。
  Future<void> _pickAndAttachImage({required bool fromCamera}) async {
    if (_preparing) return;
    final source = _sessionId;
    final XFile? photo;
    try {
      photo = await ImagePicker().pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 1600,
      );
    } catch (_) {
      _showSnack('打开相机/相册失败，请检查权限', kind: PlaiToastKind.error);
      return;
    }
    if (photo == null) return; // 用户取消。
    if (!mounted) return;
    if (source != _sessionId) {
      final draft = _drafts[source] ?? _AiDraft('', const []);
      if (draft.images.length < _maxPendingImages) {
        _drafts[source] = _AiDraft(draft.text, [...draft.images, photo.path]);
      }
      return;
    }
    _attachImages(<String>[photo.path]);
  }

  /// 把选中的图片附加到输入框上方预览条（超出上限的忽略并提示）。
  void _attachImages(List<String> paths) {
    if (_preparing || paths.isEmpty) return;
    setState(() {
      for (final String path in paths) {
        if (_pendingImages.length >= _maxPendingImages) {
          _showSnack('最多附带 $_maxPendingImages 张图片', kind: PlaiToastKind.error);
          break;
        }
        if (!_pendingImages.contains(path)) _pendingImages.add(path);
      }
    });
  }

  /// 待发送图片预览条：横排缩略图（× 删除）+「+」续加格（参考豆包）。
  Widget _buildPendingImagesBar() {
    if (_pendingImages.isEmpty) return const SizedBox.shrink();
    // 预览缩略图按显示尺寸 × DPR 解码，避免整张原图解码。
    final int thumbCacheSide = (68 * MediaQuery.of(context).devicePixelRatio)
        .round();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 76,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < _pendingImages.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          File(_pendingImages[i]),
                          width: 68,
                          height: 68,
                          cacheWidth: thumbCacheSide,
                          cacheHeight: thumbCacheSide,
                          fit: BoxFit.cover,
                          errorBuilder: (_, Object? e, _) => Container(
                            width: 68,
                            height: 68,
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _pendingImages.removeAt(i)),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.2,
                              ),
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_pendingImages.length < _maxPendingImages)
                GestureDetector(
                  onTap: _preparing
                      ? null
                      : () => showAiAttachSheet(
                          context,
                          onCamera: () => _pickAndAttachImage(fromCamera: true),
                          onGalleryPicker: () =>
                              _pickAndAttachImage(fromCamera: false),
                          onAttachPhotos: _attachImages,
                          source: ref.read(aiGallerySourceProvider),
                        ),
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.add,
                      size: 30,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标签式输入栏：大圆角胶囊、白底轻投影，左相机钮（S9 接入）+
  /// 右端圆形发送按钮（参考主流聊天 App 输入栏布局）。
  Widget _buildInputBar({int maxLines = 5, bool compact = false}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canSend =
        !_preparing &&
        (_inputCtl.text.trim().isNotEmpty || _pendingImages.isNotEmpty);
    return Padding(
      key: const Key('ai_message_composer'),
      padding: EdgeInsets.fromLTRB(12, compact ? 4 : 6, 12, compact ? 4 : 8),
      child: SafeArea(
        // 键盘弹出时 Scaffold 已把页面缩到键盘上方；再保留底部安全区
        // 会把输入框顶离键盘一段空白（手势条高度），故此时关闭 bottom。
        top: false,
        bottom: MediaQuery.of(context).viewInsets.bottom == 0,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 6,
            vertical: compact ? 2 : 4,
          ),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '拍照附到消息',
                icon: const Icon(Icons.photo_camera_outlined, size: 24),
                onPressed: _preparing
                    ? null
                    : () => _pickAndAttachImage(fromCamera: true),
              ),
              Expanded(
                child: TextField(
                  key: const Key('ai_message_input'),
                  controller: _inputCtl,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: maxLines,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  enabled: !_preparing,
                  decoration: InputDecoration(
                    hintText: '输入消息',
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: compact ? 6 : 13,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_preparing) return;
                    // 多行输入时，回车保留；发送按钮触发发送。
                  },
                ),
              ),
              IconButton.filled(
                tooltip: '发送',
                style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
                icon: const Icon(Icons.send, size: 20),
                onPressed: canSend ? _handleSend : null,
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(Icons.add, size: 28),
                onPressed: _preparing
                    ? null
                    : () => showAiAttachSheet(
                        context,
                        onCamera: () => _pickAndAttachImage(fromCamera: true),
                        onGalleryPicker: () =>
                            _pickAndAttachImage(fromCamera: false),
                        onAttachPhotos: _attachImages,
                        source: ref.read(aiGallerySourceProvider),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 工具

  void _scrollToBottom() {
    // reverse 列表：底部 = offset 0。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtl.hasClients) return;
      if (_scrollCtl.offset <= 0) return;
      _scrollCtl.animateTo(
        0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String message, {PlaiToastKind kind = PlaiToastKind.normal}) {
    if (!mounted) return;
    showPlaiToast(context, message, kind: kind);
  }

  void _showSnackWithAction(String message, {required VoidCallback onAction}) {
    if (!mounted) return;
    showPlaiToast(
      context,
      message,
      kind: PlaiToastKind.error,
      actionLabel: '去设置',
      onAction: onAction,
    );
  }
}

/// 当前会话展示标题（会话列表中查不到则回退「新对话」）。
String _displayTitle(int sessionId, List<ChatSession> sessions) {
  for (final ChatSession s in sessions) {
    if (s.id == sessionId) {
      return s.title.trim().isEmpty ? '新对话' : s.title;
    }
  }
  return '新对话';
}
