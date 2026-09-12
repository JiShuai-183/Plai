import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/plai_toast.dart';
import 'keep_alive_checker.dart';
import 'notification_diagnostics.dart';
import 'notification_providers.dart';

/// 国内 ROM「提醒保护」页（保活检测 + 提醒诊断）。
///
/// 归属 plai-notify。设置模块在「首次开启提醒」时通过命名路由
/// [AppRoutes.keepAliveGuide] 进入本页（并应先调用
/// `NotificationScheduler.shouldShowKeepAliveGuide()` 判断是否需要展示）。
///
/// 页面职责：
/// 1. 按 `Build.MANUFACTURER` 自动预选品牌（用户可改，选择持久化）；
/// 2. 一键「检测」逐项给出三态结果（✓ 已完成 / 未完成去设置 / 无法自动检测
///    请自行确认），跳转走原生 `plai/keep_alive` 通道；
/// 3. 保留各品牌完整文字步骤（跳过去也可能找不到入口时的兜底）；
/// 4. 并入原「提醒诊断」页的信息（待触发条数 / 上次重排 / 降级条数 /
///    发测试提醒 / 复制诊断信息）。
///
/// 打开本页即标记 `keepAliveGuideShown`，后续不再自动弹出。
class KeepAliveGuidePage extends ConsumerStatefulWidget {
  const KeepAliveGuidePage({super.key});

  @override
  ConsumerState<KeepAliveGuidePage> createState() => _KeepAliveGuidePageState();
}

class _KeepAliveGuidePageState extends ConsumerState<KeepAliveGuidePage> {
  KeepAliveBrand _brand = KeepAliveBrand.generic;
  bool _detecting = false;
  bool _detected = false;
  List<KeepAliveCheckItem> _items = const <KeepAliveCheckItem>[];
  final Set<String> _manuallyConfirmed = <String>{};
  bool _sendingTest = false;

  @override
  void initState() {
    super.initState();
    // 页面一旦展示，标记为已看过，避免下次提醒开启时再次弹出。
    ref.read(notificationSchedulerProvider).markKeepAliveGuideShown();
    _loadBrand();
  }

  /// 预选品牌：优先用户上次选择，其次 `getManufacturer()`，最后通用。
  Future<void> _loadBrand() async {
    final KeepAliveChecker checker = ref.read(keepAliveCheckerProvider);
    KeepAliveBrand brand = KeepAliveBrand.generic;
    try {
      final KeepAliveBrand? stored = await checker.readSelectedBrand();
      brand = stored ??
          KeepAliveBrand.fromManufacturer(await checker.getManufacturer());
    } catch (_) {
      brand = KeepAliveBrand.generic;
    }
    if (!mounted) return;
    setState(() => _brand = brand);
  }

  void _onBrandSelected(KeepAliveBrand brand) {
    setState(() => _brand = brand);
    ref.read(keepAliveCheckerProvider).writeSelectedBrand(brand);
  }

