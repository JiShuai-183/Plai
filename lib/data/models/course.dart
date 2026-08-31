import 'dart:convert';

/// 周次类型（PRD-课表模块 §5 课程表 weekType）。
enum WeekType {
  every('every', '每周'),
  odd('odd', '单周'),
  even('even', '双周'),
  custom('custom', '自定义');

  const WeekType(this.code, this.label);

  /// 存储 / 交换用的代码。
  final String code;

  /// 中文展示名。
  final String label;

  static WeekType fromCode(String code) => WeekType.values.firstWhere(
        (t) => t.code == code,
        orElse: () => throw FormatException('未知周次类型: "$code"'),
      );

  /// 宽容解析：兼容英文代码与中文名（每周/单周/双周/自定义）。
  static WeekType fromCodeLenient(String? code) {
    if (code == null || code.trim().isEmpty) return WeekType.every;
    switch (code.trim()) {
      case 'every':
      case '每周':
        return WeekType.every;
      case 'odd':
      case '单周':
        return WeekType.odd;
      case 'even':
      case '双周':
        return WeekType.even;
      case 'custom':
      case '自定义':
        return WeekType.custom;
      default:
        throw FormatException('未知周次类型: "$code"');
    }
  }
}

/// 课程（PRD-课表模块 §5）。
class Course {
  const Course({
    this.id,
    required this.semesterId,
    required this.name,
    this.teacher = '',
    this.location = '',
    this.color = '',
    this.weekType = WeekType.every,
    this.weekList = const [],
    this.startWeek = 1,
    this.endWeek = 1,
    required this.weekday,
    required this.startPeriod,
    required this.endPeriod,
  });

  /// 主键，新建时为 null。
  final int? id;

  /// 所属学期 id。
  final int semesterId;

  /// 课程名。
  final String name;

  /// 教师。
  final String teacher;

  /// 上课地点。
  final String location;

  /// 课程颜色（`#RRGGBB`，可为空字符串表示未设置）。
  final String color;

  /// 周次类型。
  final WeekType weekType;

  /// 自定义周序列（weekType=custom 时使用，如 `[1,3,5,8]`）。
  final List<int> weekList;

  /// 开始周。
  final int startWeek;

  /// 结束周。
  final int endWeek;

  /// 星期几（1=周一 … 7=周日）。
  final int weekday;

  /// 起始节次。
  final int startPeriod;

  /// 结束节次。
  final int endPeriod;

  Course copyWith({
    int? id,
    int? semesterId,
    String? name,
    String? teacher,
    String? location,
    String? color,
    WeekType? weekType,
    List<int>? weekList,
    int? startWeek,
    int? endWeek,
    int? weekday,
    int? startPeriod,
    int? endPeriod,
  }) {
    return Course(
      id: id ?? this.id,
      semesterId: semesterId ?? this.semesterId,
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      location: location ?? this.location,
      color: color ?? this.color,
      weekType: weekType ?? this.weekType,
      weekList: weekList ?? this.weekList,
      startWeek: startWeek ?? this.startWeek,
      endWeek: endWeek ?? this.endWeek,
      weekday: weekday ?? this.weekday,
      startPeriod: startPeriod ?? this.startPeriod,
      endPeriod: endPeriod ?? this.endPeriod,
    );
  }

  /// 数据库行映射（week_list 存 JSON 数组字符串）。
  Map<String, Object?> toDbMap() => {
        'id': id,
        'semester_id': semesterId,
        'name': name,
        'teacher': teacher,
        'location': location,
        'color': color,
        'week_type': weekType.code,
        'week_list': jsonEncode(weekList),
        'start_week': startWeek,
        'end_week': endWeek,
        'weekday': weekday,
        'start_period': startPeriod,
        'end_period': endPeriod,
      };

  factory Course.fromDbMap(Map<String, Object?> map) => Course(
        id: map['id'] as int?,
        semesterId: map['semester_id'] as int,
        name: map['name'] as String,
        teacher: (map['teacher'] as String?) ?? '',
        location: (map['location'] as String?) ?? '',
        color: (map['color'] as String?) ?? '',
        weekType: WeekType.fromCode(map['week_type'] as String),
        weekList: _decodeWeekList(map['week_list'] as String?),
        startWeek: map['start_week'] as int,
        endWeek: map['end_week'] as int,
        weekday: map['weekday'] as int,
        startPeriod: map['start_period'] as int,
        endPeriod: map['end_period'] as int,
      );

  /// 备份 / 导入导出用的 JSON 表示（camelCase，对齐 PRD 字段名）。
  Map<String, Object?> toJson() => {
        'id': id,
        'semesterId': semesterId,
        'name': name,
        'teacher': teacher,
        'location': location,
        'color': color,
        'weekType': weekType.code,
        'weekList': weekList,
        'startWeek': startWeek,
        'endWeek': endWeek,
        'weekday': weekday,
        'startPeriod': startPeriod,
        'endPeriod': endPeriod,
      };

  factory Course.fromJson(Map<String, Object?> json) => Course(
        id: json['id'] as int?,
        semesterId: json['semesterId'] as int,
        name: json['name'] as String,
        teacher: (json['teacher'] as String?) ?? '',
        location: (json['location'] as String?) ?? '',
        color: (json['color'] as String?) ?? '',
        weekType: WeekType.fromCode(json['weekType'] as String),
        weekList: (json['weekList'] as List?)?.cast<int>() ?? const [],
        startWeek: json['startWeek'] as int,
        endWeek: json['endWeek'] as int,
        weekday: json['weekday'] as int,
        startPeriod: json['startPeriod'] as int,
        endPeriod: json['endPeriod'] as int,
      );

  static List<int> _decodeWeekList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return (decoded as List).cast<int>();
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Course &&
        other.id == id &&
        other.semesterId == semesterId &&
        other.name == name &&
        other.teacher == teacher &&
        other.location == location &&
        other.color == color &&
        other.weekType == weekType &&
        _listEquals(other.weekList, weekList) &&
        other.startWeek == startWeek &&
        other.endWeek == endWeek &&
        other.weekday == weekday &&
        other.startPeriod == startPeriod &&
        other.endPeriod == endPeriod;
  }

  @override
  int get hashCode => Object.hash(
        id,
        semesterId,
        name,
        teacher,
        location,
        color,
        weekType,
        Object.hashAll(weekList),
        startWeek,
        endWeek,
        weekday,
        startPeriod,
        endPeriod,
      );

  @override
  String toString() => 'Course(id: $id, name: $name, semesterId: $semesterId)';

  static bool _listEquals(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
