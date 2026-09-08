import 'package:flutter/material.dart';

import '../timetable/format.dart';

/// 单格固定宽度：居中偏移按它精确计算，滚动条首帧即可停在居中位。
const double _dateCellExtent = 44;

/// 连续日期条（今日页 P4 顶部日期选择）。
///
/// 以 [today] 为锚向两端各展开 [daysBefore] / [daysAfter] 天（默认 ±8，
/// 17 天窗口），横向可滚动。每项显示「周几小字 + 日号大字」：
/// - 选中日：主题色填充圆 + 白字；
/// - 今天（未选中）：主题色描边圆 + 主题色字，与普通选中样式可区分；
/// - 其余：普通字。
///
/// 纯展示组件：只收 [today] / [selected] / [onDaySelected]，不含任何业务或
/// 数据读取。首次构建把今天滚到居中（用固定 itemExtent + viewport 宽度
/// 算出初始偏移，滚动条首帧即到位，无可见跳变）；选中今天时若不在视野中
/// 会平滑回中。
class DateStrip extends StatefulWidget {
  const DateStrip({
    super.key,
    required this.today,
    required this.selected,
    required this.onDaySelected,
    this.daysBefore = 8,
    this.daysAfter = 8,
    this.height = 56,
    this.centerKey,
  });  /// 今天（仅日期语义，年月日归一的本地 0 点）。
  final DateTime today;

  /// 当前选中日（仅日期语义）。
  final DateTime selected;

  /// 点选某天回调，入参为日期归一后的当天 0 点。
  final ValueChanged<DateTime> onDaySelected;

  /// 外部强制居中触发键：值变化时无条件把今天滚回中间（无动画）。
  ///
  /// 供父级在「回到前台 / 首帧校准」等场景触发；不依赖选中日是否切到今天，
  /// 因为用户可能只拖动日期条（不改选中日）就把今天移出视野。
  final Object? centerKey;

  /// 锚点左侧天数（含今天之前）与右侧天数。窗口总宽 =
  /// `1 + daysBefore + daysAfter`。
  final int daysBefore;

  /// 见 [daysBefore]。
  final int daysAfter;

  /// 整条高度。
  final double height;

  @override
  State<DateStrip> createState() => _DateStripState();
}

class _DateStripState extends State<DateStrip> {
  ScrollController? _controller;

  /// 是否已完成首次「今天居中」校准（只在第一次真实布局后执行一次，防止
  /// 后续 build 反复抢滚动；不依赖 IndexedStack/offstage 时机）。
  bool _initialCentered = false;

  int get _itemCount => 1 + widget.daysBefore + widget.daysAfter;

  /// 今天在整个列表中的下标（窗口固定以今天为锚）。
  int get _todayIndex => widget.daysBefore;

  @override
  void didUpdateWidget(DateStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部强制居中请求（回到前台 / 首帧校准 / 本 tab 被选中）：无条件立刻回中。
    if (widget.centerKey != oldWidget.centerKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToCenter(animate: false);
      });
    }
    // 仅当「选中今天」这一状态切换发生时平滑回中；点其它日期不扰动滚动。
    if (!_sameDay(oldWidget.selected, widget.selected) &&
        _sameDay(widget.selected, _dateOnly(widget.today))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToCenter(animate: true);
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 让第 [_todayIndex] 项居中所需的滚动偏移（按固定 itemExtent 精确计算，
  /// 视口宽度由 [viewportWidth] 给出）。首帧前即可算出，直接作为
  /// [ScrollController.initialScrollOffset]，滚动条第一次布局即停在居中位，
  /// 不需要先画出来再跳。
  double _centerOffset(double viewportWidth) {
    final double itemCenter = _dateCellExtent * (0.5 + _todayIndex);
    return (itemCenter - viewportWidth / 2).clamp(0.0, double.infinity);
  }

  void _scrollToCenter({required bool animate}) {
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return;
    final double max = controller.position.maxScrollExtent;
    final double viewport = controller.position.viewportDimension;
    final double target = _centerOffset(viewport).clamp(0.0, max);
    if (animate) {
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      controller.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateTime today = _dateOnly(widget.today);
    final DateTime base = today.subtract(Duration(days: widget.daysBefore));

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _controller ??= ScrollController(
            initialScrollOffset: _centerOffset(constraints.maxWidth),
          );
          // 首帧（真正布局完成后）把今天校准到中间：不依赖外部通知/offstage
          // 时机，首次真实布局即可见正确位置。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _ensureInitialCenter();
          });
          return ListView.builder(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemExtent: _dateCellExtent,
            itemCount: _itemCount,
            itemBuilder: (BuildContext context, int index) {
              final DateTime day = base.add(Duration(days: index));
              return _DateCell(
                key: ValueKey<String>(
                  'day_${day.year}_${day.month}_${day.day}',
                ),
                day: day,
                isToday: _sameDay(day, today),
                isSelected: _sameDay(day, _dateOnly(widget.selected)),
                onTap: () => widget.onDaySelected(_dateOnly(day)),
              );
            },
          );
        },
      ),
    );
  }

  /// 首次真实布局后的「今天居中」校准（仅一次；布局未就绪则等下次 build 重试）。
  void _ensureInitialCenter() {
    if (_initialCentered || !mounted) return;
    final ScrollController? controller = _controller;
    if (controller == null || !controller.hasClients) return;
    _initialCentered = true;
    _scrollToCenter(animate: false);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}

/// 单日格：周几小字在上、日号圆标在下。
class _DateCell extends StatelessWidget {
  const _DateCell({
    super.key,
    required this.day,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  final DateTime day;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool selected = isSelected;

    final String weekday = weekdayLabel(day.weekday);
    final String number = '${day.day}';

    final Color weekdayColor = selected
        ? cs.primary
        : (isToday ? cs.primary : cs.onSurfaceVariant);
    final TextStyle weekdayStyle = TextStyle(
      fontSize: 10,
      height: 1.1,
      color: weekdayColor,
    );

    // 日号圆标：选中 → 填充主题色；今天(未选中) → 主题色描边；其余 → 文字。
    final Widget numberWidget;
    if (selected) {
      numberWidget = Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.primary,
        ),
        child: Text(
          number,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: cs.onPrimary,
          ),
        ),
      );
    } else if (isToday) {
      numberWidget = Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: cs.primary, width: 1.4),
        ),
        child: Text(
          number,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: cs.primary,
          ),
        ),
      );
    } else {
      numberWidget = Text(
        number,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: cs.onSurface,
        ),
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: _dateCellExtent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(weekday, style: weekdayStyle),
            const SizedBox(height: 3),
            numberWidget,
          ],
        ),
      ),
    );
  }
}
