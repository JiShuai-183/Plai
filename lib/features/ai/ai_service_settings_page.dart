import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../settings/settings_providers.dart';
import 'ai_providers.dart';
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

  /// OCR App Key 输入是否遮蔽。
  bool _obscureOcrKey = true;

  /// 已保存的密钥（**只写不读**）。
  ///
  /// 密钥**永不回填输入框**，页面因此不持有可回显的明文；这两个字段只用于
  /// 展示「已配置」提示、以及测试连接 / 拉取模型时回退取值。
  String _storedApiKey = '';
  String _storedOcrKey = '';

  /// 已请求清除、待保存时执行的密钥设置键。
  ///
  /// 「清除」不立即落库，而是等到整页保存时执行 —— 与页面既有的「改动需保存
  /// + 离开时确认丢弃」语义一致，避免出现「点了清除但没保存、密钥却已没了」。
  /// 在输入框重新输入会取消对应的待清除标记。
  final Set<String> _pendingKeyClear = <String>{};

  /// 是否已加载（DB 不可用时兜底默认值照常渲染）。
  bool _loading = true;

  /// 是否有未保存改动（离开时确认）。
  bool _dirty = false;

  /// 保存 / 测试连接 / 拉取模型列表进行中（防重复点）。
  bool _saving = false;
  bool _testing = false;
  bool _fetchingModels = false;

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
      _modelCtl.text = model;
      // 密钥**只写不读**：读进状态字段备查，绝不回填输入框。
      _storedApiKey = apiKey;
      _storedOcrKey = appKey;
      _apiKeyCtl.clear();
      _ocrAppKeyCtl.clear();
      _pendingKeyClear.clear();
      _loading = false;
    });
  }

  // ------------------------------------------------------------ 保存

  /// 整页写回全部 `ai.*` 键并返回。
  ///
  /// 密钥特殊（只写不读）：输入框为空 = 不改动已存值，故**不写进 map**
  /// （`setAll` 是逐键 upsert，省略即保持原样）；点过「清除」的键在写入后
  /// 执行 `remove`。
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final settings = ref.read(settingsRepositoryProvider);
      final Map<String, String> entries = <String, String>{
        AiSettingsKeys.llmEnabled: _llmEnabled ? 'true' : 'false',
        AiSettingsKeys.llmBaseUrl: _baseUrlCtl.text.trim(),
        AiSettingsKeys.llmModel: _modelCtl.text.trim(),
        AiSettingsKeys.writeEnabled: _writeEnabled ? 'true' : 'false',
        AiSettingsKeys.ocrMode: _ocrMode,
      };
      final String typedApiKey = _apiKeyCtl.text.trim();
      if (typedApiKey.isNotEmpty) {
        entries[AiSettingsKeys.llmApiKey] = typedApiKey;
      }
      final String typedOcrKey = _ocrAppKeyCtl.text.trim();
      if (typedOcrKey.isNotEmpty) {
        entries[AiSettingsKeys.ocrAppKey] = typedOcrKey;
      }
      await settings.setAll(entries);
      for (final String key in _pendingKeyClear) {
        await settings.remove(key);
      }
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
    final String apiKey = _effectiveApiKey; // 密钥框只写不读 → 回退已存那份
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
    final LlmClient client = ref.read(llmClientFactoryProvider)(
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

  // ------------------------------------------------------------ 模型列表

  /// 拉取服务端模型列表并让用户选一个。
  Future<void> _fetchModels() async {
    final String baseUrl = _baseUrlCtl.text.trim();
    if (!_llmEnabled) {
      _showSnack('请先启用「对话模型」');
      return;
    }
    if (baseUrl.isEmpty) {
      _showSnack('请先填写 Base URL');
      return;
    }

    setState(() {
      _fetchingModels = true;
      _testResult = null;
    });
    final LlmClient client = ref.read(llmClientFactoryProvider)(
      baseUrl: baseUrl,
      apiKey: _effectiveApiKey,
      model: _modelCtl.text.trim(),
    );
    try {
      final List<String> models = await client.listModels();
      if (!mounted) return;
      // 列表已到手就先收掉转圈，再弹选择：转圈是无限动画，留着会让页面在整个
      // 选择过程中一直「在动」（也会让 widget 测试的 pumpAndSettle 永远不收敛）。
      setState(() => _fetchingModels = false);
      if (models.isEmpty) {
        _showSnack('未取到模型列表');
        return;
      }
      final String? picked = await _pickModel(models);
      if (!mounted || picked == null) return;
      setState(() {
        _modelCtl.text = picked;
        _modelCtl.selection = TextSelection.collapsed(offset: picked.length);
        _dirty = true;
        _testResult = null;
      });
    } on AiError catch (e) {
      if (!mounted) return;
      // 404 在「拉模型」语境下几乎都是该服务没实现 /models，
      // 通用 404 文案（检查 Base URL）会把人带偏。
      _showSnack(e.statusCode == 404
          ? '该服务未提供模型列表接口，请手动填写模型名'
          : _friendlyError(e));
    } catch (_) {
      if (!mounted) return;
      _showSnack('拉取模型失败：发生未知错误');
    } finally {
      client.close();
      // 正常路径已在拿到列表时收过转圈，这里兜失败分支。
      if (mounted && _fetchingModels) setState(() => _fetchingModels = false);
    }
  }

  /// 模型选择弹窗（底部弹窗：模型可能上百条，比居中对话框好滚）。
  Future<String?> _pickModel(List<String> models) {
    final String current = _modelCtl.text.trim();
    final ThemeData theme = Theme.of(context);
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.55,
          ),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '选择模型（${models.length}）',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              for (final String model in models)
                ListTile(
                  title: Text(model),
                  trailing:
                      model == current ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(sheetContext).pop(model),
                ),
            ],
          ),
        ),
      ),
    );
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

  // ------------------------------------------------------------ 密钥输入辅助

  /// 实际用于测试连接 / 拉取模型的 API 密钥。
  ///
  /// 密钥框只写不读，用户不重输时输入框是空的 —— 此时必须回退到已保存的
  /// 那份，否则会拿空密钥去请求、必然 401。
  String get _effectiveApiKey {
    final String typed = _apiKeyCtl.text.trim();
    if (typed.isNotEmpty) return typed;
    if (_pendingKeyClear.contains(AiSettingsKeys.llmApiKey)) return '';
    return _storedApiKey;
  }

  /// 密钥输入框的两处文案，按「待清除 / 已配置 / 未配置」三态给出。
  ///
  /// - [helper]：**常显**在输入框下方。状态类信息必须走这里 —— `hintText`
  ///   只在「聚焦且为空」时出现，用户不点进输入框就看不到「已配置」；
  /// - [hint]：聚焦且为空时显示在框内，给操作动作提示。
  ({String? helper, String hint}) _keyTexts({
    required String settingKey,
    required String stored,
    required String configuredHelper,
    required String emptyHint,
  }) {
    if (_pendingKeyClear.contains(settingKey)) {
      return (
        helper: '保存后将清除已配置的密钥',
        hint: '输入或粘贴新密钥可取消清除',
      );
    }
    if (stored.isNotEmpty) {
      return (
        helper: configuredHelper,
        hint: '输入或粘贴新密钥可覆盖',
      );
    }
    return (helper: null, hint: emptyHint);
  }

  /// 「清除」按钮是否显示：已配置，且不在待清除状态。
  bool _canClearKey(String settingKey, String stored) =>
      stored.isNotEmpty && !_pendingKeyClear.contains(settingKey);

  /// 一键粘贴剪贴板文本到 [ctl]（覆盖式）。
  Future<void> _pasteInto(
    TextEditingController ctl, {
    required String settingKey,
  }) async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final String text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      _showSnack('剪贴板为空');
      return;
    }
    setState(() {
      ctl.text = text;
      ctl.selection = TextSelection.collapsed(offset: text.length);
      _pendingKeyClear.remove(settingKey); // 重新输入即取消待清除
      _dirty = true;
      _testResult = null;
    });
  }

  /// 密钥框被手动输入：撤销「待清除」标记。
  ///
  /// 注意：以编程方式赋 `controller.text`（粘贴路径）**不会**触发 `onChanged`，
  /// 那条路径在 [_pasteInto] 里自行撤销。
  void _onKeyTyped(String settingKey) {
    setState(() {
      _pendingKeyClear.remove(settingKey);
      _dirty = true;
      _testResult = null;
    });
  }

  /// 请求清除已配置的密钥：不立即落库，标记后等整页保存时执行。
  void _requestClearKey(TextEditingController ctl, String settingKey) {
    setState(() {
      ctl.clear();
      _pendingKeyClear.add(settingKey);
      _dirty = true;
      _testResult = null;
    });
  }

  /// 密钥输入框后缀：粘贴 + 显隐（+ 已配置时的清除）。
  Widget _keySuffix({
    required TextEditingController ctl,
    required String settingKey,
    required String stored,
    required bool obscure,
    required VoidCallback onToggleObscure,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.content_paste),
          tooltip: '粘贴',
          visualDensity: VisualDensity.compact,
          onPressed: () => _pasteInto(ctl, settingKey: settingKey),
        ),
        IconButton(
          icon: Icon(obscure
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined),
          tooltip: obscure ? '显示密钥' : '隐藏密钥',
          visualDensity: VisualDensity.compact,
          onPressed: onToggleObscure,
        ),
        if (_canClearKey(settingKey, stored))
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清除已配置的密钥',
            visualDensity: VisualDensity.compact,
            onPressed: () => _requestClearKey(ctl, settingKey),
          ),
      ],
    );
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
    final ({String? helper, String hint}) apiKeyTexts = _keyTexts(
      settingKey: AiSettingsKeys.llmApiKey,
      stored: _storedApiKey,
      configuredHelper: 'API 已配置，输入可覆盖',
      emptyHint: 'sk-…（可留空，多数服务需要）',
    );
    final ({String? helper, String hint}) ocrKeyTexts = _keyTexts(
      settingKey: AiSettingsKeys.ocrAppKey,
      stored: _storedOcrKey,
      configuredHelper: 'App Key 已配置，输入可覆盖',
      emptyHint: '专用服务的应用密钥',
    );
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
            hint: apiKeyTexts.hint,
            helper: apiKeyTexts.helper,
            obscure: _obscureKey,
            onChanged: (_) => _onKeyTyped(AiSettingsKeys.llmApiKey),
            suffix: _keySuffix(
              ctl: _apiKeyCtl,
              settingKey: AiSettingsKeys.llmApiKey,
              stored: _storedApiKey,
              obscure: _obscureKey,
              onToggleObscure: () =>
                  setState(() => _obscureKey = !_obscureKey),
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
            suffix: IconButton(
              icon: _fetchingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              tooltip: '拉取模型列表',
              visualDensity: VisualDensity.compact,
              onPressed: (_fetchingModels || _saving) ? null : _fetchModels,
            ),
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
              hint: ocrKeyTexts.hint,
              helper: ocrKeyTexts.helper,
              obscure: _obscureOcrKey,
              onChanged: (_) => _onKeyTyped(AiSettingsKeys.ocrAppKey),
              suffix: _keySuffix(
                ctl: _ocrAppKeyCtl,
                settingKey: AiSettingsKeys.ocrAppKey,
                stored: _storedOcrKey,
                obscure: _obscureOcrKey,
                onToggleObscure: () =>
                    setState(() => _obscureOcrKey = !_obscureOcrKey),
              ),
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
    String? helper,
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
        helperText: helper,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: suffix,
        // 密钥行后缀是「粘贴 / 显隐 / 清除」多个图标，默认 48dp 最小尺寸会
        // 把输入区挤没；放开最小约束，由各 IconButton 的 compact 密度决定。
        suffixIconConstraints: suffix == null
            ? null
            : const BoxConstraints(minWidth: 0, minHeight: 0),
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
