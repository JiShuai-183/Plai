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

/// 课程卡：周视图小卡（compact）与日视图大卡共用，无色/状态色/已结束
/// 文字淡化/细化逻辑收口在此。
///
/// - [color] 为 null → 中性样式：浅底 + 浅灰描边 + 灰字；
/// - [color] 非 null → 沿用原有风格：`color@0.16` 底、`color@0.6` 描边、
///   课程名 `color`（w600）；
/// - 已结束（由调用方判断并传 [finishedTextFade]/[finishedTextThin]）：
///   淡化开 → 课程名与地点文字用淡灰；细化开 → 课程名字重从 w600 降到 w400。
class CourseCard extends StatelessWidget {
  const CourseCard({
    super.key,
    required this.course,
    required this.color,
    required this.onTap,
    this.compact = false,
    this.finishedTextFade = false,
    this.finishedTextThin = false,
  });

  /// 对应课程。
  final Course course;

  /// 主色；null = 无色中性样式。
  final Color? color;

  /// 点击回调（进入编辑页）。
  final VoidCallback onTap;

  /// 周视图小卡为 true；日视图为 false。
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
    final Color? c = color;
    final bool neutral = c == null;

    final Color background = neutral
        ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5)
        : c.withValues(alpha: 0.16);
    final Color border = neutral
        ? theme.colorScheme.outlineVariant
        : c.withValues(alpha: 0.6);
    Color nameColor;
    Color locationColor;
    if (neutral) {
      nameColor = theme.colorScheme.onSurfaceVariant;
      locationColor = theme.colorScheme.onSurfaceVariant;
    } else {
      nameColor = c;
      locationColor = c.withValues(alpha: 0.8);
    }
    if (finishedTextFade) {
      nameColor = finishedGrey;
      locationColor = finishedGrey;
    }

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 4, vertical: 3)
              : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                course.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 11 : null,
                  fontWeight: finishedTextThin
                      ? FontWeight.w400
                      : FontWeight.w600,
                  color: nameColor,
                ),
              ),
              if (course.location.isNotEmpty)
                Text(
                  course.location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 9 : 12,
                    color: locationColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
