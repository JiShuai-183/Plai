import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/ai/ai_task_type_rules.dart';

void main() {
  final today = DateTime(2026, 11, 8);
  test('每日事项从今天长期，无期限事项不捏造截止', () {
    final daily = normalizeAiTaskCreation({
      'action': 'create',
      'title': '每天背单词',
    }, now: today);
    expect(daily['type'], 'daily');
    expect(daily['start_date'], '2026-11-08');
    expect(daily['due_date'], isNull);
    final todo = normalizeAiTaskCreation({
      'action': 'create',
      'title': '买电池',
    }, now: today);
    expect(todo['type'], 'todo');
    expect(todo['due_date'], isNull);
    expect(todo.containsKey('start_date'), isFalse);
  });
  test('期限事项默认从今天开始并保留精确时刻，明确预约保留定时类型', () {
    final span = normalizeAiTaskCreation({
      'action': 'create',
      'title': '交报告',
      'due_date': '2026-11-13',
      'due_time': '22:00',
    }, now: today);
    expect(span['type'], 'span');
    expect(span['start_date'], '2026-11-08');
    expect(span['due_time'], '22:00');
    final scheduled = normalizeAiTaskCreation({
      'action': 'create',
      'type': 'scheduled',
      'title': '开会',
      'due_date': '2026-11-13',
      'due_time': '15:00',
    }, now: today);
    expect(scheduled['type'], 'scheduled');
    expect(scheduled.containsKey('start_date'), isFalse);
  });
  test('明确选择与起始日期保持，修改不重新分类', () {
    final explicit = normalizeAiTaskCreation({
      'action': 'create',
      'type': 'todo',
      'title': '旧调用',
      'due_date': '2026-11-13',
    }, now: today);
    expect(explicit['type'], 'todo');
    final daily = normalizeAiTaskCreation({
      'action': 'create',
      'type': 'daily',
      'title': '背单词',
      'start_date': '2026-11-10',
    }, now: today);
    expect(daily['start_date'], '2026-11-10');
    final update = {'action': 'update', 'title': '每天的历史记录'};
    expect(normalizeAiTaskCreation(update, now: today), update);
  });
}
