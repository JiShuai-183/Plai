import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 星期几中文名（1=周一 … 7=周日）；越界时收敛到 [1, 7]。
String weekdayLabel(int weekday) {
  const List<String> labels = ['一', '二', '三', '四', '五', '六', '日'];
  final int index = weekday.clamp(1, 7);
  return '周${labels[index - 1]}';
}

/// 完整星期几中文名，如「星期一」。
String weekdayFullLabel(int weekday) {
  const List<String> labels = ['一', '二', '三', '四', '五', '六', '日'];
  final int index = weekday.clamp(1, 7);
  return '星期${labels[index - 1]}';
}

/// `M月d日`。
String formatMonthDay(DateTime date) => DateFormat('M月d日').format(date);

/// `yyyy年M月d日`。
String formatFullDate(DateTime date) => DateFormat('yyyy年M月d日').format(date);

/// `M月d日 周一`。
String formatDateWeekday(DateTime date) =>
    '${formatMonthDay(date)} ${weekdayLabel(date.weekday)}';

/// `HH:mm`（本地时区）。
String formatTime(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

/// [TimeOfDay] → `HH:mm`。
String formatTimeOfDay(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
