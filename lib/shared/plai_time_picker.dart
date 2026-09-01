import 'dart:math' as math;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// 拨盘核心常量
// ---------------------------------------------------------------------------

/// 内外圈间隔。
///
/// Flutter 内置 showTimePicker 的 24h 双环间隔是硬编码常量
/// _kTimePickerInnerDialOffset = 28，选中高亮圆（半径约 22）会盖到另一圈数字。
/// 这里加大到 44，保证高亮圆不越圈。
const double kDialRingGap = 44.0;

/// 拨盘内边距（数字环到画布边缘的距离）。
const double kDialPadding = 28.0;

/// 拨盘最小边长（尺寸自适应时的下限）。
///
/// 保证 24h 内圈半径恒为正：
/// `side/2 - kDialPadding - kDialRingGap = 80 - 28 - 44 = 8 ≥ 0`，
/// 避免极矮视口下内圈数字翻转到圆心另一侧。
const double kDialMinSide = 160.0;

/// 选中高亮圆半径。
/// 必须小于 [kDialRingGap]（44），否则会盖到另一圈数字。
const double kDialSelectorRadius = 22.0;

/// 轻微吸附系数：吸附区 = 步距 × 该系数。
///
/// 手指进入吸附区后，指示器向最近数字渐进拉拢（拉拢强度随距离衰减），
/// 不是硬跳，保证拖动跟手又有「靠近即吸」的手感。
const double kDialSnapZoneFactor = 0.38;

/// 拨盘模式：小时盘 / 分钟盘。
enum PlaiDialMode { hour, minute }

/// 弹出自定义时间选择拨盘，替代 Flutter 内置 [showTimePicker]。
///
/// 跟随系统时间制式：`MediaQuery.alwaysUse24HourFormatOf(context)` 为 true
/// 时小时盘为 24h 双环；false 时为 12h 单环 + AM/PM。
/// 返回用户选中的时间；点「取消」或点外部遮罩返回 null。
Future<TimeOfDay?> showPlaiTimePicker(
  BuildContext context, {
  TimeOfDay? initialTime,
  String? helpText,
}) {
  return showDialog<TimeOfDay>(
    context: context,
    builder: (BuildContext context) => _PlaiTimePickerDialog(
      initialTime: initialTime ?? TimeOfDay.now(),
      helpText: helpText,
    ),
  );
}

/// 拨盘自绘 Painter。
///
/// 取色一律取自 `Theme.of(context).colorScheme`：
/// 盘底 surfaceContainerHighest / 指针与选中高亮 primary、选中数字 onPrimary /
/// 未选中数字 onSurfaceVariant / 分钟细刻度 outlineVariant、整五刻度 onSurfaceVariant。
///
/// 几何约定：正方形画布，圆心为画布中心；角度起点为顶部
/// （12 点方向，θ = π/2），顺时针递减 2π/count；坐标
/// Offset(r·cosθ, -r·sinθ)（y 轴翻转使递减 = 顺时针）。
class PlaiTimeDialPainter extends CustomPainter {
  PlaiTimeDialPainter({
    required this.mode,
    required this.use24h,
    required this.hour,
    required this.minute,
    required this.colorScheme,
    required this.textScaler,
    this.indicatorTheta,
    this.indicatorRadius,
  });

  /// 当前盘面模式。
  final PlaiDialMode mode;

  /// 是否 24 小时制（true 时小时盘为双环 0-23，false 为单环 1-12）。
  final bool use24h;

  /// 当前选中小时（0-23）。
  final int hour;

  /// 当前选中分钟（0-59）。
  final int minute;

  final ColorScheme colorScheme;

  /// 文本缩放（上层已 clamp 到 maxScaleFactor: 2.0）。
  final TextScaler textScaler;

  /// 指示器手尖/高亮圆位置覆盖（拖动中 / settle 动画中由上层驱动）。
  /// null 时回退到按 [hour]/[minute] 计算的默认位置。
  final double? indicatorTheta;
  final double? indicatorRadius;

  // ------------------------------------------------------------ 纯函数

