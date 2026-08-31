import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_providers.dart';

/// 国内 ROM 保活引导页。
///
/// 归属 plai-notify。设置模块在「首次开启提醒」时通过命名路由
/// [AppRoutes.keepAliveGuide] 进入本页（并应先调用
/// `NotificationScheduler.shouldShowKeepAliveGuide()` 判断是否需要展示）。
///
/// 页面职责：按品牌给出「关闭省电限制 / 允许自启动 / 允许后台活动」的
/// 指引路径。打开本页即标记 `keepAliveGuideShown`，后续不再自动弹出。
class KeepAliveGuidePage extends ConsumerStatefulWidget {
  const KeepAliveGuidePage({super.key});

  @override
  ConsumerState<KeepAliveGuidePage> createState() =>
      _KeepAliveGuidePageState();
}

class _KeepAliveGuidePageState extends ConsumerState<KeepAliveGuidePage> {
  int _selectedBrand = 0;

  @override
  void initState() {
    super.initState();
    // 页面一旦展示，标记为已看过，避免下次提醒开启时再次弹出。
    ref
        .read(notificationSchedulerProvider)
        .markKeepAliveGuideShown();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BrandGuide brand = _brands[_selectedBrand];

    return Scaffold(
      appBar: AppBar(title: const Text('提醒保活引导')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('为什么需要保活？', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '小米 / 华为 / OPPO / vivo / 荣耀等国内系统默认会对 App 做省电限制：'
            'App 退到后台后可能被杀进程，导致「上课提醒 / 任务提醒」不能准时弹出。'
            '请按你的手机品牌，完成下面几步开启保活。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _brands.length; i++)
                ChoiceChip(
                  label: Text(_brands[i].name),
                  avatar: Icon(_brands[i].icon, size: 18),
                  selected: _selectedBrand == i,
                  onSelected: (_) => setState(() => _selectedBrand = i),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(brand.icon, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '${brand.name} 保活步骤',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (int i = 0; i < brand.steps.length; i++)
                    _StepTile(index: i + 1, text: brand.steps[i]),
                ],
              ),
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
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
            label: const Text('我已完成设置'),
          ),
        ],
      ),
    );
  }
}

/// 单个步骤展示。
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
        children: [
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

/// 品牌保活指引数据。
class BrandGuide {
  const BrandGuide(this.name, this.icon, this.steps);

  final String name;
  final IconData icon;
  final List<String> steps;
}

const List<BrandGuide> _brands = <BrandGuide>[
  BrandGuide('小米/红米', Icons.smartphone, <String>[
    '打开「设置」→「应用设置」→「应用管理」→ 找到「Plai」',
    '「省电策略」选择「无限制」（关闭省电限制）',
    '打开「自启动」开关（允许自启动）',
    '「通知管理」→ 允许「通知」',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  BrandGuide('华为', Icons.phone_android, <String>[
    '打开「设置」→「应用」→「应用启动管理」→ 找到「Plai」',
    '关闭「自动管理」，手动开启「允许自启动」「允许关联启动」「允许后台活动」',
    '「设置」→「电池」→「更多电池设置」→ 开启「休眠时始终保持网络连接」',
    '「设置」→「通知」→ 允许 Plai 发送通知',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  BrandGuide('荣耀', Icons.phone_iphone, <String>[
    '打开「手机管家」→「应用启动管理」→ 找到「Plai」',
    '关闭「自动管理」，开启「允许自启动」「允许后台活动」',
    '「设置」→「应用」→「应用管理」→ Plai →「通知」→ 允许通知',
    '「设置」→「电池」→「省电模式」→ 将 Plai 设为「不受限制」',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  BrandGuide('OPPO', Icons.phone_android, <String>[
    '打开「设置」→「应用管理」→「应用列表」→ 找到「Plai」',
    '「耗电管理」→ 选择「允许后台运行」/「允许完全后台行为」',
    '打开「允许自启动」',
    '「设置」→「电池」→「更多设置」→ 将 Plai 加入「不优化」/「不受限制」',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  BrandGuide('vivo', Icons.phone_android, <String>[
    '打开「设置」→「电池」→「后台耗电管理」→ 找到「Plai」并「允许」',
    '「设置」→「应用与权限」→「权限管理」→ Plai → 开启「自启动」',
    '打开「i管家」→「应用管理」→ Plai →「允许自启动」「允许后台运行」',
    '「设置」→「通知与状态栏」→ 允许 Plai 发送通知',
    '在「最近任务」界面下拉 Plai 卡片，点击锁形图标锁定后台',
  ]),
  BrandGuide('通用/其他', Icons.info_outline, <String>[
    '「设置」→「应用」→「通知」→ 允许 Plai 发送通知',
    '「设置」→「应用」→「特殊应用权限」→「闹钟和提醒」→ 允许「精确闹钟」',
    '「设置」→「电池 / 省电」→ 将 Plai 加入「不受限制」/「不优化」列表',
    '若系统有「自启动管理」入口，允许 Plai 自启动',
  ]),
];
