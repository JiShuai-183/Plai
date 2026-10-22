import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/services/app_update/app_update_service.dart';

/// 2.3.x 真机 bug：清单请求没有超时，冷启动时网络/证书握手未就绪就一直挂着，
/// 启动检查既不弹提示也不报错（「3 秒后什么都没发生」）。
/// 这里锁定「请求挂住必须超时失败」。
void main() {
  test('清单请求挂住时按超时失败，不会无限等待', () async {
    final http.Client client = MockClient((http.Request request) {
      // 永远不返回：模拟连接建立后卡死 / 握手无响应。
      return Completer<http.Response>().future;
    });
    final AppUpdateService service = AppUpdateService(
      client: client,
      versionLoader: () async => '2.3.2',
      platform: AppUpdatePlatform.android,
      manifestTimeout: const Duration(milliseconds: 50),
    );

    final AppUpdateCheckResult result = await service.checkForUpdate();

    expect(result.status, AppUpdateCheckStatus.failed);
    expect(result.message, contains('超时'));
  });

  test('清单响应体卡住（连接后不再来数据）时同样超时失败', () async {
    final http.Client client = MockClient.streaming(
      (http.BaseRequest request, http.ByteStream body) async {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
        );
      },
    );
    final AppUpdateService service = AppUpdateService(
      client: client,
      versionLoader: () async => '2.3.2',
      platform: AppUpdatePlatform.android,
      manifestTimeout: const Duration(milliseconds: 50),
    );

    final AppUpdateCheckResult result = await service.checkForUpdate();

    expect(result.status, AppUpdateCheckStatus.failed);
  });
}
