import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routes/app_routes.dart';
import '../timetable/color_utils.dart';
import '../timetable/timetable_providers.dart'
    hide settingsRepositoryProvider; // 避免与 settings_providers 重名
import '../timetable/timetable_settings_keys.dart';
import 'settings_providers.dart';

/// 课表设置页：节次时间表 / 课表颜色 / 样式 三组。
///
/// 由设置页「课表设置」入口进入；节次 / 颜色 / 样式设置均持久化到
/// `plai-data` 的 setting 表（键见 [TimetableSettingsKeys]），
/// 颜色与开关改动后使 [timetableStatusSettingsProvider] 失效联动课表页。
class TimetableSettingsPage extends ConsumerStatefulWidget {
  const TimetableSettingsPage({super.key});

  @override
  ConsumerState<TimetableSettingsPage> createState() =>
      _TimetableSettingsPageState();
}

class _TimetableSettingsPageState extends ConsumerState<TimetableSettingsPage> {
  /// 节次数量（用于节次时间表入口副标题）。
  int _periodCount = 0;

  /// 状态色 / 默认课程颜色色板（与课程表单一致，11 色）。
  static const List<String> _palette = [
    '#E57373',
    '#F06292',
    '#BA68C8',
    '#9575CD',
    '#64B5F6',
    '#4FC3F7',
    '#4DB6AC',
    '#81C784',
    '#FFB74D',
    '#A1887F',
    '#9E9E9E',
  ];

  /// 课表设置读取失败时的兜底默认值（与 [TimetableSettingsKeys] 默认一致）。
  static const TimetableStatusSettings _defaultTimetableSettings =
      TimetableStatusSettings(
        statusColorsEnabled: TimetableSettingsKeys.defaultStatusColorsEnabled,
        ongoingColor: TimetableSettingsKeys.defaultStatusColorOngoing,
        upcomingColor: TimetableSettingsKeys.defaultStatusColorUpcoming,
        finishedColor: TimetableSettingsKeys.defaultStatusColorFinished,
        finishedTextFade: TimetableSettingsKeys.defaultFinishedTextFade,
        finishedTextThin: TimetableSettingsKeys.defaultFinishedTextThin,
        defaultCourseColor: TimetableSettingsKeys.defaultCourseColorDefault,
      );

  @override
  void initState() {
    super.initState();
    _loadPeriodCount();
  }

  /// 本地读取节次数；数据库不可用（如 widget 测试环境）时回退 0。
  Future<void> _loadPeriodCount() async {
    int count = 0;
    try {
      final periods = await ref
          .read(settingsTimetableRepoProvider)
          .getPeriods();
      count = periods.length;
    } catch (_) {
      // 保持 0。
    }
    if (!mounted) return;
    setState(() => _periodCount = count);
  }

  // ------------------------------------------------------------ 写键

  /// 写课表设置键（状态色 / 默认课程颜色 / 开关），随后使 provider 失效联动课表页。
  Future<void> _setTimetableValue(String key, String value) async {
    await ref.read(settingsRepositoryProvider).setValue(key, value);
    ref.invalidate(timetableStatusSettingsProvider);
  }

