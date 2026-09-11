import 'package:flutter_test/flutter_test.dart';
import 'package:plai/features/timetable/timetable_settings_keys.dart';

void main() {
  group('电脑端课表缩放', () {
    test('缺省值为 100%，边界限制为 80% 到 150%', () {
      expect(TimetableSettingsKeys.defaultDesktopScale, 1.0);
      expect(TimetableSettingsKeys.normalizeDesktopScale(0.1), 0.8);
      expect(TimetableSettingsKeys.normalizeDesktopScale(2.0), 1.5);
    });

    test('任意输入规整到 10% 档位', () {
      expect(TimetableSettingsKeys.normalizeDesktopScale(1.04), 1.0);
      expect(TimetableSettingsKeys.normalizeDesktopScale(1.06), 1.1);
    });
  });
}
