import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/repositories/eams_credentials_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('未保存时为空', () async {
    expect(await EamsCredentialsRepository().read(), isNull);
  });

  test('新仓库实例读回账号密码，密码保留空格和特殊字符', () async {
    const password = '  Test-密码/"\\🌱  ';
    await EamsCredentialsRepository().save(
      const EamsCredentials(username: ' student-test ', password: password),
    );
    final saved = await EamsCredentialsRepository().read();
    expect(saved!.username, 'student-test');
    expect(saved.password, password);
    expect(saved.toString(), isNot(contains(password)));
  });

  test('覆盖整对凭据，清除不影响其它安全存储键', () async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'other.secret', value: 'unrelated');
    final repo = EamsCredentialsRepository();
    await repo.save(
      const EamsCredentials(username: 'old', password: 'old-pass'),
    );
    await repo.save(
      const EamsCredentials(username: 'new', password: 'new-pass'),
    );
    expect((await repo.read())!.username, 'new');
    expect((await repo.read())!.password, 'new-pass');
    await repo.clear();
    await repo.clear();
    expect(await repo.read(), isNull);
    expect(await storage.read(key: 'other.secret'), 'unrelated');
  });

  for (final invalid in [
    '',
    'not-json-secret',
    '[]',
    '{"username":"u"}',
    '{"username":"u","password":2}',
    '{"username":" ","password":"secret"}',
  ]) {
    test('损坏记录报固定错误，不回显内容：${invalid.length}', () async {
      FlutterSecureStorage.setMockInitialValues({
        EamsCredentialsRepository.storageKey: invalid,
      });
      expect(
        EamsCredentialsRepository().read(),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', '本机教务凭据损坏')
              .having((e) => e.source, 'source', isNull),
        ),
      );
    });
  }

  test('空账号或密码不覆盖已保存记录', () async {
    final repo = EamsCredentialsRepository();
    await repo.save(
      const EamsCredentials(username: 'test', password: 'secret'),
    );
    await expectLater(
      repo.save(const EamsCredentials(username: ' ', password: 'x')),
      throwsArgumentError,
    );
    await expectLater(
      repo.save(const EamsCredentials(username: 'test', password: '')),
      throwsArgumentError,
    );
    expect((await repo.read())!.password, 'secret');
  });
}