  /// 角度 → 值：将 [theta] 吸附到最近格点，返回 0..count-1，含环绕。
  /// 例：0 分往左（逆时针）一格 → 59；59 分往右（顺时针）一格 → 0。
  static int valueForAngle(double theta, int count) {
    // 归一化「从顶部顺时针偏移角」到 [0, 2π)
    final double t =
        ((math.pi / 2 - theta) % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    final double step = 2 * math.pi / count;
    // + step/2 后向下取整 = 吸附最近格点
    return ((t + step / 2) ~/ step) % count;
  }

  /// 24h 小时盘内外环判断：落点距圆心 [distance] 离外环半径近 → 外环（0-11），
  /// 离内环半径近 → 内环（12-23）。等距时视为外环。
  static bool isOuterRing(
    double distance,
    double innerLabelRadius,
    double labelRadius,
  ) {
    return (distance - labelRadius).abs() <= (distance - innerLabelRadius).abs();
  }

  /// 12h 显示小时（1-12）→ 24h 内部小时（0-23）。
  static int twelveHourToInternal(int display12, {required bool isPm}) {
    if (isPm) return display12 == 12 ? 12 : display12 + 12;
    return display12 == 12 ? 0 : display12;
  }

  /// 24h 内部小时（0-23）→ 12h 显示小时（1-12）。
  static int internalToTwelveHour(int hour24) {
    final int h = hour24 % 12;
    return h == 0 ? 12 : h;
  }

  /// 是否 PM（12:00 及以后）。
  static bool isPm(int hour24) => hour24 >= 12;

  // ------------------------------------------------------------ 绘制

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double labelRadius = size.shortestSide / 2 - kDialPadding;
    final double innerLabelRadius = labelRadius - kDialRingGap;
    final double backgroundRadius = labelRadius + kDialSelectorRadius;

    // 盘底
    final Paint background = Paint()
      ..color = colorScheme.surfaceContainerHighest;
    canvas.drawCircle(center, backgroundRadius, background);

    // 数字 / 刻度：全部普通绘制（onSurfaceVariant），不画选中态
    if (mode == PlaiDialMode.hour) {
      if (use24h) {
        _paint24hHourNumbers(canvas, center, labelRadius, innerLabelRadius);
      } else {
        _paint12hHourNumbers(canvas, center, labelRadius);
      }
    } else {
      _paintMinuteNumbers(canvas, center, labelRadius);
    }

    // 指示器（最后统一绘制，覆盖在数字之上）：
    // 指针（中心线 + 圆点）+ primary 高亮圆 + 圆内数字（onPrimary）。
    final (double theta, double radius) =
        _indicatorPosition(labelRadius, innerLabelRadius);
    final Offset tip = center +
        Offset(radius * math.cos(theta), -radius * math.sin(theta));
    _paintHand(canvas, center, tip);
    final Paint fill = Paint()..color = colorScheme.primary;
    canvas.drawCircle(tip, kDialSelectorRadius, fill);
    final double indicatorFont = mode == PlaiDialMode.hour ? 16 : 14;
    _paintLabel(canvas, tip, _indicatorValueLabel(), colorScheme.onPrimary,
        indicatorFont);
  }

  /// 24h 小时盘数字：外环 0-11，内环 12-23，内外环对应数字同角度仅半径差 [kDialRingGap]。
  void _paint24hHourNumbers(
    Canvas canvas,
    Offset center,
    double labelRadius,
    double innerLabelRadius,
  ) {
    for (int i = 0; i < 12; i++) {
      final double a = math.pi / 2 - i * (2 * math.pi / 12);
      final Offset outerPos = center +
          Offset(labelRadius * math.cos(a), -labelRadius * math.sin(a));
      _paintLabel(canvas, outerPos, '$i', colorScheme.onSurfaceVariant, 16);
      final Offset innerPos = center +
          Offset(
              innerLabelRadius * math.cos(a), -innerLabelRadius * math.sin(a));
      _paintLabel(canvas, innerPos, '${i + 12}', colorScheme.onSurfaceVariant,
          16);
    }
  }

