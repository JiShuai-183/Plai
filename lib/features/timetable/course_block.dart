import 'package:flutter/material.dart';

import '../../data/models/course.dart';
import 'color_utils.dart';
import 'course_status.dart';
import 'timetable_providers.dart';

/// 解析课程卡主色：状态色 > 课程自选色；null = 无色中性样式。
///
/// - [status] 非 null（今天 + 当前周）且状态色总开关打开 → 按状态取
///   ongoing/upcoming/finished 对应的状态色；状态色为空串则为 null（无色）；
/// - 其余情况取课程自选色；自选色为空串则为 null（无色）。
Color? resolveCourseColor({
  required Course course,
  required CourseStatus? status,
  required TimetableStatusSettings settings,
}) {
  if (settings.statusColorsEnabled && status != null) {
    final String hex = switch (status) {
      CourseStatus.ongoing => settings.ongoingColor,
      CourseStatus.upcoming => settings.upcomingColor,
      CourseStatus.finished => settings.finishedColor,
    };
    if (hex.trim().isEmpty) return null;
    return colorFromHex(hex);
  }
  if (course.color.trim().isEmpty) return null;
  return colorFromHex(course.color);
}

/// 分段课程块：周视图小卡（compact）与日视图大卡共用，按节次独立染色。
///
/// 连排课（跨多节）每节一个独立色块：背景按 [perPeriodColors] 逐节纵向
/// 分区染色，课程名/地点信息显示在块顶部浮层；边框用首节色描边。
///
/// - [perPeriodColors] 每节一色，null 表示该节无色中性；
/// - [color] 语义由首节色（列表首个）决定：null → 中性样式（浅底 + 浅灰
///   描边 + 灰字）；非 null → 沿用原有风格（`color@0.16` 底、`color@0.6`
///   描边、课程名 `color` w600）；
/// - 已结束（由调用方判断并传 [finishedTextFade]/[finishedTextThin]）：
///   淡化开 → 课程名与地点文字用淡灰；细化开 → 课程名字重从 w600 降到 w400。
class SegmentedCourseBlock extends StatelessWidget {
  const SegmentedCourseBlock({
    super.key,
    required this.course,
    required this.perPeriodColors,
    required this.onTap,
    this.expanded = false,
    this.compact = false,
    this.finishedTextFade = false,
    this.finishedTextThin = false,
  });

  /// 对应课程。
  final Course course;

  /// 每节颜色（索引 = 相对起始节次偏移）；null = 该节无色中性。
  final List<Color?> perPeriodColors;

  /// 点击回调（进入编辑页）。
  final VoidCallback onTap;

  /// 连排课（跨 ≥2 节）为 true：信息展开显示（字号增大、可多行）。
  final bool expanded;

  /// 周视图小卡为 true；日视图为 false（决定紧凑字号）。
  final bool compact;

  /// 已结束文字淡化（课程名与地点文字用淡灰）。
  final bool finishedTextFade;

  /// 已结束文字细化（课程名字重变细）。
  final bool finishedTextThin;

  /// 已结束文字淡化 / 已结束状态色共用的淡灰。
  static const Color finishedGrey = Color(0xFF9E9E9E);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color? firstColor =
        perPeriodColors.isEmpty ? null : perPeriodColors.first;
    final bool neutral = firstColor == null;

    // 背景：逐节纵向分区，节间无分隔线。
    final Widget background = perPeriodColors.isEmpty
        ? Container(
            color: theme.colorScheme.surfaceContainerHigh
                .withValues(alpha: 0.5),
          )
        : Column(
            children: [
              for (final Color? pc in perPeriodColors)
                Expanded(
                  child: Container(
                    color: pc == null
                        ? theme.colorScheme.surfaceContainerHigh
                            .withValues(alpha: 0.5)
                        : pc.withValues(alpha: 0.16),
                  ),
                ),
            ],
          );

    final Color borderColor = neutral
        ? theme.colorScheme.outlineVariant
        : firstColor.withValues(alpha: 0.6);

    Color nameColor;
    Color locationColor;
    if (neutral) {
      nameColor = theme.colorScheme.onSurfaceVariant;
      locationColor = theme.colorScheme.onSurfaceVariant;
    } else {
      nameColor = firstColor;
      locationColor = firstColor.withValues(alpha: 0.8);
    }
    if (finishedTextFade) {
      nameColor = finishedGrey;
      locationColor = finishedGrey;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 逐节染色背景。
              background,
              // 信息浮层：顶部左对齐。
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Padding(
                  padding: compact
                      ? const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 3)
                      : const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        course.name,
                        maxLines: expanded ? 4 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? (expanded ? 13 : 11) : null,
                          fontWeight: finishedTextThin
                              ? FontWeight.w400
                              : FontWeight.w600,
                          color: nameColor,
                        ),
                      ),
                      if (course.location.isNotEmpty)
                        Text(
                          course.location,
                          maxLines: expanded ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize:
                                compact ? (expanded ? 11 : 9) : 12,
                            color: locationColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 外框描边（不拦截点击）。
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
