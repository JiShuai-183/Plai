/// AI 模块配置设置键（命名空间 `ai.*`，PRD §8 AIConfig）。
///
/// 存进现有 `setting` 键值表（与 `timetable.*` / `notify.*` 同机制），
/// 本文件集中字面量键名与默认值，供后续 AI 设置页与对话客户端读写；
/// 值统一存字符串（bool 存 'true' / 'false'，数字/枚举存 code）。
///
/// V2 S1 只定义键与默认值契约，不落读取实现。
/// 语音输入不做配置（无对应键）。
abstract final class AiSettingsKeys {
  // ---- 对话 LLM ----

  /// 对话 LLM 总开关（'true' / 'false'，默认关）。
  static const String llmEnabled = 'ai.llm.enabled';

  /// LLM API 地址（Base URL，空串 = 未配置）。
  static const String llmBaseUrl = 'ai.llm.base_url';

  /// LLM API 密钥（空串 = 未配置）。
  static const String llmApiKey = 'ai.llm.api_key';

  /// 对话模型名（如 'gpt-4o' / 'qwen-plus'，空串 = 未配置）。
  static const String llmModel = 'ai.llm.model';

  // ---- AI 操作写工具 ----

  /// 允许 AI 操作 App 写工具开关（'true' / 'false'，默认关）。
  static const String writeEnabled = 'ai.write_enabled';

  // ---- OCR 文字识别 ----

  /// OCR 识别模式（'llm' = 走对话 LLM / 'provider' = 专用识别服务，默认 'llm'）。
  static const String ocrMode = 'ai.ocr.mode';

  /// OCR 专用服务 App Key（ocrMode=provider 时使用，可空）。
  static const String ocrAppKey = 'ai.ocr.app_key';

  // ---- 知情提示 ----

  /// 首次使用知情提示是否已展示（'1' = 已展示，缺省视为未展示）。
  static const String aiOnboarded = 'ai.onboarded';

  // ------------------------------------------------------------ 默认值

  /// 对话 LLM 总开关默认值：关（配置好 base_url/key 后由设置页打开）。
  static const String defaultLlmEnabled = 'false';

  /// LLM API 地址默认值：空串。
  static const String defaultLlmBaseUrl = '';

  /// LLM API 密钥默认值：空串。
  static const String defaultLlmApiKey = '';

  /// 对话模型默认值：空串。
  static const String defaultLlmModel = '';

  /// 写工具开关默认值：关。
  static const String defaultWriteEnabled = 'false';

  /// OCR 模式默认值：llm。
  static const String defaultOcrMode = 'llm';

  /// OCR App Key 默认值：空串。
  static const String defaultOcrAppKey = '';
}
