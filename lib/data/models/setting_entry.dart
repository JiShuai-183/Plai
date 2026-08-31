/// 键值设置条目（PRD-设置与数据 §1 setting 表）。
class SettingEntry {
  const SettingEntry({
    required this.key,
    required this.value,
  });

  /// 设置键。
  final String key;

  /// 设置值（统一存字符串，由使用方按需解析）。
  final String value;

  SettingEntry copyWith({
    String? key,
    String? value,
  }) {
    return SettingEntry(
      key: key ?? this.key,
      value: value ?? this.value,
    );
  }

  Map<String, Object?> toDbMap() => {
        'key': key,
        'value': value,
      };

  factory SettingEntry.fromDbMap(Map<String, Object?> map) => SettingEntry(
        key: map['key'] as String,
        value: map['value'] as String,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SettingEntry &&
        other.key == key &&
        other.value == value;
  }

  @override
  int get hashCode => Object.hash(key, value);

  @override
  String toString() => 'SettingEntry(key: $key, value: $value)';
}
