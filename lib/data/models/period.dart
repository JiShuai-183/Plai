/// 节次（PRD-课表模块 §5）。
class Period {
  const Period({
    this.id,
    required this.index,
    required this.startTime,
    required this.endTime,
  });

  /// 主键，新建时为 null。
  final int? id;

  /// 节次序号（1 起，全局唯一）。
  final int index;

  /// 开始时间（`HH:mm`）。
  final String startTime;

  /// 结束时间（`HH:mm`）。
  final String endTime;

  Period copyWith({
    int? id,
    int? index,
    String? startTime,
    String? endTime,
  }) {
    return Period(
      id: id ?? this.id,
      index: index ?? this.index,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }

  /// 数据库行映射（`index` 列名用 `idx`，避免与 SQL 关键字混淆）。
  Map<String, Object?> toDbMap() => {
        'id': id,
        'idx': index,
        'start_time': startTime,
        'end_time': endTime,
      };

  factory Period.fromDbMap(Map<String, Object?> map) => Period(
        id: map['id'] as int?,
        index: map['idx'] as int,
        startTime: map['start_time'] as String,
        endTime: map['end_time'] as String,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'index': index,
        'startTime': startTime,
        'endTime': endTime,
      };

  factory Period.fromJson(Map<String, Object?> json) => Period(
        id: json['id'] as int?,
        index: json['index'] as int,
        startTime: json['startTime'] as String,
        endTime: json['endTime'] as String,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Period &&
        other.id == id &&
        other.index == index &&
        other.startTime == startTime &&
        other.endTime == endTime;
  }

  @override
  int get hashCode => Object.hash(id, index, startTime, endTime);

  @override
  String toString() => 'Period(id: $id, index: $index, '
      '$startTime-$endTime)';
}