  /// 12h 小时盘数字：单环 1-12，顶部为 12。
  void _paint12hHourNumbers(Canvas canvas, Offset center, double labelRadius) {
    for (int i = 1; i <= 12; i++) {
      final double a = math.pi / 2 - (i % 12) * (2 * math.pi / 12);
      final Offset pos = center +
          Offset(labelRadius * math.cos(a), -labelRadius * math.sin(a));
      _paintLabel(canvas, pos, '$i', colorScheme.onSurfaceVariant, 16);
    }
  }

  /// 分钟盘刻度与数字：60 个刻度（每 6° 一格，顶部 = 0 分，顺时针），
  /// 逐分钟细刻度 + 整五粗刻度与数字。
  void _paintMinuteNumbers(Canvas canvas, Offset center, double labelRadius) {
    final Paint tickPaint = Paint()
      ..color = colorScheme.outlineVariant
      ..strokeWidth = 1;
    final Paint tick5Paint = Paint()
      ..color = colorScheme.onSurfaceVariant
      ..strokeWidth = 2;

    for (int i = 0; i < 60; i++) {
      final double a = math.pi / 2 - i * (2 * math.pi / 60);
      final Offset dir = Offset(math.cos(a), -math.sin(a));
      if (i % 5 == 0) {
        // 整五：粗长刻度 + 数字（数字圆心在 labelRadius）
        canvas.drawLine(center + dir * (labelRadius - 18),
            center + dir * (labelRadius - 7), tick5Paint);
        _paintLabel(
            canvas, center + dir * labelRadius, '$i',
            colorScheme.onSurfaceVariant, 14);
      } else {
        // 逐分钟细刻度（labelRadius-14 ~ labelRadius-7）
        canvas.drawLine(center + dir * (labelRadius - 14),
            center + dir * (labelRadius - 7), tickPaint);
      }
    }
  }

  /// 指示器位置：优先用上层覆盖的 [indicatorTheta]/[indicatorRadius]；
  /// 为 null 时按 committed 值回退（24h 外环 labelRadius / 内环 innerLabelRadius，
  /// 12h 与分钟均为 labelRadius）。
  (double, double) _indicatorPosition(
    double labelRadius,
    double innerLabelRadius,
  ) {
    final double? th = indicatorTheta;
    final double? rd = indicatorRadius;
    if (th != null && rd != null) {
      return (th, rd);
    }
    if (mode == PlaiDialMode.hour) {
      if (use24h) {
        final bool outer = hour < 12;
        final int index = outer ? hour : hour - 12;
        final double theta = math.pi / 2 - index * (2 * math.pi / 12);
        return (theta, outer ? labelRadius : innerLabelRadius);
      }
      final int index = internalToTwelveHour(hour) % 12;
      return (math.pi / 2 - index * (2 * math.pi / 12), labelRadius);
    }
    return (math.pi / 2 - minute * (2 * math.pi / 60), labelRadius);
  }

  /// 指示器圆内显示的值文本（跟随 committed 值）。
  String _indicatorValueLabel() {
    if (mode == PlaiDialMode.hour) {
      if (use24h) return '$hour';
      return '${internalToTwelveHour(hour)}';
    }
    return '$minute';
  }

  /// 指针（中心到手尖）+ 圆心中点小圆点。
  void _paintHand(Canvas canvas, Offset center, Offset tip) {
    final Paint hand = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, hand);
    canvas.drawCircle(center, 4, hand);
  }

  /// 即时布局即时绘制的文本（不缓存，无需保留 TextPainter）。
  void _paintLabel(
    Canvas canvas,
    Offset pos,
    String text,
    Color color,
    double fontSize,
  ) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: textScaler.scale(fontSize)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(PlaiTimeDialPainter oldDelegate) {
    return oldDelegate.mode != mode ||
        oldDelegate.use24h != use24h ||
        oldDelegate.hour != hour ||
        oldDelegate.minute != minute ||
        oldDelegate.indicatorTheta != indicatorTheta ||
        oldDelegate.indicatorRadius != indicatorRadius ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.textScaler != textScaler;
  }
}

