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

    if (mode == PlaiDialMode.hour) {
      if (use24h) {
        _paint24hHourDial(canvas, center, labelRadius, innerLabelRadius);
      } else {
        _paint12hHourDial(canvas, center, labelRadius);
      }
    } else {
      _paintMinuteDial(canvas, center, labelRadius);
    }
  }

  /// 24h 小时盘：外环 0-11，内环 12-23，内外环对应数字同角度仅半径差 [kDialRingGap]。
  void _paint24hHourDial(
    Canvas canvas,
    Offset center,
    double labelRadius,
    double innerLabelRadius,
  ) {
    final bool outer = hour < 12;
    final int index = outer ? hour : hour - 12;
    // 指针：选在外环时手长 labelRadius，内环时手长 innerLabelRadius
    final double handRadius = outer ? labelRadius : innerLabelRadius;
    final double theta = math.pi / 2 - index * (2 * math.pi / 12);
    final Offset tip = center +
        Offset(handRadius * math.cos(theta), -handRadius * math.sin(theta));
    _paintHand(canvas, center, tip);

    for (int i = 0; i < 12; i++) {
      final double a = math.pi / 2 - i * (2 * math.pi / 12);
      final Offset outerPos = center +
          Offset(labelRadius * math.cos(a), -labelRadius * math.sin(a));
      _paintHourLabel(canvas, outerPos, '$i', selected: hour == i);
      final Offset innerPos = center +
          Offset(
              innerLabelRadius * math.cos(a), -innerLabelRadius * math.sin(a));
      _paintHourLabel(canvas, innerPos, '${i + 12}', selected: hour == i + 12);
    }
  }

  /// 12h 小时盘：单环 1-12，顶部为 12。
  void _paint12hHourDial(Canvas canvas, Offset center, double labelRadius) {
    final int display = internalToTwelveHour(hour);
    final int index = display % 12; // 12 → 0 → 顶部
    final double theta = math.pi / 2 - index * (2 * math.pi / 12);
    final Offset tip = center +
        Offset(labelRadius * math.cos(theta), -labelRadius * math.sin(theta));
    _paintHand(canvas, center, tip);

    for (int i = 1; i <= 12; i++) {
      final double a = math.pi / 2 - (i % 12) * (2 * math.pi / 12);
      final Offset pos = center +
          Offset(labelRadius * math.cos(a), -labelRadius * math.sin(a));
      _paintHourLabel(canvas, pos, '$i', selected: i == display);
    }
  }

  /// 分钟盘：60 个刻度（每 6° 一格，顶部 = 0 分，顺时针），
  /// 逐分钟细刻度 + 整五粗刻度与数字，指针吸附到最近分钟。
  void _paintMinuteDial(Canvas canvas, Offset center, double labelRadius) {
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

    // 手尖高亮圆盖在选中分钟位置，数字画在圆内
    final double theta = math.pi / 2 - minute * (2 * math.pi / 60);
    final Offset tip = center +
        Offset(labelRadius * math.cos(theta), -labelRadius * math.sin(theta));
    _paintHand(canvas, center, tip);
    final Paint fill = Paint()..color = colorScheme.primary;
    canvas.drawCircle(tip, kDialSelectorRadius, fill);
    _paintLabel(canvas, tip, '$minute', colorScheme.onPrimary, 14);
  }

  /// 小时数字：选中时画 primary 高亮圆（半径 [kDialSelectorRadius]，
  /// 数字 onPrimary 画在圆内），未选中画 onSurfaceVariant 文字。
  void _paintHourLabel(
    Canvas canvas,
    Offset pos,
    String text, {
    required bool selected,
  }) {
    if (selected) {
      final Paint fill = Paint()..color = colorScheme.primary;
      canvas.drawCircle(pos, kDialSelectorRadius, fill);
      _paintLabel(canvas, pos, text, colorScheme.onPrimary, 16);
    } else {
      _paintLabel(canvas, pos, text, colorScheme.onSurfaceVariant, 16);
    }
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

/// 拨盘交互区：点击/拖动沿盘面按角度吸附最近小时/分钟；
/// 24h 小时模式按落点半径判断内外环。
class _PlaiDial extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side = math.min(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          key: const Key('plai_dial'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) => _handle(d.localPosition, side),
          onPanDown: (DragDownDetails d) => _handle(d.localPosition, side),
          onPanUpdate: (DragUpdateDetails d) => _handle(d.localPosition, side),
          child: CustomPaint(
            key: const Key('plai_dial_paint'),
            size: Size.square(side),
            painter: PlaiTimeDialPainter(
              mode: mode,
              use24h: use24h,
              hour: hour,
              minute: minute,
              colorScheme: colorScheme,
              textScaler: textScaler,
            ),
          ),
        );
      },
    );
  }

  void _handle(Offset local, double side) {
    final Offset center = Offset(side / 2, side / 2);
    final Offset delta = local - center;
    final double distance = delta.distance;
    final double labelRadius = side / 2 - kDialPadding;
    final double innerLabelRadius = labelRadius - kDialRingGap;
    // 太靠近圆心（角度不稳定）或出盘时忽略
    if (distance < kDialSelectorRadius ||
        distance > labelRadius + kDialSelectorRadius) {
      return;
    }
    final double theta = math.atan2(-delta.dy, delta.dx);
    if (mode == PlaiDialMode.hour) {
      final int index = PlaiTimeDialPainter.valueForAngle(theta, 12);
      if (use24h) {
        // 按落点半径判断内外环：外环 0-11，内环 12-23
        final bool outer = PlaiTimeDialPainter.isOuterRing(
          distance,
          innerLabelRadius,
          labelRadius,
        );
        onHourChanged(outer ? index : index + 12);
      } else {
        final int display12 = index == 0 ? 12 : index;
        onHourChanged(PlaiTimeDialPainter.twelveHourToInternal(
          display12,
          isPm: PlaiTimeDialPainter.isPm(hour),
        ));
      }
    } else {
      onMinuteChanged(PlaiTimeDialPainter.valueForAngle(theta, 60));
    }
  }
}
