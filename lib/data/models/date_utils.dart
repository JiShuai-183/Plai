/// 日期/时间字符串工具。
///
/// 约定（与 PRD 对齐，全 App 统一）：
/// - 日期存 `yyyy-MM-dd`，仅本地时区，无跨时区需求。
/// - 时刻存 `HH:mm`（24 小时制）。
library;

/// 把日期格式化为 `yyyy-MM-dd`（丢弃时分秒）。
String dateOnlyToString(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

/// 解析 `yyyy-MM-dd` 为日期（本地时区，时间为 00:00）。
///
/// 格式非法抛 [FormatException]。
DateTime stringToDateOnly(String value) {
  final parts = value.split('-');
  if (parts.length != 3) {
    throw FormatException('非法日期格式: "$value"（应为 yyyy-MM-dd）');
  }
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) {
    throw FormatException('非法日期格式: "$value"');
  }
  return DateTime(year, month, day);
}

/// 宽容解析 `yyyy-MM-dd`，非法或为空返回 null。
DateTime? tryParseDateOnly(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  try {
    return stringToDateOnly(value.trim());
  } on FormatException {
    return null;
  }
}

/// 是否为合法 24 小时制时刻 `HH:mm`。
bool isValidTime24h(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return false;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return false;
  return h >= 0 && h <= 23 && m >= 0 && m <= 59;
}
