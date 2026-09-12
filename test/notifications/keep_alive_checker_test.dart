import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/services/notifications/keep_alive_checker.dart';

/// 内存版 ISettingsRepository（测试注入）。
class _FakeSettings implements ISettingsRepository {
  _FakeSettings([Map<String, String>? seed]) : _map = <String, String>{...?seed};

  final Map<String, String> _map;

  @override
  Future<String?> getValue(String key) async => _map[key];

  @override
  Future<void> setValue(String key, String value) async => _map[key] = value;

  @override
  Future<void> setAll(Map<String, String> entries) async => _map.addAll(entries);

  @override
  Future<Map<String, String>> getAll() async => Map<String, String>.of(_map);

  @override
  Future<void> remove(String key) async => _map.remove(key);
}

/// 构造一个检测器；[respond] 为 null 时通道调用一律抛异常。
KeepAliveChecker makeChecker({
  Object? Function(String method)? respond,
  ISettingsRepository? settings,
}) {
  return KeepAliveChecker(
    settings: settings ?? _FakeSettings(),
    channelCaller: (String method, Map<String, Object?> args) async {
      if (respond == null) throw PlatformException(code: 'boom');
      return respond(method);
    },
  );
}

void main() {
  group('KeepAliveBrand.fromManufacturer', () {
    test('小米 / 红米 / POCO → xiaomi', () {
      expect(KeepAliveBrand.fromManufacturer('Xiaomi'),
          KeepAliveBrand.xiaomi);
      expect(KeepAliveBrand.fromManufacturer('Redmi'), KeepAliveBrand.xiaomi);
      expect(KeepAliveBrand.fromManufacturer('POCO'), KeepAliveBrand.xiaomi);
    });

    test('华为 → huawei；荣耀 / hihonor → honor', () {
      expect(KeepAliveBrand.fromManufacturer('HUAWEI'), KeepAliveBrand.huawei);
      expect(KeepAliveBrand.fromManufacturer('HONOR'), KeepAliveBrand.honor);
      expect(KeepAliveBrand.fromManufacturer('Hihonor'), KeepAliveBrand.honor);
    });

    test('OPPO / 一加 / realme → oppo', () {
      expect(KeepAliveBrand.fromManufacturer('OPPO'), KeepAliveBrand.oppo);
      expect(KeepAliveBrand.fromManufacturer('OnePlus'), KeepAliveBrand.oppo);
      expect(KeepAliveBrand.fromManufacturer('realme'), KeepAliveBrand.oppo);
    });

    test('vivo / iQOO → vivo', () {
      expect(KeepAliveBrand.fromManufacturer('vivo'), KeepAliveBrand.vivo);
      expect(KeepAliveBrand.fromManufacturer('iQOO'), KeepAliveBrand.vivo);
    });

    test('大小写不敏感、含空白也可识别', () {
      expect(KeepAliveBrand.fromManufacturer('  Xiaomi  '),
          KeepAliveBrand.xiaomi);
    });

    test('未知厂商 / 空串 → generic', () {
      expect(KeepAliveBrand.fromManufacturer('samsung'), KeepAliveBrand.generic);
      expect(KeepAliveBrand.fromManufacturer(''), KeepAliveBrand.generic);
      expect(KeepAliveBrand.fromManufacturer('   '), KeepAliveBrand.generic);
    });

    test('needsAutoStart：generic 为 false，其余为 true', () {
      for (final KeepAliveBrand brand in KeepAliveBrand.values) {
        expect(
          brand.needsAutoStart,
          brand != KeepAliveBrand.generic,
          reason: '${brand.name} needsAutoStart 不符',
        );
      }
    });
  });

  group('collectChecks 品牌 → 项目集合', () {
    test('xiaomi：自启动 + 电池优化 + 通知 + 精确闹钟', () async {
      final items = await makeChecker(respond: (m) => switch (m) {
            'checkAutoStart' => 'allowed',
            'checkBatteryOptimization' => true,
            _ => null,
          }).collectChecks(KeepAliveBrand.xiaomi);
      expect(items.map((e) => e.id).toList(), <String>[
        'auto_start',
        'battery_optimization',
        'notification',
        'exact_alarm',
      ]);
      expect(items.first.state, KeepAliveCheckState.ok);
      expect(items[1].state, KeepAliveCheckState.ok);
      // 仅自启动项允许手动确认。
      expect(items.where((e) => e.manualConfirmable).map((e) => e.id),
          <String>['auto_start']);
    });

    test('generic：不含自启动', () async {
      final items = await makeChecker(respond: (m) => switch (m) {
            'checkBatteryOptimization' => true,
            _ => null,
          }).collectChecks(KeepAliveBrand.generic);
      expect(items.map((e) => e.id).toList(), <String>[
        'battery_optimization',
        'notification',
        'exact_alarm',
      ]);
      expect(items.any((e) => e.id == 'auto_start'), isFalse);
    });
  });

  group('三态合并', () {
    test('通道抛异常 → 全部 unknown，绝不抛', () async {
      final items = await makeChecker().collectChecks(KeepAliveBrand.xiaomi);
      final autoStart = items.firstWhere((e) => e.id == 'auto_start');
      final battery = items.firstWhere((e) => e.id == 'battery_optimization');
      expect(autoStart.state, KeepAliveCheckState.unknown);
      expect(battery.state, KeepAliveCheckState.unknown);
    });

    test('checkAutoStart：只有 allowed 才 ok，denied 为 notOk，其余 unknown',
        () async {
      Future<KeepAliveCheckState> stateOf(Object? raw) async {
        final items = await makeChecker(respond: (m) => raw)
            .collectChecks(KeepAliveBrand.xiaomi);
        return items.firstWhere((e) => e.id == 'auto_start').state;
      }

      expect(await stateOf('allowed'), KeepAliveCheckState.ok);
      expect(await stateOf('denied'), KeepAliveCheckState.notOk);
      // 未知字面量 / 类型不对 → 一律 unknown，不给假 ✓。
      expect(await stateOf('garbage'), KeepAliveCheckState.unknown);
      expect(await stateOf(10008), KeepAliveCheckState.unknown);
      expect(await stateOf(null), KeepAliveCheckState.unknown);
    });

    test('checkBatteryOptimization：true→ok、false→notOk、非 bool→unknown',
        () async {
      Future<KeepAliveCheckState> stateOf(Object? raw) async {
        final items = await makeChecker(respond: (m) => raw)
            .collectChecks(KeepAliveBrand.xiaomi);
        return items
            .firstWhere((e) => e.id == 'battery_optimization')
            .state;
      }

      expect(await stateOf(true), KeepAliveCheckState.ok);
      expect(await stateOf(false), KeepAliveCheckState.notOk);
      expect(await stateOf('true'), KeepAliveCheckState.unknown);
    });
  });

  group('openSettings', () {
    test('opened → true；failed / 抛异常 → false', () async {
      expect(
        await makeChecker(respond: (m) => 'opened').openSettings('autostart'),
        isTrue,
      );
      expect(
        await makeChecker(respond: (m) => 'failed').openSettings('autostart'),
        isFalse,
      );
      expect(await makeChecker().openSettings('battery'), isFalse);
    });
  });

  group('手动确认键', () {
    test('写读为 true/false', () async {
      final settings = _FakeSettings();
      final checker = makeChecker(settings: settings);
      expect(await checker.readManualConfirm('auto_start'), isFalse);
      await checker.writeManualConfirm('auto_start', true);
      expect(await checker.readManualConfirm('auto_start'), isTrue);
      await checker.writeManualConfirm('auto_start', false);
      expect(await checker.readManualConfirm('auto_start'), isFalse);
      // 键名带前缀。
      expect(
        await settings.getValue(
          '${KeepAliveChecker.manualConfirmPrefix}auto_start',
        ),
        'false',
      );
    });

    test('clearManualConfirms 只清手动确认键，不动其他设置', () async {
      final settings = _FakeSettings(<String, String>{
        'notify.keepalive_confirmed.auto_start': 'true',
        'notify.keepalive_brand': 'xiaomi',
        'notify.enabled': 'true',
      });
      await makeChecker(settings: settings).clearManualConfirms();
      final all = await settings.getAll();
      expect(
        all.containsKey('notify.keepalive_confirmed.auto_start'),
        isFalse,
      );
      expect(all['notify.keepalive_brand'], 'xiaomi');
      expect(all['notify.enabled'], 'true');
    });
  });

  group('品牌选择持久化', () {
    test('未存过 → null；写入后可读回', () async {
      final checker = makeChecker(settings: _FakeSettings());
      expect(await checker.readSelectedBrand(), isNull);
      await checker.writeSelectedBrand(KeepAliveBrand.honor);
      expect(await checker.readSelectedBrand(), KeepAliveBrand.honor);
    });

    test('存量是脏值 → 返回 null 而不崩', () async {
      final checker = makeChecker(
        settings: _FakeSettings(<String, String>{
          KeepAliveChecker.brandKey: '不是品牌',
        }),
      );
      expect(await checker.readSelectedBrand(), isNull);
    });
  });
}
