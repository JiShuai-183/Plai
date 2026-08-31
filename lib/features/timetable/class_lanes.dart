import '../../data/models/course.dart';

/// 课程在节次网格中的横向排布：并排车道（lane）与该重叠组总车道数。
class CourseSlot {
  const CourseSlot({
    required this.course,
    required this.lane,
    required this.laneCount,
  });

  /// 对应课程。
  final Course course;

  /// 横向车道序号（0 起）。车道数 > 1 时课程块按 `lane/laneCount` 偏移、宽度取 `1/laneCount`。
  final int lane;

  /// 该重叠组的总车道数。
  final int laneCount;
}

/// 把同一星期（同一周次下）的课程分配成互不重叠的「车道」。
///
/// 两门课在节次上重叠（`max(start) <= min(end)`，含连续节次如 1-2 与 2-3
/// 共用第 2 节）则必须并排；同一重叠组件内的课程按开始节次贪心分配车道
/// （区间划分），组件结束后每个槽位补记 laneCount。返回顺序与传入无关
/// （内部按 开始节次、结束节次 排序）。
List<CourseSlot> computeCourseSlots(List<Course> courses) {
  if (courses.isEmpty) return const <CourseSlot>[];
  final List<Course> sorted = [...courses]..sort((a, b) {
        final int s = a.startPeriod.compareTo(b.startPeriod);
        if (s != 0) return s;
        return a.endPeriod.compareTo(b.endPeriod);
      });

  final List<CourseSlot> result = <CourseSlot>[];
  // 当前重叠组件：各车道的占用结束节次；组件覆盖的最大结束节次；组件起点。
  final List<int> laneEnds = <int>[];
  int componentEnd = 0;
  int componentStartIndex = 0;

  for (final Course course in sorted) {
    if (laneEnds.isNotEmpty && course.startPeriod > componentEnd) {
      _closeComponent(result, componentStartIndex, laneEnds.length);
      laneEnds.clear();
      componentEnd = 0;
      componentStartIndex = result.length;
    }

    // 找第一个「该车道当前课程结束在当前课程开始之前」的车道复用；否则新开车道。
    int lane = -1;
    for (int i = 0; i < laneEnds.length; i++) {
      if (laneEnds[i] < course.startPeriod) {
        lane = i;
        break;
      }
    }
    if (lane == -1) {
      laneEnds.add(course.endPeriod);
      lane = laneEnds.length - 1;
    } else {
      laneEnds[lane] = course.endPeriod;
    }
    if (course.endPeriod > componentEnd) componentEnd = course.endPeriod;

    // laneCount 在组件关闭时统一回填。
    result.add(CourseSlot(course: course, lane: lane, laneCount: 0));
  }
  if (laneEnds.isNotEmpty) {
    _closeComponent(result, componentStartIndex, laneEnds.length);
  }
  return result;
}

/// 给 [start, result.length) 区间的槽位回填车道数。
void _closeComponent(List<CourseSlot> result, int start, int laneCount) {
  for (int i = start; i < result.length; i++) {
    final CourseSlot slot = result[i];
    result[i] = CourseSlot(
      course: slot.course,
      lane: slot.lane,
      laneCount: laneCount,
    );
  }
}
