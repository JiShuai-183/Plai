import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:plai/data/repositories/settings_repository.dart';
import 'package:plai/features/ai/ai_providers.dart';
import 'package:plai/features/ai/ai_service_settings_page.dart';
import 'package:plai/features/ai/ai_settings_keys.dart';
import 'package:plai/features/settings/settings_providers.dart';
import 'package:plai/services/ai/ai_error.dart';
import 'package:plai/services/ai/llm_client.dart';

/// 假 LLM 客户端：只覆写 [listModels]，不发网络。
///
/// 注入一个必定失败的 MockClient，避免真去建 HttpClient。
class FakeModelClient extends LlmClient {
  FakeModelClient({
    required super.baseUrl,
    super.apiKey = '',
    required super.model,
    this.models = const <String>[],
    this.error,
  }) : super(httpClient: MockClient((_) async => http.Response('{}', 500)));

  final List<String> models;
  final AiError? error;

  @override
  Future<List<String>> listModels({Duration? timeout, int maxRetries = 0}) async {
    if (error != null) throw error!;
    return models;
  }
}

/// 内存版设置仓库（本文件专用，沿用仓库内各测试文件各自定义 fake 的惯例）。
class FakeSettingsRepository implements ISettingsRepository {
  FakeSettingsRepository([Map<String, String>? seed])
      : _map = <String, String>{...?seed};

  final Map<String, String> _map;

  @override
  Future<String?> getValue(String key) async => _map[key];

  @override
  Future<void> setValue(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> setAll(Map<String, String> entries) async {
    _map.addAll(entries);
  }

  @override
  Future<Map<String, String>> getAll() async => Map.of(_map);

  @override
  Future<void> remove(String key) async {
    _map.remove(key);
  }
}

/// 建页并注入内存仓库；返回仓库供断言落库结果。
///
/// [client] 非空时同时覆写客户端工厂（模型拉取需要可注入的假 client）。
Future<FakeSettingsRepository> pumpPage(
  WidgetTester tester, {
  Map<String, String>? seed,
  LlmClient? client,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final FakeSettingsRepository repo = FakeSettingsRepository(seed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(repo),
        if (client != null)
          llmClientFactoryProvider.overrideWithValue(
            ({
              required String baseUrl,
              String apiKey = '',
              required String model,
            }) =>
                client,
          ),
      ],
      child: const MaterialApp(home: AiServiceSettingsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// 打桩剪贴板读取（`Clipboard.getData` 在测试宿主是 platform channel）。
void stubClipboard(WidgetTester tester, String? text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': text}
        : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}

/// 按 label 取输入框（labelText 渲染在 TextField 子树内）。
TextField fieldByLabel(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.widgetWithText(TextField, label));

void main() {
  testWidgets('AI 服务页：字段齐全，默认值正常渲染', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 无 DB（宿主测试环境）→ 兜底默认值照常渲染。
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiServiceSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 三个分组与字段。
    expect(find.text('对话 LLM'), findsOneWidget);
    expect(find.text('启用对话模型'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API 密钥'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(find.text('允许 AI 操作 App'), findsOneWidget);
    expect(find.text('OCR 文字识别'), findsOneWidget);

    // 服务商模板芯片齐全。
    for (final String name in ['DeepSeek', '智谱', '通义', 'Moonshot', 'OpenAI']) {
      expect(find.text(name), findsOneWidget);
    }

    // OCR 默认 llm → 不出现 App Key 输入。
    expect(find.text('OCR App Key'), findsNothing);

    // 隐私说明。
    expect(find.text('对话内容会发送给你配置的第三方服务，请注意保管密钥。'), findsOneWidget);
  });

  testWidgets('AI 服务页：模板一键填充 + OCR 切 provider 显示 App Key',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiServiceSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 点 DeepSeek 模板 → 自动填 base_url + model。
    await tester.tap(find.text('DeepSeek'));
    await tester.pump();
    final List<TextField> fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(
      fields.any((TextField f) =>
          f.controller?.text == 'https://api.deepseek.com/v1'),
      isTrue,
      reason: 'Base URL 应被模板填充为 DeepSeek 地址',
    );
    expect(
      fields.any((TextField f) => f.controller?.text == 'deepseek-chat'),
      isTrue,
      reason: '模型应被模板填充为 deepseek-chat',
    );

    // OCR 切到专用服务 → 出现 App Key 输入。
    await tester.tap(find.text('专用 OCR 服务'));
    await tester.pumpAndSettle();
    expect(find.text('OCR App Key'), findsOneWidget);
  });

  testWidgets('AI 服务页：测试连接前置校验提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiServiceSettingsPage())),
    );
    await tester.pumpAndSettle();

    // 默认未启用 → 先提示启用。
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请先启用「对话模型」再测试'), findsOneWidget);

    // 启用后仍未填 Base URL → 提示填地址。
    await tester.tap(find.text('启用对话模型'));
    await tester.pump();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请先填写 Base URL'), findsOneWidget);
  });

  // ------------------------------------------------ 密钥框：只写不读 + 粘贴 + 清除

  testWidgets('AI 服务页：已存密钥不回填输入框，「已配置」走常显 helper',
      (WidgetTester tester) async {
    await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
      AiSettingsKeys.llmApiKey: 'sk-stored-secret',
    });

    // 输入框为空 —— 页面不再持有可回显的密钥。
    expect(fieldByLabel(tester, 'API 密钥').controller?.text, isEmpty);
    expect(find.textContaining('sk-stored-secret'), findsNothing);

    // 关键：「已配置」必须在**未聚焦**时也看得见，故走 helperText 而非 hintText
    //（hintText 只在聚焦且为空时出现，用户不点进输入框就看不到状态）。
    final InputDecoration decoration =
        fieldByLabel(tester, 'API 密钥').decoration!;
    expect(decoration.helperText, 'API 已配置，输入可覆盖');
    expect(find.text('API 已配置，输入可覆盖'), findsOneWidget);

    // 已配置时才出现「清除」。
    expect(find.byTooltip('清除已配置的密钥'), findsOneWidget);
  });

