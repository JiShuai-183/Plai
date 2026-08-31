import 'date_utils.dart';

/// 学期（PRD-课表模块 §5）。
class Semester {
  const Semester({
    this.id,
    required this.name,
    required this.startDate,
    required this.totalWeeks,
  });

  /// 主键，新建时为 null（插入后回填）。
  final int? id;

  /// 学期名称，如「2026 秋」。
  final String name;

  /// 开学日期（第 1 周周一）。
  final DateTime startDate;

  /// 总周数。
  final int totalWeeks;

  /// 学期结束日期（开学日 + 总周数 - 1 天），由字段推导，不入库。
  DateTime get endDate => startDate.add(Duration(days: totalWeeks * 7 - 1));

  Semester copyWith({
    int? id,
    String? name,
    DateTime? startDate,
    int? totalWeeks,
  }) {
    return Semester(
      id: id ?? this.id,
      name: name ?? this.name,
      startDate: startDate ?? this.startDate,
      totalWeeks: totalWeeks ?? this.totalWeeks,
    );
  }

  /// 数据库行映射（snake_case）。
  Map<String, Object?> toDbMap() => {
        'id': id,
        'name': name,
        'start_date': dateOnlyToString(startDate),
        'total_weeks': totalWeeks,
      };

  factory Semester.fromDbMap(Map<String, Object?> map) => Semester(
        id: map['id'] as int?,
        name: map['name'] as String,
        startDate: stringToDateOnly(map['start_date'] as String),
        totalWeeks: map['total_weeks'] as int,
      );

  /// 备份 / 导入导出用的 JSON 表示（camelCase，对齐 PRD 字段名）。
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'startDate': dateOnlyToString(startDate),
        'totalWeeks': totalWeeks,
      };

  factory Semester.fromJson(Map<String, Object?> json) => Semester(
        id: json['id'] as int?,
        name: json['name'] as String,
        startDate: stringToDateOnly(json['startDate'] as String),
        totalWeeks: json['totalWeeks'] as int,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Semester &&
        other.id == id &&
        other.name == name &&
        other.startDate == startDate &&
        other.totalWeeks == totalWeeks;
  }

  @override
  int get hashCode => Object.hash(id, name, startDate, totalWeeks);

  @override
  String toString() => 'Semester(id: $id, name: $name, '
      'startDate: ${dateOnlyToString(startDate)}, totalWeeks: $totalWeeks)';
}