  /// 跑一次检测：先清掉陈旧的手动确认，再逐项采集。
  Future<void> _detect() async {
    if (_detecting) return;
    setState(() => _detecting = true);
    final KeepAliveChecker checker = ref.read(keepAliveCheckerProvider);
    await checker.clearManualConfirms();
    List<KeepAliveCheckItem> items = const <KeepAliveCheckItem>[];
    try {
      items = await checker.collectChecks(_brand);
    } catch (_) {
      items = const <KeepAliveCheckItem>[];
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _manuallyConfirmed.clear();
      _detected = true;
      _detecting = false;
    });
    if (items.isEmpty) {
      showPlaiToast(
        context,
        '检测失败，请稍后重试或按下方步骤手动确认',
        kind: PlaiToastKind.error,
      );
    }
  }

  Future<void> _openSettings(KeepAliveCheckItem item) async {
    final bool ok = await ref
        .read(keepAliveCheckerProvider)
        .openSettings(item.settingsTarget);
    if (!mounted) return;
    showPlaiToast(
      context,
      ok ? '已打开系统设置页' : '无法打开系统设置页，请手动进入系统设置',
      kind: ok ? PlaiToastKind.normal : PlaiToastKind.error,
    );
  }

  Future<void> _onManualConfirm(KeepAliveCheckItem item, bool value) async {
    setState(() {
      if (value) {
        _manuallyConfirmed.add(item.id);
      } else {
        _manuallyConfirmed.remove(item.id);
      }
    });
    await ref.read(keepAliveCheckerProvider).writeManualConfirm(item.id, value);
  }

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
      showPlaiToast(context, '发送测试提醒失败：$e', kind: PlaiToastKind.error);
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
      await Clipboard.setData(ClipboardData(text: diagnosticsToPlainText(d)));
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
    final BrandGuide guide = _brandGuides[_brand] ?? _genericGuide;

    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒保护'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新采集诊断',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(notificationDiagnosticsProvider),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // ------------------------------------------------------ 说明
          Text('为什么需要保活？', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '小米 / 华为 / OPPO / vivo / 荣耀等国内系统默认会对 App 做省电限制：'
            'App 退到后台后可能被杀进程，导致「上课提醒 / 任务提醒」不能准时弹出。'
            '请按你的手机品牌，完成下面几步开启保活。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 16),

          // -------------------------------------------------- 品牌选择
          Text('你的手机品牌', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final KeepAliveBrand brand in KeepAliveBrand.values)
                ChoiceChip(
                  label: Text(_brandGuides[brand]?.name ?? '通用/其他'),
                  avatar: Icon(
                    _brandGuides[brand]?.icon ?? Icons.info_outline,
                    size: 18,
                  ),
                  selected: _brand == brand,
                  onSelected: (_) => _onBrandSelected(brand),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // ------------------------------------------------------ 检测
          FilledButton.icon(
            onPressed: _detecting ? null : _detect,
            icon: _detecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check),
            label: Text(_detecting ? '检测中…' : '检测当前设置'),
          ),
          const SizedBox(height: 8),
          Text(
            '检测会逐项核对通知权限、精确闹钟、电池优化与自启动。'
            '「自启动」系统未提供标准接口，无法确定时会请你自行确认。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),

          if (_detected && _items.isEmpty)
            Text(
              '检测失败，未取到结果。可下拉重试，或直接按下方步骤手动设置。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          for (final KeepAliveCheckItem item in _items)
            _buildCheckItem(theme, item),

          // ------------------------------------------------ 完整步骤
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              leading: Icon(guide.icon, color: theme.colorScheme.primary),
              title: Text('${guide.name} 完整步骤'),
              subtitle: const Text('跳转后找不到入口时，照这里手动找'),
              initiallyExpanded: !_detected,
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: <Widget>[
                for (int i = 0; i < guide.steps.length; i++)
                  _StepTile(index: i + 1, text: guide.steps[i]),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '提示：以上为各品牌系统的通用指引，具体菜单名可能随系统版本不同略有差异。'
            '若找不到对应入口，可在系统设置中搜索「自启动」「省电」「后台」等关键词。'
            '部分机型还需在「最近任务」界面下拉 Plai 卡片并点击锁形图标，锁定后台。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),

          const Divider(),
          const SizedBox(height: 12),

          // ------------------------------------------------------ 诊断
          _buildDiagnosticsSection(theme),
          const SizedBox(height: 24),

          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
            label: const Text('完成'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 检测项

  Widget _buildCheckItem(ThemeData theme, KeepAliveCheckItem item) {
    final ColorScheme scheme = theme.colorScheme;
    final bool confirmed = _manuallyConfirmed.contains(item.id);
    final bool isManualPending =
        item.state == KeepAliveCheckState.unknown && item.manualConfirmable;
    final bool done =
        item.state == KeepAliveCheckState.ok || (isManualPending && confirmed);
    final bool broken = item.state == KeepAliveCheckState.notOk;

    final (Color color, IconData icon, String label) = done
        ? (scheme.primary, Icons.check_circle, '已完成')
        : broken
            ? (scheme.error, Icons.error, '未完成')
            : (scheme.onSurfaceVariant, Icons.help_outline, '待确认');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(item.title, style: theme.textTheme.bodyLarge),
                ),
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (item.state == KeepAliveCheckState.unknown) ...<Widget>[
              Text(
                '无法自动检测，请自行确认。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              item.detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: broken ? scheme.error : scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (!done) ...<Widget>[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _openSettings(item),
                icon: const Icon(Icons.settings, size: 18),
                label: const Text('点击设置'),
              ),
            ],
            if (isManualPending && !confirmed) ...<Widget>[
              CheckboxListTile(
                value: confirmed,
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (bool? v) => _onManualConfirm(item, v ?? false),
                title: const Text('我已完成'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 诊断区

  Widget _buildDiagnosticsSection(ThemeData theme) {
    final AsyncValue<NotificationDiagnostics> async =
        ref.watch(notificationDiagnosticsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('提醒诊断', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          // 采集失败也给出可用页面而不是白屏；正常情况下采集函数不抛。
          error: (Object e, StackTrace _) => Text(
            '诊断信息读取失败：$e',
            style: theme.textTheme.bodyMedium,
          ),
          data: (NotificationDiagnostics d) => _buildDiagnosticsBody(theme, d),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsBody(ThemeData theme, NotificationDiagnostics d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '提醒由系统闹钟负责弹出。下面任一项异常、或「系统里待触发提醒」为 0 条，'
          '都会导致到点不响。',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
        const SizedBox(height: 12),
        _DiagnosticCard(diagnostics: d),
        const SizedBox(height: 12),
        _InfoCard(title: '系统版本', value: d.osVersion),
        const SizedBox(height: 20),
        Text('发一条测试提醒（10 秒后）', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '① 点一次、留在 App 里 —— 10 秒内应弹出，验证通知渠道与提示音；\n'
          '② 再点一次后立刻划掉 App（从最近任务清掉）—— 10 秒后仍应弹出，'
          '这才验证「App 未启动也能响」。\n'
          '若 ① 有、② 没有，多半是系统省电限制杀掉了后台，'
          '请按上方步骤关闭限制。',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _sendingTest ? null : _sendTestReminder,
          icon: const Icon(Icons.notifications_active),
          label: const Text('发一条测试提醒'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _copyDiagnostics,
          icon: const Icon(Icons.copy_all),
          label: const Text('复制诊断信息'),
        ),
      ],
    );
  }
}

/// 单项检测结果卡片中的「一步」展示。
class _StepTile extends StatelessWidget {
  const _StepTile({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 11,
            backgroundColor: theme.colorScheme.primary,
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// 诊断总览卡：待触发条数 / 上次重排 / 降级条数。
class _DiagnosticCard extends StatelessWidget {
  const _DiagnosticCard({required this.diagnostics});

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
            const SizedBox(height: 8),
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
                '请检查总开关与权限，或回设置触发一次「重排提醒」。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _kv(theme, '上次重排', _rescheduleText(diagnostics)),
            const SizedBox(height: 8),
            _kv(
              theme,
              '本次启动降级条数',
              '${diagnostics.degradedScheduleCount} 条'
                  '${diagnostics.degradedScheduleCount > 0 ? '（可能被系统延迟）' : ''}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
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

/// 通用信息卡片：标题 + 值。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 品牌保活指引数据。
class BrandGuide {
  const BrandGuide(this.name, this.icon, this.steps);

  final String name;
  final IconData icon;
  final List<String> steps;
}

/// 通用品牌兜底（理论不可达，避免 `!` 崩）。
const BrandGuide _genericGuide = BrandGuide(
  '通用/其他',
  Icons.info_outline,
  <String>[],
);

/// 品牌 → 保活步骤（原文与旧版引导页逐字一致，未删减）。
const Map<KeepAliveBrand, BrandGuide> _brandGuides = <KeepAliveBrand, BrandGuide>{
  KeepAliveBrand.xiaomi: BrandGuide('小米/红米', Icons.smartphone, <String>[
    '打开「设置」→「应用设置」→「应用管理」→ 找到「Plai」',
    '「省电策略」选择「无限制」（关闭省电限制）',
    '打开「自启动」开关（允许自启动）',
    '「通知管理」→ 允许「通知」',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  KeepAliveBrand.huawei: BrandGuide('华为', Icons.phone_android, <String>[
    '打开「设置」→「应用」→「应用启动管理」→ 找到「Plai」',
    '关闭「自动管理」，手动开启「允许自启动」「允许关联启动」「允许后台活动」',
    '「设置」→「电池」→「更多电池设置」→ 开启「休眠时始终保持网络连接」',
    '「设置」→「通知」→ 允许 Plai 发送通知',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  KeepAliveBrand.honor: BrandGuide('荣耀', Icons.phone_iphone, <String>[
    '打开「手机管家」→「应用启动管理」→ 找到「Plai」',
    '关闭「自动管理」，开启「允许自启动」「允许后台活动」',
    '「设置」→「应用」→「应用管理」→ Plai →「通知」→ 允许通知',
    '「设置」→「电池」→「省电模式」→ 将 Plai 设为「不受限制」',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  KeepAliveBrand.oppo: BrandGuide('OPPO', Icons.phone_android, <String>[
    '打开「设置」→「应用管理」→「应用列表」→ 找到「Plai」',
    '「耗电管理」→ 选择「允许后台运行」/「允许完全后台行为」',
    '打开「允许自启动」',
    '「设置」→「电池」→「更多设置」→ 将 Plai 加入「不优化」/「不受限制」',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  KeepAliveBrand.vivo: BrandGuide('vivo', Icons.phone_android, <String>[
    '打开「设置」→「电池」→「后台耗电管理」→ 找到「Plai」并「允许」',
    '「设置」→「应用与权限」→「权限管理」→ Plai → 开启「自启动」',
    '打开「i管家」→「应用管理」→ Plai →「允许自启动」「允许后台运行」',
    '「设置」→「通知与状态栏」→ 允许 Plai 发送通知',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  KeepAliveBrand.generic:
      BrandGuide('通用/其他', Icons.info_outline, <String>[
    '「设置」→「应用」→「通知」→ 允许 Plai 发送通知',
    '「设置」→「应用」→「特殊应用权限」→「闹钟和提醒」→ 允许「精确闹钟」',
    '「设置」→「电池 / 省电」→ 将 Plai 加入「不受限制」/「不优化」列表',
    '若系统有「自启动管理」入口，允许 Plai 自启动',
  ]),
};
