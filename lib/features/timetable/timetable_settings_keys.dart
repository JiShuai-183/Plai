/// 课表模块状态色 / 无色课程相关设置键（命名空间 `timetable.*`）。
///
/// 设置模块读写这几个键即可联动课表渲染（字面量不得随意改动），
/// 本文件同时集中各键的默认值常量，供 [TimetableStatusSettings] 解析缺省使用。
abstract final class TimetableSettingsKeys {
  /// 状态色总开关（'true' / 'false'，默认开）。
  static const String statusColorsEnabled = 'timetable.status_colors_enabled';

  /// 正在上(ongoing)状态色（`#RRGGBB`，空串为无色）。
  static const String statusColorOngoing = 'timetable.status_color_ongoing';

  /// 还未上(upcoming)状态色（`#RRGGBB`，空串为无色）。
  static const String statusColorUpcoming = 'timetable.status_color_upcoming';

  /// 上完(finished)状态色（`#RRGGBB`，空串为无色）。
  static const String statusColorFinished = 'timetable.status_color_finished';

  /// 已结束文字淡化开关（淡化 = 课程名与地点用淡灰，'true'/'false'，默认开）。
  static const String finishedTextFade = 'timetable.finished_text_fade';

  /// 已结束文字细化开关（细化 = 课程名字重从 w600 降到 w400，'true'/'false'，默认开）。
  static const String finishedTextThin = 'timetable.finished_text_thin';

  /// 默认课程颜色（新建/导入课程初始色，`#RRGGBB`，空串为无色）。
  static const String defaultCourseColor = 'timetable.default_course_color';

  /// Windows 课表缩放比例，范围 0.8–1.5、步进 0.1。
  static const String desktopScale = 'timetable.desktop_scale';

  // ------------------------------------------------------------ 默认值

  /// 状态色总开关默认值：开。
  static const bool defaultStatusColorsEnabled = true;

  /// 正在上状态色默认值：淡蓝。
  static const String defaultStatusColorOngoing = '#4FC3F7';

  /// 还未上状态色默认值：无色。
  static const String defaultStatusColorUpcoming = '';

  /// 上完状态色默认值：灰。
  static const String defaultStatusColorFinished = '#9E9E9E';

  /// 已结束文字淡化默认值：开。
  static const bool defaultFinishedTextFade = true;

  /// 已结束文字细化默认值：开。
  static const bool defaultFinishedTextThin = true;

  /// 默认课程颜色缺省值：无色（新建/导入课程默认无色）。
  static const String defaultCourseColorDefault = '';

  /// 电脑端课表默认缩放：100%。
  static const double defaultDesktopScale = 1.0;

  static const double minDesktopScale = 0.8;
  static const double maxDesktopScale = 1.5;
  static const double desktopScaleStep = 0.1;

  /// 将任意输入规整到合法的 10% 缩放档位。
  static double normalizeDesktopScale(double value) {
    final double clamped = value.clamp(minDesktopScale, maxDesktopScale);
    return (clamped * 10).roundToDouble() / 10;
  }
}
