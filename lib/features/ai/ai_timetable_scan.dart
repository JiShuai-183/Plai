import 'dart:convert';

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ai/ai_error.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/models/ai_message.dart';

/// S9：AI 课表识别（拍照/相册 → 视觉模型结构化 → 课程草稿）。
///
/// 走「对话模型视觉」模式（ai.ocr.mode='llm'）；一次调用 jsonMode 输出
/// 课程数组，再交给 create_course 写工具的确认面板核对落库。
/// 专用 OCR 服务（mode='provider'）的具体服务商协议未定，暂不实现。

/// 识别提示词（要求只输出 JSON）。
const String _scanSystemPrompt =
    '你是课表识别助手。从用户给的课表图片/文字中提取全部课程，'
    '只输出一个 JSON 对象，不要输出任何其他文字：\n'
    '{"courses":[{"name":"课程名","weekday":1,"start_period":1,'
    '"end_period":2,"start_week":1,"end_week":16,'
    '"week_type":"every","location":"教室","teacher":"教师"}]}\n'
    '字段说明：weekday 1=周一…7=周日；start_period/end_period 为起始/结束节次'
    '（整数）；start_week/end_week 为开始/结束周，未知用 1 和 20；'
    'week_type 取 every/odd/even/custom（单双周用 odd/even）；'
    'location/teacher 未知用空字符串。表格里有多少门课就输出多少条，不要遗漏。';

/// 对一张课表图片执行识别，返回可直接喂给 create_course 确认面板的
/// 课程参数列表（已补默认周次/类型、过滤无效条目）。
///
/// [totalWeeks]：当前学期总周数（识别缺省 end_week 时兜底）。
Future<List<Map<String, dynamic>>> scanTimetableFromImage(
  WidgetRef ref, {
  required String imagePath,
  required String baseUrl,
  String apiKey = '',
  required String model,
  int totalWeeks = 20,
}) async {
  final File file = File(imagePath);
  if (!file.existsSync()) {
    throw const AiError(AiErrorKind.config, '图片文件不存在');
  }
  final List<int> bytes = file.readAsBytesSync();
  if (bytes.length > 8 * 1024 * 1024) {
    throw const AiError(AiErrorKind.config, '图片过大（超过 8MB），请重拍或裁剪');
  }
  final String base64 = base64Encode(bytes);

  final LlmClient client = LlmClient(
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
  );
  try {
    final LlmChatResult result = await client.chat(
      temperature: 0,
      jsonMode: true,
      timeout: const Duration(seconds: 90),
      messages: <AiMessage>[
        AiMessage.system(_scanSystemPrompt),
        AiMessage.userImages(
          text: '识别这张课表图片中的全部课程。',
          images: <AiImagePart>[AiImagePart.data(
            base64: base64,
            mime: 'image/jpeg',
          )],
        ),
      ],
    );
    final List<Map<String, dynamic>> raw =
        parseCoursesFromOcrJson(result.content ?? '');
    return normalizeCourseDrafts(raw, totalWeeks: totalWeeks);
  } finally {
    client.close();
  }
}

/// 从模型输出解析课程数组（宽容：剥 markdown 代码块、取首个 JSON 对象）。
List<Map<String, dynamic>> parseCoursesFromOcrJson(String raw) {
  String text = raw.trim();
  // 剥 ```json ... ``` 包裹。
  if (text.startsWith('```')) {
    text = text.replaceFirst(RegExp(r'^```(json)?\s*'), '')
        .replaceFirst(RegExp(r'```\s*$'), '')
        .trim();
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const <Map<String, dynamic>>[];
  }
  final Object? courses =
      decoded is Map ? decoded['courses'] : null;
  if (courses is! List) return const <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[
    for (final Object? e in courses)
      if (e is Map) e.cast<String, dynamic>(),
  ];
}

/// 草稿清洗：数字字段归一、缺失周次/类型兜底、无效条目丢弃。
List<Map<String, dynamic>> normalizeCourseDrafts(
  List<Map<String, dynamic>> raw, {
  required int totalWeeks,
}) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final Map<String, dynamic> m in raw) {
    final String name = (m['name'] as String?)?.trim() ?? '';
    final int? weekday = (m['weekday'] is num)
        ? (m['weekday'] as num).toInt()
        : int.tryParse('${m['weekday']}');
    final int? startPeriod = _toInt(m['start_period']);
    final int? endPeriodRaw = _toInt(m['end_period']);
    if (name.isEmpty ||
        weekday == null ||
        weekday < 1 ||
        weekday > 7 ||
        startPeriod == null ||
        startPeriod < 1) {
      continue; // 无效条目丢弃（面板不会显示）。
    }
    final int endPeriod = (endPeriodRaw != null && endPeriodRaw >= startPeriod)
        ? endPeriodRaw
        : startPeriod;
    out.add(<String, dynamic>{
      'name': name,
      'weekday': weekday,
      'start_period': startPeriod,
      'end_period': endPeriod,
      'start_week': _toInt(m['start_week']) ?? 1,
      'end_week': _clampWeek(_toInt(m['end_week']) ?? totalWeeks, totalWeeks),
      'week_type': _normalizeWeekType(m['week_type']),
      if (m['week_list'] is List && (m['week_list'] as List).isNotEmpty)
        'week_list': <int>[
          for (final Object? e in m['week_list'] as List)
            if (e is num && e >= 1) e.toInt(),
        ],
      'location': (m['location'] as String?)?.trim() ?? '',
      'teacher': (m['teacher'] as String?)?.trim() ?? '',
    });
  }
  return out;
}

int? _toInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

int _clampWeek(int week, int totalWeeks) => week.clamp(1, totalWeeks);

String _normalizeWeekType(Object? v) {
  final String s = (v as String?)?.trim().toLowerCase() ?? '';
  switch (s) {
    case 'odd':
    case '单':
    case '单周':
      return 'odd';
    case 'even':
    case '双':
    case '双周':
      return 'even';
    case 'custom':
      return 'custom';
    default:
      return 'every';
  }
}
