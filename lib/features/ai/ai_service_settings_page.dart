import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../settings/settings_providers.dart';
import 'ai_settings_keys.dart';

/// 预设服务商模板（URL / 模型均为 OpenAI 兼容端点，可改）。
///
/// 点选后只自动填充 base_url + model，API 密钥留空由用户自行填写。
typedef _ProviderPreset = ({String name, String baseUrl, String model});

const List<_ProviderPreset> _presets = [
  (name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat'),
  (name: '智谱', baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4-flash'),
  (name: '通义', baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus'),
  (name: 'Moonshot', baseUrl: 'https://api.moonshot.cn/v1', model: 'moonshot-v1-8k'),
  (name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', model: 'gpt-4o-mini'),
];

/// AI 服务设置页：读写 `ai.*` 配置键。
///
/// 字段：
/// - 对话 LLM：启用开关 / Base URL / API 密钥（可显隐）/ 模型；
/// - 允许 AI 操作 App：写工具门控开关（S7 才真正启用）；
/// - OCR：模式二选一（llm = 用对话模型视觉 / provider = 专用服务），provider 时输 App Key。
///
/// 交互：
/// - 服务商模板一键填充 base_url + model（key 留空用户填）；
/// - 保存：整页写回并返回；有未保存改动离开时弹确认；
/// - 测试连接：读当前表单临时构造 [LlmClient] ping，成功/失败按类型提示。
class AiServiceSettingsPage extends ConsumerStatefulWidget {
  const AiServiceSettingsPage({super.key});

  @override
  ConsumerState<AiServiceSettingsPage> createState() =>
      _AiServiceSettingsPageState();
}

class _AiServiceSettingsPageState extends ConsumerState<AiServiceSettingsPage> {
  /// 表单控制器。
  final TextEditingController _baseUrlCtl = TextEditingController();
  final TextEditingController _apiKeyCtl = TextEditingController();
  final TextEditingController _modelCtl = TextEditingController();
  final TextEditingController _ocrAppKeyCtl = TextEditingController();

  /// 启用对话模型 / 允许 AI 操作 App 开关。
  bool _llmEnabled = false;
  bool _writeEnabled = false;

  /// OCR 识别模式：'llm'（默认） / 'provider'。
  String _ocrMode = AiSettingsKeys.defaultOcrMode;

  /// API 密钥输入是否遮蔽。
  bool _obscureKey = true;

  /// 是否已加载（DB 不可用时兜底默认值照常渲染）。
  bool _loading = true;

  /// 是否有未保存改动（离开时确认）。
  bool _dirty = false;

  /// 保存 / 测试连接进行中（防重复点）。
  bool _saving = false;
  bool _testing = false;

  /// 测试连接结果：`(文案, 是否成功)`。
  (String, bool)? _testResult;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _baseUrlCtl.dispose();
    _apiKeyCtl.dispose();
    _modelCtl.dispose();
    _ocrAppKeyCtl.dispose();
    super.dispose();
  }

  /// 读取 `ai.*` 键到表单；数据库不可用（如 widget 测试环境）时回退默认值。
  Future<void> _loadSettings() async {
    bool enabled = AiSettingsKeys.defaultLlmEnabled == 'true';
    bool write = AiSettingsKeys.defaultWriteEnabled == 'true';
    String baseUrl = AiSettingsKeys.defaultLlmBaseUrl;
    String apiKey = AiSettingsKeys.defaultLlmApiKey;
    String model = AiSettingsKeys.defaultLlmModel;
    String ocrMode = AiSettingsKeys.defaultOcrMode;
    String appKey = AiSettingsKeys.defaultOcrAppKey;
    try {
      final settings = ref.read(settingsRepositoryProvider);
      enabled = await settings.getValue(AiSettingsKeys.llmEnabled) != 'false';
      write = await settings.getValue(AiSettingsKeys.writeEnabled) == 'true';
      baseUrl = await settings.getValue(AiSettingsKeys.llmBaseUrl) ??
          AiSettingsKeys.defaultLlmBaseUrl;
      apiKey = await settings.getValue(AiSettingsKeys.llmApiKey) ??
          AiSettingsKeys.defaultLlmApiKey;
      model = await settings.getValue(AiSettingsKeys.llmModel) ??
          AiSettingsKeys.defaultLlmModel;
      ocrMode = await settings.getValue(AiSettingsKeys.ocrMode) ??
          AiSettingsKeys.defaultOcrMode;
      appKey = await settings.getValue(AiSettingsKeys.ocrAppKey) ??
          AiSettingsKeys.defaultOcrAppKey;
    } catch (_) {
      // 保持默认值。
    }
    if (!mounted) return;
    setState(() {
      _llmEnabled = enabled;
      _writeEnabled = write;
      _ocrMode = ocrMode;
      _baseUrlCtl.text = baseUrl;
      _apiKeyCtl.text = apiKey;
      _modelCtl.text = model;
      _ocrAppKeyCtl.text = appKey;
      _loading = false;
    });
  }

  // ------------------------------------------------------------ 保存

  /// 整页写回全部 `ai.*` 键并返回。
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsRepositoryProvider).setAll({
        AiSettingsKeys.llmEnabled: _llmEnabled ? 'true' : 'false',
        AiSettingsKeys.llmBaseUrl: _baseUrlCtl.text.trim(),
        AiSettingsKeys.llmApiKey: _apiKeyCtl.text.trim(),
        AiSettingsKeys.llmModel: _modelCtl.text.trim(),
        AiSettingsKeys.writeEnabled: _writeEnabled ? 'true' : 'false',
        AiSettingsKeys.ocrMode: _ocrMode,
        AiSettingsKeys.ocrAppKey: _ocrAppKeyCtl.text.trim(),
      });
      _dirty = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showSnack('保存失败，请重试');
    }
  }

  /// 未保存改动离开确认。
  Future<void> _confirmDiscard() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('放弃修改？'),
          content: const Text('有未保存的 AI 服务配置，离开将丢失这些改动。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('放弃'),
            ),
          ],
        );
      },
    );
    if (discard == true && mounted) {
      _dirty = false;
      Navigator.of(context).pop();
    }
  }

  // ------------------------------------------------------------ 模板

  /// 点选服务商模板：只填 base_url + model，key 留空。
  void _applyPreset(_ProviderPreset preset) {
    if (_baseUrlCtl.text.trim() == preset.baseUrl &&
        _modelCtl.text.trim() == preset.model) {
      return;
    }
    setState(() {
      _baseUrlCtl.text = preset.baseUrl;
      _modelCtl.text = preset.model;
      _dirty = true;
      _testResult = null;
    });
  }

  // ------------------------------------------------------------ 测试连接

  /// 读当前表单临时构造 [LlmClient] ping；结果按 [AiError] 类型友好提示。
  Future<void> _testConnection() async {
    final String baseUrl = _baseUrlCtl.text.trim();
    final String apiKey = _apiKeyCtl.text.trim();
    final String model = _modelCtl.text.trim();
    if (!_llmEnabled) {
      setState(() => _testResult = ('请先启用「对话模型」再测试', false));
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _testResult = ('请先填写 Base URL', false));
      return;
    }
    if (model.isEmpty) {
      setState(() => _testResult = ('请先填写模型名称', false));
      return;
    }
    if (apiKey.isEmpty) {
      _showSnack('未填 API 密钥：多数服务需要密钥鉴权，连接可能失败');
    }

    setState(() {
      _testing = true;
      _testResult = null;
    });
    final LlmClient client = LlmClient(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
    );
    try {
      await client.ping();
      if (!mounted) return;
      setState(() => _testResult = ('连接成功（$model）', true));
    } on AiError catch (e) {
      if (!mounted) return;
      setState(() => _testResult = (_friendlyError(e), false));
    } catch (_) {
      if (!mounted) return;
      setState(() => _testResult = ('连接失败：发生未知错误', false));
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 把 [AiError] 映射为对人类友好的单行提示（区分配置 / 网络 / 鉴权 / 限流等）。
  static String _friendlyError(AiError e) {
    switch (e.kind) {
      case AiErrorKind.config:
        return e.message;
      case AiErrorKind.network:
        return '网络连接失败，请检查网络或 Base URL';
      case AiErrorKind.timeout:
        return '连接超时，请检查网络或 Base URL';
      case AiErrorKind.format:
        return '服务响应格式异常：${e.message}';
      case AiErrorKind.http:
        switch (e.statusCode) {
          case 401:
            return 'API 密钥无效或未授权（401）';
          case 403:
            return '无访问权限（403），请检查密钥';
          case 404:
            return '接口地址不存在（404），请检查 Base URL';
          case 429:
            return '请求过于频繁或额度不足（429），请稍后再试';
          case 503:
            return '服务繁忙或暂时不可用（503），请稍后再试';
          default:
            return '服务端错误 HTTP ${e.statusCode}：${e.message}';
        }
    }
  }

  // ------------------------------------------------------------ 字段联动

  void _markDirty() {
    setState(() {
      _dirty = true;
      _testResult = null; // LLM 配置改动后旧结果作废
    });
  }

  void _setLlmEnabled(bool value) {
    setState(() {
      _llmEnabled = value;
      _dirty = true;
      _testResult = null;
    });
  }

  void _setWriteEnabled(bool value) {
    setState(() {
      _writeEnabled = value;
      _dirty = true;
    });
  }

  void _setOcrMode(String value) {
    if (value == _ocrMode) return;
    setState(() {
      _ocrMode = value;
      _dirty = true;
    });
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI 服务'),
          actions: [
            TextButton(
              onPressed: (_loading || _saving || _testing) ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const _SectionHeader('对话 LLM'),
        SwitchListTile(
          secondary: const Icon(Icons.smart_toy_outlined),
          title: const Text('启用对话模型'),
          subtitle: const Text('开启后 AI 对话使用下方配置的服务'),
          value: _llmEnabled,
          onChanged: _setLlmEnabled,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '服务商模板（点选自动填地址与模型，可再修改）',
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final _ProviderPreset p in _presets)
                ActionChip(
                  label: Text(p.name),
                  onPressed: () => _applyPreset(p),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: _buildField(
            controller: _baseUrlCtl,
            label: 'Base URL',
            hint: 'https://api.deepseek.com/v1',
            keyboardType: TextInputType.url,
            onChanged: (_) => _markDirty(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _buildField(
            controller: _apiKeyCtl,
            label: 'API 密钥',
            hint: 'sk-…（可留空，多数服务需要）',
            obscure: _obscureKey,
            onChanged: (_) => _markDirty(),
            suffix: IconButton(
              icon: Icon(_obscureKey
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              tooltip: _obscureKey ? '显示密钥' : '隐藏密钥',
              onPressed: () => setState(() => _obscureKey = !_obscureKey),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _buildField(
            controller: _modelCtl,
            label: '模型',
            hint: 'deepseek-chat',
            onChanged: (_) => _markDirty(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: (_testing || _saving) ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(_testing ? '测试中…' : '测试连接'),
              ),
            ],
          ),
        ),
        if (_testResult != null) _buildTestResult(theme),
        const _SectionHeader('AI 操作权限'),
        SwitchListTile(
          secondary: const Icon(Icons.build_outlined),
          title: const Text('允许 AI 操作 App'),
          subtitle: const Text('开启后 AI 可代你创建/修改课表与日程（功能逐步开放）'),
          value: _writeEnabled,
          onChanged: _setWriteEnabled,
        ),
        const _SectionHeader('OCR 文字识别'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'llm',
                label: Text('用对话模型'),
                icon: Icon(Icons.image_outlined),
              ),
              ButtonSegment(
                value: 'provider',
                label: Text('专用 OCR 服务'),
                icon: Icon(Icons.document_scanner_outlined),
              ),
            ],
            selected: {_ocrMode},
            onSelectionChanged: (Set<String> sel) => _setOcrMode(sel.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            _ocrMode == 'provider'
                ? '使用专用识别服务，需填写下方 App Key'
                : '使用上面对话模型的视觉能力识别文字（需已配置对话 LLM）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (_ocrMode == 'provider')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _buildField(
              controller: _ocrAppKeyCtl,
              label: 'OCR App Key',
              hint: '专用服务的应用密钥',
              onChanged: (_) => _markDirty(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text(
            '对话内容会发送给你配置的第三方服务，请注意保管密钥。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }

  Widget _buildTestResult(ThemeData theme) {
    final (String message, bool ok) = _testResult!;
    final Color color = ok ? theme.colorScheme.primary : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 18, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }

  /// 统一样式的输入框。
  Widget _buildField({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboardType,
    bool obscure = false,
    Widget? suffix,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: suffix,
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 分组列表标题。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
