import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/plai_toast.dart';
import 'notification_diagnostics.dart';
import 'notification_providers.dart';

/// 提醒诊断自检页。
///
/// 归属 plai-notify。目的：把「提醒不响」的排查从黑盒变可观测 ——
/// 权限状态、系统里实际待触发的条数、上次重排结果、本次启动的静默降级
/// 条数，以及一键「发测试提醒 / 复制诊断信息」。
///
/// 本页只读 + 触发调度接口，不改变任何调度行为。
/// 入口：设置页「提醒诊断」，路由 `AppRoutes.notificationDiagnostics`。
class NotificationDiagnosticsPage extends ConsumerStatefulWidget {
  const NotificationDiagnosticsPage({super.key});

  @override
  ConsumerState<NotificationDiagnosticsPage> createState() =>
      _NotificationDiagnosticsPageState();
}

class _NotificationDiagnosticsPageState
    extends ConsumerState<NotificationDiagnosticsPage> {
  bool _sendingTest = false;

  /// 发一条 10 秒后的测试提醒；反馈用气泡（全仓库统一，不用 SnackBar）。
  Future<void> _sendTestReminder() async {
    if (_sendingTest) return;
    setState(() => _sendingTest = true);
    try {
      await ref.read(notificationSchedulerProvider).scheduleTestReminder();
      if (!mounted) return;
      showPlaiToast(context, '测试提醒已安排，10 秒后触发');
    } catch (e) {
      if (!mounted) return;
      showPlaiToast(
        context,
        '发送测试提醒失败：$e',
        kind: PlaiToastKind.error,
      );
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  /// 把全部诊断信息拼成纯文本进剪贴板。
  Future<void> _copyDiagnostics() async {
    final NotificationDiagnostics? d =
        ref.read(notificationDiagnosticsProvider).valueOrNull;
    if (d == null) {
      showPlaiToast(context, '诊断信息尚未就绪', kind: PlaiToastKind.error);
      return;
    }
    try {
      await Clipboard.setData(
        ClipboardData(text: diagnosticsToPlainText(d)),
      );
      if (!mounted) return;
      showPlaiToast(context, '诊断信息已复制');
    } catch (e) {
      if (!mounted) return;
      showPlaiToast(context, '复制失败：$e', kind: PlaiToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<NotificationDiagnostics> async =
        ref.watch(notificationDiagnosticsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒诊断'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新采集',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(notificationDiagnosticsProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // 采集失败也应给出可用页面而不是白屏；正常情况下采集函数不抛。
        error: (Object e, StackTrace _) => ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text('诊断信息读取失败：$e', style: theme.textTheme.bodyMedium),
          ],
        ),
        data: (NotificationDiagnostics d) => _buildBody(theme, d),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, NotificationDiagnostics d) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text('为什么会不响？', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '提醒由系统闹钟负责弹出。下面三项任一异常、或「系统里待触发提醒」为 0 条，'
          '都会导致到点不响。',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
        const SizedBox(height: 16),

        // ---------------------------------------------------------- 权限三项
        Card(
          child: Column(
            children: <Widget>[
              _StatusRow(
                label: '通知权限',
                ok: d.notificationsEnabled,
                abnormalHint: '系统会拦截 Plai 的所有通知，提醒一定不响。'
                    '请到系统设置允许 Plai 发送通知。',
              ),
              const Divider(height: 1),
              _StatusRow(
                label: '精确闹钟',
                ok: d.exactAlarmsAllowed,
                abnormalHint: '提醒仍会触发，但只能非精确调度，'
                    '可能被系统延迟几分钟到几小时。',
              ),
              const Divider(height: 1),
              _StatusRow(
                label: 'App 内总开关',
                ok: d.remindersEnabled,
                abnormalHint: 'App 内通知总开关已关闭，不会调度任何提醒。',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ------------------------------------------------------ 待触发提醒
        _PendingCard(diagnostics: d),
        const SizedBox(height: 16),

        // -------------------------------------------------------- 上次重排
        _InfoCard(
          title: '上次重排',
          value: _rescheduleText(d),
          hint: '总开关关闭时结果会是「已关闭」；若为「失败」，说明重排过程出错。',
        ),
        const SizedBox(height: 12),

        // ------------------------------------------------------ 降级条数
        _InfoCard(
          title: '本次启动降级条数',
          value: '${d.degradedScheduleCount} 条',
          hint: d.degradedScheduleCount > 0
              ? '本次启动有 ${d.degradedScheduleCount} 条提醒只能非精确调度，'
                  '可能被系统延迟几分钟到几小时。'
              : '没有提醒发生静默降级。',
          warning: d.degradedScheduleCount > 0,
        ),
        const SizedBox(height: 12),

        // ------------------------------------------------------ 系统版本
        _InfoCard(title: '系统版本', value: d.osVersion),
        const SizedBox(height: 20),

        // -------------------------------------------------------- 测试提醒
        Text('发一条测试提醒（10 秒后）', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '① 点一次、留在 App 里 —— 10 秒内应弹出，验证通知渠道与提示音；\n'
          '② 再点一次后立刻划掉 App（从最近任务清掉）—— 10 秒后仍应弹出，'
          '这才验证「App 未启动也能响」。\n'
          '若 ① 有、② 没有，多半是系统省电限制杀掉了后台，'
          '请到「保活引导」按品牌关闭限制。',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _sendingTest ? null : _sendTestReminder,
          icon: const Icon(Icons.notifications_active),
          label: const Text('发一条测试提醒'),
        ),
        const SizedBox(height: 24),

        // ------------------------------------------------------ 复制诊断
        OutlinedButton.icon(
          onPressed: _copyDiagnostics,
          icon: const Icon(Icons.copy_all),
          label: const Text('复制诊断信息'),
        ),
      ],
    );
  }

  /// 「3 分钟前 · 成功 · 排了 5 条」。
  static String _rescheduleText(NotificationDiagnostics d) {
    final DateTime? at = d.lastRescheduleAt;
    if (at == null) return '暂无记录';
    final String result = switch (d.lastRescheduleResult) {
      'ok' => '成功',
      'disabled' => '已关闭（总开关未开）',
      'failed' => '失败',
      _ => '未知',
    };
    final String count =
        d.lastRescheduleCount == null ? '' : ' · 排了 ${d.lastRescheduleCount} 条';
    return '${_relativeTime(at)} · $result$count';
  }

  /// 相对时间（够用即可，不引额外依赖）。
  static String _relativeTime(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    if (d.isNegative || d.inSeconds < 60) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}

/// 一行权限状态：正常 / 异常 / 未知 + 异常后果说明。
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.ok,
    required this.abnormalHint,
  });

  final String label;

  /// null = 未知（无法判定），不当作异常。
  final bool? ok;

  /// 异常时展示的人话解释（说明会导致什么后果）。
  final String abnormalHint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final (String text, Color color, IconData icon) = switch (ok) {
      true => ('正常', scheme.primary, Icons.check_circle),
      false => ('异常', scheme.error, Icons.error),
      null => ('未知', scheme.onSurfaceVariant, Icons.help_outline),
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(label, style: theme.textTheme.bodyLarge),
              ),
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (ok == false) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              abnormalHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.error,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「系统里实际待触发的提醒」卡片 —— 诊断最关键一项，0 条时醒目提示。
class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.diagnostics});

  final NotificationDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool empty = diagnostics.pendingTotal == 0;
    return Card(
      color: empty ? scheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  empty ? Icons.warning_amber : Icons.alarm,
                  color: empty ? scheme.onErrorContainer : scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '系统里实际待触发提醒',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: empty ? scheme.onErrorContainer : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '上课提醒 ${diagnostics.pendingClassCount} 条 · '
              '日程提醒 ${diagnostics.pendingTaskCount} 条'
              '${diagnostics.pendingOtherCount > 0 ? ' · 其他 ${diagnostics.pendingOtherCount} 条' : ''}',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: empty ? scheme.onErrorContainer : null,
              ),
            ),
            if (empty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '系统里没有任何待触发的提醒 —— 到点必然不会响。'
                '请检查上面的总开关与权限，或回到设置触发一次「重排提醒」。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 通用信息卡片：标题 + 值（+ 可选提示）。
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.value,
    this.hint,
    this.warning = false,
  });

  final String title;
  final String value;
  final String? hint;

  /// true 时用醒目（errorContainer）样式。
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color foreground = warning ? scheme.onErrorContainer : scheme.onSurface;
    return Card(
      color: warning ? scheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(color: foreground),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: warning ? scheme.onErrorContainer : scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
