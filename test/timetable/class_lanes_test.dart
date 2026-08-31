import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/models/course.dart';
import 'package:plai/features/timetable/class_lanes.dart';

Course course(int start, int end, {String name = '课'}) => Course(
      semesterId: 1,
      name: name,
      weekday: 1,
      startPeriod: start,
      endPeriod: end,
    );

void main() {
  test('不重叠课程各占满行（laneCount=1）', () {
    final slots = computeCourseSlots([course(1, 2), course(3, 4)]);
    expect(slots, hasLength(2));
    expect(slots[0].lane, 0);
    expect(slots[0].laneCount, 1);
    expect(slots[1].lane, 0);
    expect(slots[1].laneCount, 1);
  });

  test('同节次重叠并排（laneCount=2，车道不同）', () {
    final slots = computeCourseSlots([course(1, 2, name: 'A'), course(1, 2, name: 'B')]);
    expect(slots, hasLength(2));
    expect(slots[0].laneCount, 2);
    expect(slots[1].laneCount, 2);
    expect(slots[0].lane, isNot(slots[1].lane));
  });

  test('连续节次重叠（1-2 与 2-3 共用第 2 节）并排', () {
    final slots = computeCourseSlots([course(1, 2), course(2, 3)]);
    expect(slots[0].laneCount, 2);
    expect(slots[1].laneCount, 2);
  });

  test('复杂：重叠部分并排，独立课程恢复满行', () {
    // A(1,3) 与 B(2,4) 重叠；C(5,5) 与二者无重叠。
    final slots = computeCourseSlots([course(1, 3, name: 'A'), course(2, 4, name: 'B'), course(5, 5, name: 'C')]);
    expect(slots, hasLength(3));
    expect(slots[0].laneCount, 2);
    expect(slots[1].laneCount, 2);
    expect(slots[0].lane, isNot(slots[1].lane));
    expect(slots[2].laneCount, 1);
  });

  test('输入顺序不影响排布（先给后课仍正确分组）', () {
    final slots = computeCourseSlots([course(5, 5, name: 'C'), course(1, 3, name: 'A'), course(2, 4, name: 'B')]);
    final a = slots.firstWhere((s) => s.course.name == 'A');
    final b = slots.firstWhere((s) => s.course.name == 'B');
    final c = slots.firstWhere((s) => s.course.name == 'C');
    expect(a.laneCount, 2);
    expect(b.laneCount, 2);
    expect(c.laneCount, 1);
    expect(a.lane, isNot(b.lane));
  });

  test('空列表返回空', () {
    expect(computeCourseSlots([]), isEmpty);
  });
}