// ---------------------------------------------------------------------------
// 对话框
// ---------------------------------------------------------------------------

/// 自定义时间选择对话框主体。
class _PlaiTimePickerDialog extends StatefulWidget {
  const _PlaiTimePickerDialog({required this.initialTime, this.helpText});

  final TimeOfDay initialTime;

  /// 对话框标题（如「选择时间」或「第 N 节开始时间」）。
  final String? helpText;

  @override
  State<_PlaiTimePickerDialog> createState() => _PlaiTimePickerDialogState();
}

class _PlaiTimePickerDialogState extends State<_PlaiTimePickerDialog> {
  late TimeOfDay _time;
  PlaiDialMode _mode = PlaiDialMode.hour;

  @override
  void initState() {
    super.initState();
    _time = widget.initialTime;
  }

  void _onHourChanged(int hour) {
    setState(() => _time = TimeOfDay(hour: hour, minute: _time.minute));
  }

  void _onMinuteChanged(int minute) {
    setState(() => _time = TimeOfDay(hour: _time.hour, minute: minute));
  }

  void _onPeriodChanged(bool pm) {
    setState(() {
      _time = TimeOfDay(
        hour: PlaiTimeDialPainter.twelveHourToInternal(
          PlaiTimeDialPainter.internalToTwelveHour(_time.hour),
          isPm: pm,
        ),
        minute: _time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final TextScaler scaler =
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 2.0);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(28)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
              child: Text(
                widget.helpText ?? '选择时间',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            _PlaiTimeHeader(
              time: _time,
              mode: _mode,
              use24h: use24h,
              colorScheme: cs,
              textScaler: scaler,
              onModeChanged: (PlaiDialMode m) => setState(() => _mode = m),
              onPeriodChanged: _onPeriodChanged,
            ),
            // 拨盘区：Flexible 占满剩余高度，边长按实际可用空间自适应，避免溢出。
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // 边长：可用宽/高最短边内取 ≤ 320，下限 kDialMinSide
                    // （保证 24h 内圈半径恒正，见常量注释）。
                    final double dialSide = math.min(
                      320.0,
                      math.max(
                        kDialMinSide,
                        math.min(constraints.maxWidth, constraints.maxHeight),
                      ),
                    );
                    // FittedBox(contain) 只缩不放大：可用空间 < kDialMinSide 时
                    // 按比例缩小渲染，painter 仍按 dialSide 坐标系绘制（内圈半径恒正），
                    // 手势 localPosition 落在未缩放的坐标系里，几何不变。
                    return Center(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(
                          width: dialSide,
                          height: dialSide,
                          child: _PlaiDial(
                            mode: _mode,
                            use24h: use24h,
                            hour: _time.hour,
                            minute: _time.minute,
                            colorScheme: cs,
                            textScaler: scaler,
                            onHourChanged: _onHourChanged,
                            onMinuteChanged: _onMinuteChanged,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_time),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部时间头：显示当前选中时间，小时段/分钟段可点切换盘面模式，
/// 当前模式以 primary 高亮；12h 制时附带 AM/PM 切换。
class _PlaiTimeHeader extends StatelessWidget {
  const _PlaiTimeHeader({
    required this.time,
    required this.mode,
    required this.use24h,
    required this.colorScheme,
    required this.textScaler,
    required this.onModeChanged,
    required this.onPeriodChanged,
  });

  final TimeOfDay time;
  final PlaiDialMode mode;
  final bool use24h;
  final ColorScheme colorScheme;
  final TextScaler textScaler;
  final ValueChanged<PlaiDialMode> onModeChanged;
  final ValueChanged<bool> onPeriodChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = colorScheme;
    final bool isPm = PlaiTimeDialPainter.isPm(time.hour);
    final int display12 = PlaiTimeDialPainter.internalToTwelveHour(time.hour);
    final String hourText =
        use24h ? time.hour.toString().padLeft(2, '0') : '$display12';
    final String minuteText = time.minute.toString().padLeft(2, '0');
    final double timeFontSize = textScaler.scale(32);

    return Container(
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              _TimeSegment(
                key: const Key('plai_time_hour'),
                text: hourText,
                active: mode == PlaiDialMode.hour,
                colorScheme: cs,
                fontSize: timeFontSize,
                onTap: () => onModeChanged(PlaiDialMode.hour),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  ':',
                  style: TextStyle(
                    fontSize: timeFontSize,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
              _TimeSegment(
                key: const Key('plai_time_minute'),
                text: minuteText,
                active: mode == PlaiDialMode.minute,
                colorScheme: cs,
                fontSize: timeFontSize,
                onTap: () => onModeChanged(PlaiDialMode.minute),
              ),
            ],
          ),
          if (!use24h) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PeriodSegment(
                  key: const Key('plai_period_am'),
                  label: 'AM',
                  active: !isPm,
                  colorScheme: cs,
                  textScaler: textScaler,
                  onTap: () => onPeriodChanged(false),
                ),
                const SizedBox(width: 8),
                _PeriodSegment(
                  key: const Key('plai_period_pm'),
                  label: 'PM',
                  active: isPm,
                  colorScheme: cs,
                  textScaler: textScaler,
                  onTap: () => onPeriodChanged(true),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 时间段（小时/分钟）可点击块；激活段以 primary 填充高亮。
class _TimeSegment extends StatelessWidget {
  const _TimeSegment({
    super.key,
    required this.text,
    required this.active,
    required this.colorScheme,
    required this.fontSize,
    required this.onTap,
  });

  final String text;
  final bool active;
  final ColorScheme colorScheme;
  final double fontSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: active
            ? BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: active ? cs.onPrimary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// AM/PM 切换小块；激活段以 primary 填充高亮。
class _PeriodSegment extends StatelessWidget {
  const _PeriodSegment({
    super.key,
    required this.label,
    required this.active,
    required this.colorScheme,
    required this.textScaler,
    required this.onTap,
  });

  final String label;
  final bool active;
  final ColorScheme colorScheme;
  final TextScaler textScaler;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: active ? cs.primary : null,
          border: Border.all(color: active ? cs.primary : cs.outline),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: textScaler.scale(13),
            fontWeight: FontWeight.w500,
            color: active ? cs.onPrimary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 拨盘交互区：拖动/点击沿盘面按角度吸附最近小时/分钟；
/// 24h 小时模式按落点半径判断内外环。
///
/// 拖动中指示器直接跟随手指（轻微吸附为渐进拉拢），
/// 抬起/点按时以 140ms settle 动画平滑滑到精确数值位置。
class _PlaiDial extends StatefulWidget {
  const _PlaiDial({
    required this.mode,
    required this.use24h,
    required this.hour,
    required this.minute,
    required this.colorScheme,
    required this.textScaler,
    required this.onHourChanged,
    required this.onMinuteChanged,
  });

  final PlaiDialMode mode;
  final bool use24h;
  final int hour;
  final int minute;
  final ColorScheme colorScheme;
  final TextScaler textScaler;
  final ValueChanged<int> onHourChanged;
  final ValueChanged<int> onMinuteChanged;

  @override
  State<_PlaiDial> createState() => _PlaiDialState();
}

class _PlaiDialState extends State<_PlaiDial>
    with SingleTickerProviderStateMixin {
  /// 抬起/点按后滑到精确数值位置的动画时长。
  static const Duration _kSettleDuration = Duration(milliseconds: 140);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _kSettleDuration,
  );
  double _fromTheta = 0;
  double _toTheta = 0;
  double _fromFrac = 1;
  double _toFrac = 1;
  bool _dragging = false;
  double? _lastDragTheta;
  double? _lastDragFrac;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _anim.stop();
    _anim.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 几何

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// 把 [to] 归到 [from-π, from+π]（沿最短角度差方向），处理 359°→0° 环绕。
  double _shortestAngle(double from, double to) {
    double delta = (to - from) % (2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    return from + delta;
  }

  /// committed 值（小时/分钟）对应的指示器位置：theta + 半径比例（labelRadius=1.0）。
  /// 24h 内环比例 = (labelRadius - kDialRingGap) / labelRadius。
  (double, double) _valuePosition({
    int? hour,
    int? minute,
    required double labelRadius,
  }) {
    final int h = hour ?? widget.hour;
    final int m = minute ?? widget.minute;
    if (widget.mode == PlaiDialMode.hour) {
      if (widget.use24h) {
        final bool outer = h < 12;
        final int index = outer ? h : h - 12;
        final double theta = math.pi / 2 - index * (2 * math.pi / 12);
        final double frac =
            outer ? 1.0 : (labelRadius - kDialRingGap) / labelRadius;
        return (theta, frac);
      }
      final int index = PlaiTimeDialPainter.internalToTwelveHour(h) % 12;
      return (math.pi / 2 - index * (2 * math.pi / 12), 1.0);
    }
    return (math.pi / 2 - m * (2 * math.pi / 60), 1.0);
  }

  /// 当前显示位置：动画中 → easeOutCubic 插值；拖拽中 → 拖拽位置；否则 → committed 值。
  (double, double) _currentDisplay(double lr) {
    if (_anim.isAnimating) {
      final double t = Curves.easeOutCubic.transform(_anim.value);
      return (_lerp(_fromTheta, _toTheta, t), _lerp(_fromFrac, _toFrac, t));
    }
    if (_dragging && _lastDragTheta != null) {
      return (_lastDragTheta!, _lastDragFrac ?? 1.0);
    }
    return _valuePosition(labelRadius: lr);
  }

  /// 起 settle 动画：from → to（to 归到最短角度差方向）。
  void _startAnim(double fromTh, double fromFr, double toTh, double toFr) {
    _fromTheta = fromTh;
    _fromFrac = fromFr;
    _toTheta = _shortestAngle(fromTh, toTh);
    _toFrac = toFr;
    _anim.forward(from: 0);
  }

  /// 轻微吸附拉拢：手指角度离最近数字格点小于吸附区
  /// （zone = 步距 × [kDialSnapZoneFactor]）时按距离衰减拉拢；
  /// 24h 下半径也向最近环拉拢（zone = [kDialRingGap] × 0.4）。
  (double, double) _snapPulled(
    double rawTheta,
    double dist,
    double lr,
    double ilr,
  ) {
    final int count = widget.mode == PlaiDialMode.hour ? 12 : 60;
    final double step = 2 * math.pi / count;
    final int index = PlaiTimeDialPainter.valueForAngle(rawTheta, count);
    final double snapTheta = math.pi / 2 - index * step;
    final double target = _shortestAngle(rawTheta, snapTheta);
    final double delta = target - rawTheta;
    final double zone = step * kDialSnapZoneFactor;
    final double k = (1 - delta.abs() / zone).clamp(0.0, 1.0);
    final double theta = rawTheta + delta * k;

    if (widget.mode == PlaiDialMode.hour && widget.use24h) {
      // 半径向最近环拉拢（渐进，非硬跳）
      final double innerFrac = ilr / lr;
      final double curFrac = (dist / lr).clamp(innerFrac, 1.0);
      final double targetFrac = dist < (ilr + lr) / 2 ? innerFrac : 1.0;
      final double radiusDist = (curFrac - targetFrac).abs() * lr;
      final double radiusZone = kDialRingGap * 0.4;
      final double k2 = (1 - radiusDist / radiusZone).clamp(0.0, 1.0);
      final double frac = curFrac + (targetFrac - curFrac) * k2;
      return (theta, frac);
    }
    return (theta, 1.0);
  }

  // ------------------------------------------------------------ 手势

  /// 提交手势落点：角度/距离校验 → 提交新值 → 算目标指示器位置 →
  /// `animate` 时起动画，否则存拖拽位置。
  void _commit(
    Offset local,
    double lr,
    double ilr, {
    required bool animate,
    bool snapToValue = false,
  }) {
    final double side = 2 * (lr + kDialPadding);
    final Offset delta = local - Offset(side / 2, side / 2);
    final double dist = delta.distance;
    // 太靠近圆心（角度不稳定）或出盘时忽略
    if (dist < kDialSelectorRadius || dist > lr + kDialSelectorRadius) {
      return;
    }
    final double rawTheta = math.atan2(-delta.dy, delta.dx);

    final double targetTheta;
    final double targetFrac;
    if (widget.mode == PlaiDialMode.hour) {
      final int index = PlaiTimeDialPainter.valueForAngle(rawTheta, 12);
      final int newHour;
      if (widget.use24h) {
        // 按落点半径判断内外环：外环 0-11，内环 12-23
        newHour = PlaiTimeDialPainter.isOuterRing(dist, ilr, lr)
            ? index
            : index + 12;
      } else {
        newHour = PlaiTimeDialPainter.twelveHourToInternal(
          index == 0 ? 12 : index,
          isPm: PlaiTimeDialPainter.isPm(widget.hour),
        );
      }
      widget.onHourChanged(newHour);
      // 目标是刚提交的新值的精确位置（onHourChanged 后 widget.hour 仍是旧值，须显式传新值），
      // 否则用渐进拉拢位置。
      final (double t, double f) = (snapToValue || animate)
          ? _valuePosition(hour: newHour, labelRadius: lr)
          : _snapPulled(rawTheta, dist, lr, ilr);
      targetTheta = t;
      targetFrac = f;
    } else {
      final int newMinute = PlaiTimeDialPainter.valueForAngle(rawTheta, 60);
      widget.onMinuteChanged(newMinute);
      final (double t, double f) = (snapToValue || animate)
          ? _valuePosition(minute: newMinute, labelRadius: lr)
          : _snapPulled(rawTheta, dist, lr, ilr);
      targetTheta = t;
      targetFrac = f;
    }

    if (animate) {
      final (double ct, double cf) = _currentDisplay(lr);
      _startAnim(ct, cf, targetTheta, targetFrac);
    } else {
      _anim.stop();
      setState(() {
        _dragging = true;
        _lastDragTheta = targetTheta;
        _lastDragFrac = targetFrac;
      });
    }
  }

  /// 抬起/取消：清拖拽态，指示器平滑滑到 committed 值的精确位置；
  /// 既无动画也无拖拽（已处于精确位置）时直接返回。
  void _settle(double lr) {
    final (double ct, double cf) = _currentDisplay(lr);
    final (double tt, double tf) = _valuePosition(labelRadius: lr);
    if (!_anim.isAnimating && _lastDragTheta == null) {
      return;
    }
    setState(() {
      _dragging = false;
      _lastDragTheta = null;
      _lastDragFrac = null;
    });
    _startAnim(ct, cf, tt, tf);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side =
            math.min(constraints.maxWidth, constraints.maxHeight);
        final double labelRadius = side / 2 - kDialPadding;
        final double innerLabelRadius = labelRadius - kDialRingGap;
        final (double theta, double frac) = _currentDisplay(labelRadius);
        final double dispRadius = labelRadius * frac;
        return GestureDetector(
          key: const Key('plai_dial'),
          behavior: HitTestBehavior.opaque,
          // tap 天然 = panDown + 立即 panEnd，无需单独 onTapDown
          onPanDown: (DragDownDetails d) => _commit(
            d.localPosition,
            labelRadius,
            innerLabelRadius,
            animate: false,
          ),
          onPanUpdate: (DragUpdateDetails d) => _commit(
            d.localPosition,
            labelRadius,
            innerLabelRadius,
            animate: false,
          ),
          onPanEnd: (DragEndDetails _) => _settle(labelRadius),
          onPanCancel: () => _settle(labelRadius),
          child: CustomPaint(
            key: const Key('plai_dial_paint'),
            size: Size.square(side),
            painter: PlaiTimeDialPainter(
              mode: widget.mode,
              use24h: widget.use24h,
              hour: widget.hour,
              minute: widget.minute,
              colorScheme: widget.colorScheme,
              textScaler: widget.textScaler,
              indicatorTheta: theta,
              indicatorRadius: dispRadius,
            ),
          ),
        );
      },
    );
  }
}
