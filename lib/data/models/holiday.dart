import 'date_utils.dart';

/// 停课 / 节假日记录（PRD-课表模块 §5）。
class Holiday {
  const Holiday({
    this.id,
    required this.date,
    this.courseId,
    this.reason = '',
  });

  /// 主键，新建时为 null。
  final int? id;

  /// 停课日期。
  final DateTime date;

  /// 仅停某一门课时指定；为 null 表示当天全局停课。
  final int? courseId;

  /// 原因，如「国庆放假」「调停课」。
  final String reason;

  Holiday copyWith({
    int? id,
    DateTime? date,
    int? courseId,
    String? reason,
  }) {
    return Holiday(
      id: id ?? this.id,
      date: date ?? this.date,
      courseId: courseId ?? this.courseId,
      reason: reason ?? this.reason,
    );
  }

  Map<String, Object?> toDbMap() => {
        'id': id,
        'date': dateOnlyToString(date),
        'course_id': courseId,
        'reason': reason,
      };

  factory Holiday.fromDbMap(Map<String, Object?> map) => Holiday(
        id: map['id'] as int?,
        date: stringToDateOnly(map['date'] as String),
        courseId: map['course_id'] as int?,
        reason: (map['reason'] as String?) ?? '',
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'date': dateOnlyToString(date),
        'courseId': courseId,
        'reason': reason,
      };

  factory Holiday.fromJson(Map<String, Object?> json) => Holiday(
        id: json['id'] as int?,
        date: stringToDateOnly(json['date'] as String),
        courseId: json['courseId'] as int?,
        reason: (json['reason'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Holiday &&
        other.id == id &&
        other.date == date &&
        other.courseId == courseId &&
        other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(id, date, courseId, reason);

  @override
  String toString() => 'Holiday(id: $id, date: ${dateOnlyToString(date)}, '
      'courseId: $courseId, reason: $reason)';
}
