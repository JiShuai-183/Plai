import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../data/models/task.dart';
import '../timetable/format.dart';
import 'task_rules.dart';

/// 任务列表项：勾选打卡 + 优先级标签 + 日期时刻 + 逾期标红 + 左滑删除。
///
/// 完成划线圈选交互：
/// - 点复选框「未完成 → 完成」时**立即**本地视觉划线，横线从左到右扫过
///   [completeSweepDuration]，**动画播完才**调用 [onToggle] 提交完成状态，
///   由父级刷新后行归入「已完成」；
/// - 「已完成 → 取消」**立即**恢复（不播反向动画）并立即调用 [onToggle]；
/// - 动画进行中重复点击被忽略（防重入），[onToggle] 只触发一次；
/// - 非本 tile 发起的完成状态变化（详情页完成、provider 刷新）直接跳到位，
///   不播动画：本来就已完成的行首次渲染即为划好的横线，滚动/重建不重播。
///
/// 左滑交互（自绘，非 Dismissible，可限位、不整条滑出屏）：
/// - 最多左滑露出 tile 宽 1/3，拖到此即顶住（clamp，无弹性）；
/// - **松手**才触发：左滑位移 ≥ 阈值（宽 1/6，至少 56px）→ fire-and-forget
///   触发 [onConfirmDelete]（其内部弹确认框；确认后删数据并等列表数据源刷新
///   使条目出树；取消则保留），并回弹原位（~180ms）；滑不足仅回弹不触发；
/// - 右滑 / 往回拖到 0 不触发，仅复位；
/// - [onConfirmDelete] 为 null 时不启用滑动（纯 ListTile，无手势/无背景）。
///
/// 今日视图 / 任务列表页 / 日历某天共用。
class TaskListTile extends StatefulWidget {
  const TaskListTile({
    super.key,
    required this.task,
    this.onToggle,
    this.onTap,
    this.onConfirmDelete,
    this.showCheckbox = true,
    this.checkedOverride,
  });

  final Task task;

  /// 勾选 / 取消打卡回调（daily 由父按"某天"调 mark/clear）。
  final VoidCallback? onToggle;

  /// 点击进入详情。
  final VoidCallback? onTap;

  /// 左滑触发删除确认回调（松手到位后 fire-and-forget 调用，不 await）。
  /// 实现方负责：弹确认框 → 确认后执行删除并 `await` 列表数据源刷新使条目随
  /// 重建从列表移除；取消则条目保留。条目不回滑出屏外，靠数据刷新移除。
  final Future<bool> Function()? onConfirmDelete;

  /// 是否显示勾选框。daily 在没有"某天"语义的列表页不显示勾选（父传 false），
  /// 今日/按日视图仍需勾选打卡 → 默认 true。
  final bool showCheckbox;

  /// 勾选显示值覆盖：daily 顶层 completed 恒 false，完成语义按天，由父传
  /// 「该日已打卡」作覆盖值；划线/文字淡化一并跟随该值。null 时用
  /// [Task.completed]。
  final bool? checkedOverride;

  /// 完成横线从左划到右的时长（划满后才提交完成状态）。
  static const Duration completeSweepDuration = Duration(milliseconds: 250);

  /// 上层「带删除线」标题文本的定位 Key：横线未起（`_sweep == 0`）时该层
  /// 不存在，可用于断言「无横线 / 横线已出现」。
  static const Key titleSweepKey = Key('task_list_tile_title_sweep');

  @override
  State<TaskListTile> createState() => _TaskListTileState();
}