  testWidgets('AI 服务页：未配置密钥时无常显状态说明，「清除」也不出现',
      (WidgetTester tester) async {
    await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
    });

    final InputDecoration decoration =
        fieldByLabel(tester, 'API 密钥').decoration!;
    expect(decoration.helperText, isNull, reason: '未配置时没有状态需要常显');
    expect(decoration.hintText, 'sk-…（可留空，多数服务需要）');
    expect(find.text('sk-…（可留空，多数服务需要）'), findsOneWidget);
    expect(find.byTooltip('清除已配置的密钥'), findsNothing);
  });

  testWidgets('AI 服务页：待清除状态同样走常显 helper',
      (WidgetTester tester) async {
    await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
      AiSettingsKeys.llmApiKey: 'sk-stored-secret',
    });

    await tester.tap(find.byTooltip('清除已配置的密钥'));
    await tester.pumpAndSettle();

    expect(fieldByLabel(tester, 'API 密钥').decoration?.helperText,
        '保存后将清除已配置的密钥');
  });

  testWidgets('AI 服务页：密钥框留空保存 → 已存密钥不被改动',
      (WidgetTester tester) async {
    final FakeSettingsRepository repo = await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
      AiSettingsKeys.llmApiKey: 'sk-stored-secret',
    });

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await repo.getValue(AiSettingsKeys.llmApiKey), 'sk-stored-secret',
        reason: '输入框为空 = 不改动已存值，不能被空串覆盖');
  });

  testWidgets('AI 服务页：一键粘贴填入密钥框，保存后覆盖已存值',
      (WidgetTester tester) async {
    final FakeSettingsRepository repo = await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
      AiSettingsKeys.llmApiKey: 'sk-stored-secret',
    });
    stubClipboard(tester, 'sk-pasted-new');

    // OCR 默认走对话模型，页面上此时只有一个「粘贴」按钮。
    await tester.tap(find.byTooltip('粘贴'));
    await tester.pumpAndSettle();

    expect(fieldByLabel(tester, 'API 密钥').controller?.text, 'sk-pasted-new');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(await repo.getValue(AiSettingsKeys.llmApiKey), 'sk-pasted-new');
  });

  testWidgets('AI 服务页：剪贴板为空时提示且不改动输入框',
      (WidgetTester tester) async {
    await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
    });
    stubClipboard(tester, '   ');

    await tester.tap(find.byTooltip('粘贴'));
    await tester.pumpAndSettle();

    expect(find.text('剪贴板为空'), findsOneWidget);
    expect(fieldByLabel(tester, 'API 密钥').controller?.text, isEmpty);
  });

  testWidgets('AI 服务页：清除密钥在保存时才生效（未保存则保留）',
      (WidgetTester tester) async {
    final FakeSettingsRepository repo = await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
      AiSettingsKeys.llmApiKey: 'sk-stored-secret',
    });

    await tester.tap(find.byTooltip('清除已配置的密钥'));
    await tester.pumpAndSettle();

    // 尚未保存 → 库里仍有，且提示待清除。
    expect(await repo.getValue(AiSettingsKeys.llmApiKey), 'sk-stored-secret',
        reason: '「清除」应与整页保存在一起生效');
    expect(find.text('保存后将清除已配置的密钥'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await repo.getValue(AiSettingsKeys.llmApiKey), isNull);
  });

  testWidgets('AI 服务页：清除后又输入 → 取消待清除，按新值保存',
      (WidgetTester tester) async {
    final FakeSettingsRepository repo = await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
      AiSettingsKeys.llmModel: 'm',
      AiSettingsKeys.llmApiKey: 'sk-stored-secret',
    });

    await tester.tap(find.byTooltip('清除已配置的密钥'));
    await tester.pumpAndSettle();
    expect(find.text('保存后将清除已配置的密钥'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'API 密钥'), 'sk-typed');
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await repo.getValue(AiSettingsKeys.llmApiKey), 'sk-typed');
  });

  // ------------------------------------------------ 模型列表拉取

  testWidgets('AI 服务页：拉取模型 → 弹窗选择 → 写入模型框',
      (WidgetTester tester) async {
    await pumpPage(
      tester,
      seed: <String, String>{
        AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
        AiSettingsKeys.llmModel: 'old-model',
      },
      client: FakeModelClient(
        baseUrl: 'https://api.example.com/v1',
        model: '',
        models: <String>['deepseek-chat', 'deepseek-reasoner'],
      ),
    );

    await tester.tap(find.byTooltip('拉取模型列表'));
    await tester.pumpAndSettle();

    // 弹窗列出全部模型，并标出当前值。
    expect(find.text('选择模型（2）'), findsOneWidget);
    expect(find.text('deepseek-reasoner'), findsOneWidget);

    await tester.tap(find.text('deepseek-reasoner'));
    await tester.pumpAndSettle();

    expect(fieldByLabel(tester, '模型').controller?.text, 'deepseek-reasoner');
  });

  testWidgets('AI 服务页：拉取模型遇 404 → 专门文案（而非通用「检查 Base URL」）',
      (WidgetTester tester) async {
    await pumpPage(
      tester,
      seed: <String, String>{
        AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
        AiSettingsKeys.llmModel: 'm',
      },
      client: FakeModelClient(
        baseUrl: 'https://api.example.com/v1',
        model: 'm',
        error: const AiError(AiErrorKind.http, 'HTTP 404', statusCode: 404),
      ),
    );

    await tester.tap(find.byTooltip('拉取模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('该服务未提供模型列表接口，请手动填写模型名'), findsOneWidget);
    expect(find.text('接口地址不存在（404），请检查 Base URL'), findsNothing);
  });

  testWidgets('AI 服务页：拉取到空列表 → 提示未取到', (WidgetTester tester) async {
    await pumpPage(
      tester,
      seed: <String, String>{
        AiSettingsKeys.llmBaseUrl: 'https://api.example.com/v1',
        AiSettingsKeys.llmModel: 'm',
      },
      client: FakeModelClient(
        baseUrl: 'https://api.example.com/v1',
        model: 'm',
        models: const <String>[],
      ),
    );

    await tester.tap(find.byTooltip('拉取模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('未取到模型列表'), findsOneWidget);
  });

  testWidgets('AI 服务页：未启用 / 未填 Base URL 时拉模型给前置提示',
      (WidgetTester tester) async {
    // 注意：页面把「读不到值」判为启用（`!= 'false'`），故这里显式落库 'false'
    // 才是未启用态（与「DB 不可用」回退默认值的路径不同）。
    await pumpPage(tester, seed: <String, String>{
      AiSettingsKeys.llmEnabled: 'false',
    });

    await tester.tap(find.byTooltip('拉取模型列表'));
    await tester.pumpAndSettle();
    expect(find.text('请先启用「对话模型」'), findsOneWidget);

    // 让第一条 snackbar 走完，否则下一条会排队、不显示。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 启用后仍未填 Base URL。
    await tester.tap(find.text('启用对话模型'));
    await tester.pump();
    await tester.tap(find.byTooltip('拉取模型列表'));
    await tester.pumpAndSettle();
    expect(find.text('请先填写 Base URL'), findsOneWidget);
  });
}
