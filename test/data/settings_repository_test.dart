import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  late TestData data;

  setUp(() async {
    data = await TestData.create();
  });

  tearDown(() async {
    await data.db.close();
  });

  test('getValue/setValue 读写与覆盖', () async {
    final repo = data.settings;
    expect(await repo.getValue('remind_minutes'), isNull);

    await repo.setValue('remind_minutes', '10');
    expect(await repo.getValue('remind_minutes'), '10');

    await repo.setValue('remind_minutes', '30');
    expect(await repo.getValue('remind_minutes'), '30');
  });

  test('setAll 批量写入，getAll 全量读取', () async {
    final repo = data.settings;
    await repo.setAll({'a': '1', 'b': '2'});
    final all = await repo.getAll();
    expect(all, {'a': '1', 'b': '2'});
  });

  test('remove 删除指定键', () async {
    final repo = data.settings;
    await repo.setValue('theme', 'dark');
    await repo.remove('theme');
    expect(await repo.getValue('theme'), isNull);
  });
}