class _TaskListTileState extends State<TaskListTile>
    with TickerProviderStateMixin {
  /// 左滑最大露出位移比例：tile 宽 1/3（到顶即止，不继续左滑）。
  static const double _slideRatio = 1 / 3;

  /// 触发删除确认的最小位移阈值（绝对值下限），小屏也能滑到位。
  static const double _triggerMin = 56.0;

  /// 回弹时长。
  static const Duration _settleDuration = Duration(milliseconds: 180);

  /// 本次 build 测得的可滑上限（tile 宽 1/3）。
  double _dragLimit = 0;

  /// 当前左滑位移（px，≥0；0=原位）。放 Notifier 里跟手更新，避免整树重建。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// 松手回弹控制器。
  late final AnimationController _settle;
  late final CurvedAnimation _settleCurve;

  /// 本次回弹起始位移。
  double _settleFrom = 0;

  /// 完成横线的本地视觉进度：0=无横线，1=横线划满。渲染一律以此为准，
  /// 不直接读 `widget.checkedOverride ?? task.completed`（后者是「已提交」的
  /// 状态，落后于本地视觉）。
  late bool _visualCompleted;

  /// 本 tile 发起的「完成」动画是否进行中：进行中忽略重复点击，且外部重建
  /// 不得把视觉回退；动画播完后清除并提交。
  bool _pendingComplete = false;

  /// 完成横线扫描控制器（0→1 从左划到右）。
  late final AnimationController _sweep;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: _settleDuration);
    _settleCurve = CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic);
    _settle.addListener(
      () => _offset.value = _settleFrom * (1 - _settleCurve.value),
    );
    _visualCompleted = widget.checkedOverride ?? widget.task.completed;
    _sweep = AnimationController(
      vsync: this,
      duration: TaskListTile.completeSweepDuration,
    );
    // 本来就已完成的行：首帧即横线划满，不播动画。
    _sweep.value = _visualCompleted ? 1.0 : 0.0;
    _sweep.addStatusListener(_onSweepStatus);
  }

  @override
  void didUpdateWidget(covariant TaskListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 本 tile 发起的完成动画进行中：此时外部仍是「未提交」的旧值，重建不得
    // 把视觉回退（否则横线会被撤掉）。
    if (_pendingComplete) return;
    final bool completed = widget.checkedOverride ?? widget.task.completed;
    // 非本 tile 发起的状态变化（详情页完成 / provider 刷新）直接跳到位、不播
    // 动画；外部提交失败（回落到 false）时横线随之消失。
    _visualCompleted = completed;
    final double target = completed ? 1.0 : 0.0;
    if (_sweep.value != target) _sweep.value = target;
  }

  @override
  void dispose() {
    _sweep.dispose();
    _settle.dispose();
    _offset.dispose();
    super.dispose();
  }

  /// 横线划满：清除防重入标志并**此时**才提交完成状态。
  void _onSweepStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _pendingComplete) {
      _pendingComplete = false;
      widget.onToggle?.call();
    }
  }

  /// 复选框点击：未完成→完成走「先划线、播完再提交」；已完成→取消立即恢复
  /// 并立即提交；动画进行中忽略（防重入）。
  void _onToggle() {
    final VoidCallback? toggle = widget.onToggle;
    if (toggle == null || _pendingComplete) return;
    if (_visualCompleted) {
      // 取消完成：立即恢复、不播反向动画，立即提交。
      setState(() {
        _visualCompleted = false;
        _sweep.value = 0.0;
      });
      toggle();
    } else {
      // 完成：立即划线，动画播完（[_onSweepStatus]）才提交。
      setState(() => _visualCompleted = true);
      _pendingComplete = true;
      _sweep.forward(from: 0);
    }
  }

  /// 松手触发阈值 = tile 宽 1/6（限位的 1/2），且不小于 [_triggerMin]；
  /// 不大于限位（超窄 tile 时全滑即可触发）。
  double _triggerThreshold() {
    final double byRatio = _dragLimit / 2; // 限位=_dragLimit=宽1/3 → 此=宽1/6
    return math.min(math.max(byRatio, _triggerMin), _dragLimit);
  }

  void _onDragStart(DragStartDetails details) {
    _settle.stop(); // 拖动打断回弹，从当前位移继续跟手。
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double next = _offset.value - details.delta.dx; // 左滑(dx<0)→增大
    _offset.value = next.clamp(0.0, _dragLimit);
  }

  void _onDragEnd(DragEndDetails details) {
    final double off = _offset.value;
    if (off >= _triggerThreshold()) {
      // 左滑到位才触发：fire-and-forget，确认框由其内部弹出。
      final Future<bool> Function()? confirm = widget.onConfirmDelete;
      if (confirm != null) unawaited(confirm());
    }
    if (_offset.value > 0) {
      _settleFrom = _offset.value;
      _settle.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Task task = widget.task;
    // 勾选/划线一律跟随本地视觉状态（[_visualCompleted]），它由外部值初始化、
    // 随交互即时更新，避免点击到提交刷新之间出现「已勾选却无横线」的跳变。
    final bool completed = _visualCompleted;
    final bool showCheckbox = widget.showCheckbox;
    final bool overdue = !completed && isTaskOverdue(task);
    final Color textColor =
        completed ? theme.colorScheme.outline : theme.colorScheme.onSurface;

    final Widget tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: showCheckbox
          ? Checkbox(
              value: completed,
              onChanged: widget.onToggle == null ? null : (_) => _onToggle(),
            )
          : null,
      title: _buildTitle(
        task,
        TextStyle(color: overdue ? theme.colorScheme.error : textColor),
      ),
      subtitle: _buildSubtitle(theme, overdue),
      onTap: widget.onTap,
    );

    if (widget.onConfirmDelete == null) return tile;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _dragLimit = math.max(0.0, constraints.maxWidth * _slideRatio);
        final double limit = _dragLimit;
        return ValueListenableBuilder<double>(
          valueListenable: _offset,
          builder: (BuildContext context, double value, Widget? child) {
            final double offset = value.clamp(0.0, limit);
            return Stack(
              children: <Widget>[
                // 删除背景：只占 content 移开后露出的右侧条带（width=offset），
                // 不会透过仍被 content 覆盖的区域露出。
                if (offset > 0)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: offset,
                    child: Container(
                      color: theme.colorScheme.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: Icon(
                        Icons.delete_outline,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(-offset, 0),
                  child: RawGestureDetector(
                    behavior: HitTestBehavior.opaque,
                    gestures: <Type, GestureRecognizerFactory>{
                      // 近水平判定识别器：斜向（纵向分量明显）滑动主动放弃，
                      // 让 ListView 的纵向滚动接管，避免误触发左滑删除。
                      _TileHorizontalDragRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              _TileHorizontalDragRecognizer>(
                        () => _TileHorizontalDragRecognizer(debugOwner: this),
                        (recognizer) {
                          recognizer.onStart = _onDragStart;
                          recognizer.onUpdate = _onDragUpdate;
                          recognizer.onEnd = _onDragEnd;
                        },
                      ),
                    },
                    child: tile,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 标题 + 完成横线。
  ///
  /// `TextDecoration.lineThrough` 是整行线、无法半透出，故叠两层同一段文字：
  /// 下层普通样式，上层带删除线、用 [ClipRect] + [Align] 的 `widthFactor` 按
  /// [_sweep] 从左往右裁出，形成「横线跟着字形从左划到右」。两层用完全相同的
  /// [TextStyle] 基准（仅上层加 decoration）/ `maxLines` / `overflow`，换行位置
  /// 才能一致不错位。横线未起时只渲染单层（无裁剪开销，也让测试可用
  /// [TaskListTile.titleSweepKey] 判定「有无横线」）。
  Widget _buildTitle(Task task, TextStyle baseStyle) {
    return AnimatedBuilder(
      animation: _sweep,
      builder: (BuildContext context, Widget? child) {
        final double sweep = _sweep.value;
        if (sweep <= 0) {
          return Text(
            task.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: baseStyle,
          );
        }
        return Stack(
          children: <Widget>[
            Text(
              task.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: baseStyle,
            ),
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: sweep,
                child: Text(
                  task.title,
                  key: TaskListTile.titleSweepKey,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: baseStyle.copyWith(
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSubtitle(ThemeData theme, bool overdue) {
    final Task task = widget.task;
    final List<Widget> items = <Widget>[];

    // 类型。
    items.add(Text(task.type.label, style: theme.textTheme.bodySmall));
    items.add(const SizedBox(width: 8));

    // 优先级标签。
    items.add(_buildTag(
      theme,
      text: task.priority.label,
      foreground: _priorityForeground(theme, task.priority),
      background: _priorityBackground(theme, task.priority),
    ));

    // 日期 / 区间：todo/scheduled 显示截止日期（带时刻）；daily/span 显示
    // 「起始~截止」区间（同一天则只显示一天）。
    items.add(Text(_dateRangeText(), style: theme.textTheme.bodySmall));

    // 逾期标红。
    if (overdue) {
      items.add(Text(
        '已逾期',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
      ));
    }

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  /// 日期展示文本（风格沿用 `formatMonthDay`）。
  ///
  /// - todo / scheduled：`dueDate`（有 dueTime 追加时刻）；
  /// - daily / span：`startDate ~ dueDate` 区间（同一天折叠成单日）。
  String _dateRangeText() {
    final Task task = widget.task;
    final String time = task.dueTime ?? '';
    final String due = formatMonthDay(task.dueDate);
    if (task.type != TaskType.daily && task.type != TaskType.span) {
      return time.isEmpty ? due : '$due $time';
    }
    final DateTime end = task.dueDate;
    final DateTime start = task.startDate ?? end;
    final String begin = formatMonthDay(start);
    final bool sameDay = !start.isBefore(end) && !start.isAfter(end);
    return sameDay ? begin : '$begin~$due';
  }

  Widget _buildTag(
    ThemeData theme, {
    required String text,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }

  Color _priorityForeground(ThemeData theme, Priority priority) {
    switch (priority) {
      case Priority.urgent:
        return theme.colorScheme.error;
      case Priority.important:
        return theme.colorScheme.onTertiaryContainer;
      case Priority.normal:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  Color _priorityBackground(ThemeData theme, Priority priority) {
    switch (priority) {
      case Priority.urgent:
        return theme.colorScheme.errorContainer;
      case Priority.important:
        return theme.colorScheme.tertiaryContainer;
      case Priority.normal:
        return theme.colorScheme.surfaceContainerHighest;
    }
  }
}

/// 左滑删除专用水平拖拽识别器：与列表纵向滚动在 gesture arena 竞争时，仅
/// 「近水平」才认领，纵向分量明显的斜向滑动主动放弃、交还 ListView 滚动。
///
/// 系统自带的 HorizontalDragGestureRecognizer 只看横向累计距离（斜向拖动
/// 只要 |dx| 过 slop 就可能抢赢 arena）→ 误触发左滑。本识别器在 arena 竞争
/// 阶段判定：累计 |dx| ≥ |dy| × [_kHorizontalDominance]（≈30° 内近水平）且
/// |dx| 超 slop 才 resolve accepted；|dy| 已超 slop 则直接 resolve rejected
/// 让纵向滚动赢。也因此在竞争阶段就完成方向筛选，不吞列表滚动。
class _TileHorizontalDragRecognizer extends OneSequenceGestureRecognizer {
  _TileHorizontalDragRecognizer({super.debugOwner});

  /// 近水平主导比：要求 |dx| ≥ |dy| × 1.7（即与水平夹角 ≤ ~30°）。
  /// ~45° 及更垂直（|dx| < |dy| × 1.7）→ 纵向主导 → 拒让列表滚动。
  static const double _kHorizontalDominance = 1.7;

  GestureDragStartCallback? onStart;
  GestureDragUpdateCallback? onUpdate;
  GestureDragEndCallback? onEnd;

  int? _pointer;
  Offset _downGlobal = Offset.zero;
  Offset _downLocal = Offset.zero;
  Offset _lastGlobal = Offset.zero;
  Offset _lastLocal = Offset.zero;
  bool _accepted = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return; // 左滑单指即可；忽略多余触点。
    _pointer = event.pointer;
    _downGlobal = _lastGlobal = event.position;
    _downLocal = _lastLocal = event.localPosition;
    _accepted = false;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_pointer != event.pointer) return;
    if (event is PointerMoveEvent) {
      final Offset position = event.position;
      final Offset total = position - _downGlobal;
      final Offset move = position - _lastGlobal;
      _lastGlobal = position;
      _lastLocal = event.localPosition;
      if (!_accepted) {
        final double slop = computeHitSlop(event.kind, gestureSettings);
        final bool horizontalDominant =
            total.dx.abs() >= total.dy.abs() * _kHorizontalDominance;
        if (horizontalDominant && total.dx.abs() > slop) {
          // 近水平且超 slop：认领（acceptGesture 内补 onStart + 初始累计 update）。
          resolve(GestureDisposition.accepted);
        } else if (total.dy.abs() > slop) {
          // 纵向分量明显（斜向/垂直）：主动放弃，交列表纵向滚动。
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
        }
      } else if (move.dx != 0) {
        onUpdate?.call(DragUpdateDetails(
          delta: Offset(move.dx, 0),
          primaryDelta: move.dx,
          globalPosition: position,
          localPosition: event.localPosition,
        ));
      }
    } else if (event is PointerUpEvent) {
      if (_accepted) {
        onEnd?.call(DragEndDetails(
          globalPosition: event.position,
          localPosition: event.localPosition,
        ));
      }
      stopTrackingPointer(event.pointer);
      _reset(event.pointer);
    } else if (event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
      _reset(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_accepted || pointer != _pointer) return;
    _accepted = true;
    onStart?.call(DragStartDetails(
      globalPosition: _downGlobal,
      localPosition: _downLocal,
    ));
    final Offset total = _lastGlobal - _downGlobal;
    if (total.dx != 0) {
      onUpdate?.call(DragUpdateDetails(
        delta: Offset(total.dx, 0),
        primaryDelta: total.dx,
        globalPosition: _lastGlobal,
        localPosition: _lastLocal,
      ));
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _pointer) {
      stopTrackingPointer(pointer);
      _reset(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _reset(pointer);
  }

  void _reset(int pointer) {
    if (pointer == _pointer) {
      _pointer = null;
      _accepted = false;
    }
  }

  @override
  String get debugDescription => 'horizontal dominant drag';

  @override
  void dispose() {
    _pointer = null;
    super.dispose();
  }
}