  /// 弹色板：点色即 pop 返回 hex（无色返回 ''）；「恢复默认」pop 返回该键默认值；取消返回 null。
  Future<String?> _pickTimetableColor({
    required String title,
    required String current,
    required String defaultHex,
  }) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: Text(title),
          children: [
            ListTile(
              leading: const _ColorDot(''),
              title: const Text('无色'),
              trailing: current.isEmpty ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(''),
            ),
            for (final String hex in _palette)
              ListTile(
                leading: _ColorDot(hex),
                title: Text(hex),
                trailing: current == hex ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(hex),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('恢复默认'),
              trailing: current == defaultHex ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(defaultHex),
            ),
          ],
        );
      },
    );
  }

  /// 弹色板并把选中值写进对应键（值不变则跳过）。
  Future<void> _onPickColor({
    required String title,
    required String key,
    required String current,
    required String defaultHex,
  }) async {
    final String? picked = await _pickTimetableColor(
      title: title,
      current: current,
      defaultHex: defaultHex,
    );
    if (picked == null || picked == current || !mounted) return;
    await _setTimetableValue(key, picked);
  }

  Future<void> _editDesktopScale(double current) async {
    double selected = current;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          final int percent = (selected * 100).round();
          return AlertDialog(
            title: const Text('电脑端课表缩放'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$percent%',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Slider(
                  min: TimetableSettingsKeys.minDesktopScale,
                  max: TimetableSettingsKeys.maxDesktopScale,
                  divisions: 7,
                  label: '$percent%',
                  value: selected,
                  onChanged: (double value) => setDialogState(
                    () => selected =
                        TimetableSettingsKeys.normalizeDesktopScale(value),
                  ),
                ),
                const Text('也可在课表页按住 Ctrl 后滚动鼠标滚轮调节'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => setDialogState(
                  () => selected = TimetableSettingsKeys.defaultDesktopScale,
                ),
                child: const Text('恢复 100%'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  ref
                      .read(timetableDesktopScaleProvider.notifier)
                      .setScale(selected);
                  Navigator.of(context).pop();
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    // provider 不可用（如测试环境 DB 缺失）时兜底默认值，页面正常渲染。
    final TimetableStatusSettings s = ref
        .watch(timetableStatusSettingsProvider)
        .when(
          loading: () => _defaultTimetableSettings,
          error: (_, _) => _defaultTimetableSettings,
          data: (data) => data,
        );
    final double desktopScale = ref.watch(timetableDesktopScaleProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('课表设置')),
      body: ListView(
        children: [
          const _SectionHeader('节次时间表'),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('节次时间表'),
            subtitle: Text('共 $_periodCount 节 · 编辑各节起止时间'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).pushNamed(AppRoutes.periodsEdit);
              if (mounted) _loadPeriodCount(); // 返回后刷新节次数量
            },
          ),
          const _SectionHeader('课表颜色'),
          ..._buildStatusColorTiles(s),
          const _SectionHeader('样式'),
          ..._buildStyleTiles(s, desktopScale),
        ],
      ),
    );
  }

  /// 「课表颜色」分组：三种状态色。
  List<Widget> _buildStatusColorTiles(TimetableStatusSettings s) {
    return [
      ListTile(
        title: const Text('正在上课'),
        trailing: _ColorDot(s.ongoingColor),
        onTap: () => _onPickColor(
          title: '正在上课',
          key: TimetableSettingsKeys.statusColorOngoing,
          current: s.ongoingColor,
          defaultHex: TimetableSettingsKeys.defaultStatusColorOngoing,
        ),
      ),
      ListTile(
        title: const Text('还未上课'),
        trailing: _ColorDot(s.upcomingColor),
        onTap: () => _onPickColor(
          title: '还未上课',
          key: TimetableSettingsKeys.statusColorUpcoming,
          current: s.upcomingColor,
          defaultHex: TimetableSettingsKeys.defaultStatusColorUpcoming,
        ),
      ),
      ListTile(
        title: const Text('已经下课'),
        trailing: _ColorDot(s.finishedColor),
        onTap: () => _onPickColor(
          title: '已经下课',
          key: TimetableSettingsKeys.statusColorFinished,
          current: s.finishedColor,
          defaultHex: TimetableSettingsKeys.defaultStatusColorFinished,
        ),
      ),
    ];
  }

  /// 「样式」分组：默认课程颜色 / 状态色总开关 / 已结束文字样式。
  List<Widget> _buildStyleTiles(
    TimetableStatusSettings s,
    double desktopScale,
  ) {
    return [
      if (Platform.isWindows)
        ListTile(
          leading: const Icon(Icons.zoom_in_outlined),
          title: const Text('电脑端课表缩放'),
          subtitle: const Text('Ctrl + 滚轮可快速调节'),
          trailing: Text('${(desktopScale * 100).round()}%'),
          onTap: () => _editDesktopScale(desktopScale),
        ),
      ListTile(
        leading: const Icon(Icons.palette_outlined),
        title: const Text('默认课程颜色'),
        subtitle: const Text('新建/导入课程初始颜色'),
        trailing: _ColorDot(s.defaultCourseColor),
        onTap: () => _onPickColor(
          title: '默认课程颜色',
          key: TimetableSettingsKeys.defaultCourseColor,
          current: s.defaultCourseColor,
          defaultHex: TimetableSettingsKeys.defaultCourseColorDefault,
        ),
      ),
      SwitchListTile(
        title: const Text('状态色总开关'),
        subtitle: Text(
          s.statusColorsEnabled ? '当前周·今天的课按状态显示颜色' : '全部恢复课程自选颜色',
        ),
        value: s.statusColorsEnabled,
        onChanged: (bool v) =>
            _setTimetableValue(TimetableSettingsKeys.statusColorsEnabled, '$v'),
      ),
      SwitchListTile(
        title: const Text('已结束文字淡化'),
        subtitle: const Text('课程名与地点变淡灰'),
        value: s.finishedTextFade,
        onChanged: (bool v) =>
            _setTimetableValue(TimetableSettingsKeys.finishedTextFade, '$v'),
      ),
      SwitchListTile(
        title: const Text('已结束文字细化'),
        subtitle: const Text('课程名字重变细'),
        value: s.finishedTextThin,
        onChanged: (bool v) =>
            _setTimetableValue(TimetableSettingsKeys.finishedTextThin, '$v'),
      ),
    ];
  }
}

/// 分组列表标题。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 课程色小块：hex 非空为实心圆；空（无色）为空心圆 + block 图标。
class _ColorDot extends StatelessWidget {
  const _ColorDot(this.hex);

  final String hex;

  static const double _size = 28;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (hex.isEmpty) {
      return Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline),
        ),
        child: Icon(
          Icons.block,
          color: scheme.onSurfaceVariant,
          size: _size * 0.5,
        ),
      );
    }
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: colorFromHex(hex),
        shape: BoxShape.circle,
      ),
    );
  }
}
