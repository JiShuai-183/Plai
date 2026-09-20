import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 郑航教务（Beangle / EAMS 系）**网络层**：登录、会话 Cookie、取课表响应体。
///
/// 与解析层严格分离（见 `docs/教务一键导入-实施计划.md` §4）：本文件只负责把
/// 服务端响应原样取回来，**不做任何解析**。其中所有「串 → 串」的提取逻辑都实现为
/// **静态纯函数**（[extractSalt] / [hashPassword] / [extractLoginError] /
/// [looksLikeCaptcha] / [extractSemesterId] / [extractIds]），可不经网络直接单测。
///
/// 实测流程（§2.1–2.3，**已确证，勿重复验证**）：
///
/// 1. `GET  /eams/loginExt.action` → 取 `Set-Cookie` 与页面里的本轮随机 salt；
/// 2. `POST /eams/loginExt.action` → 复用 ① 的 Cookie（salt 与 session 绑定）；
/// 3. `GET  /eams/homeExt!main.action` → 正则取 `semester.id` / `ids`；
/// 4. `POST /eams/courseTableForStd!courseTable.action` → 响应体即解析层输入。
///
/// **安全约束**（计划书 §1 决策 2 / §8 风险 1、2、4）：
/// - 绝不打印、记录、持久化密码或密码摘要（本文件不出现 `print` / `debugPrint`）；
/// - 绝不自动重试登录（教务系统普遍「密码错 N 次锁号」）；
/// - 检测到验证码输入元素即停并抛 [EamsCaptchaException]，**不硬闯**。
class EamsClient {
  EamsClient({
    http.Client? httpClient,
    this.baseUrl = defaultBaseUrl,
    this.loginFormDwell = defaultLoginFormDwell,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// 教务系统站点（实测 HTTPS 不通，只能明文 HTTP；明文仅对该域名放行）。
  static const String defaultBaseUrl = 'http://jwglxt.zua.edu.cn';

  /// 单次请求超时。
  static const Duration timeout = Duration(seconds: 15);

  /// 登录页 GET 与登录 POST 之间的**最小间隔**（防「请不要过快点击」闸门）。
  ///
  /// 实测（2026-09-20，真服务器 + 假学号，同一 Cookie 会话）：
  ///
  /// | GET→POST 间隔 | 服务端响应 |
  /// |---|---|
  /// | 0s / 0.3s | `请不要过快点击`（被拦） |
  /// | 0.5s / 0.8s / 1s / 2s / 3s / 5s | 正常走登录（回 `账号或密码异常`） |
  ///
  /// 即服务端要求「登录表单必须停留约 0.5s 以上才可提交」的防机器人闸门。
  /// **不等待则登录 100% 失败**，且失败文案会被误认为密码错。
  /// 故取 1s（2 倍余量，且远低于人的感知阈值）。
  /// 该等待**不是**对失败登录的重试，与「绝不自动重试」的约束不冲突。
  static const Duration defaultLoginFormDwell = Duration(seconds: 1);

  final http.Client _http;
  final bool _ownsHttp;

  /// 站点基址（无尾斜杠），可在测试中替换。
  final String baseUrl;

  /// 登录页 GET → 登录 POST 的最小间隔；单元测试传 [Duration.zero] 跳过等待。
  final Duration loginFormDwell;

  /// 走完整套流程，返回课表响应体（`courseTableForStd!courseTable.action` 的
  /// 原始 JS 文本），供解析层 [_parse] 使用。
  ///
  /// 任何一步不符合预期都抛 [EamsException] 家族异常，**绝不静默返回空串**。
  Future<String> fetchCourseTableHtml({
    required String username,
    required String password,
  }) async {
    final EamsCookieJar jar = EamsCookieJar();

    // ① 登录页：拿 Cookie 与本轮 salt。计时用于 ② 的最小停留间隔。
    final Stopwatch dwell = Stopwatch()..start();
    final http.Response loginPage = await _get(jar, '/eams/loginExt.action');
    _throwIfCaptcha(loginPage.body);
    final String? salt = extractSalt(loginPage.body);
    if (salt == null) {
      throw const EamsProtocolException(
        '疑似教务系统改版：登录页里没有找到密码加密盐值（salt）声明'
        '（预期形如 CryptoJS.SHA1(\'<salt>-\' + form[\'password\'].value)）。',
      );
    }

    // ② 提交登录（必须带 ① 的 Cookie，salt 与 session 绑定）。
    //    先补足最小停留间隔 —— 否则服务端回「请不要过快点击」，登录必然失败。
    await _awaitLoginFormDwell(dwell);
    final http.Response login = await _post(jar, '/eams/loginExt.action', <String, String>{
      'username': username,
      'password': hashPassword(salt, password),
      'needModify': '0',
      'session_locale': 'zh_CN',
      'login_from': 'login_from',
      'submitBtn': '登录',
    });
    _throwIfCaptcha(login.body);
    final String? error = extractLoginError(login.body);
    if (error != null) {
      // 「请不要过快点击」：服务端的提交过快闸门（正常路径已由
      // [_awaitLoginFormDwell] 规避）。若仍撞上，说明是**时序**问题而非密码问题，
      // 直接透传会让用户误以为密码错，故换成人话。
      final bool tooFast = error.contains('过快');
      throw EamsLoginException(
        tooFast
            ? '教务系统提示提交过快，请稍等几秒再试一次。'
            : (error.isEmpty ? '登录失败：教务系统未给出原因，请核对学号与密码。' : error),
      );
    }

    // ③ 门户首页：取课表挂件参数。
    final http.Response home = await _get(jar, '/eams/homeExt!main.action');
    _throwIfCaptcha(home.body);
    final String? semesterId = extractSemesterId(home.body);
    final String? ids = extractIds(home.body);
    if (semesterId == null || ids == null) {
      throw EamsProtocolException(
        '疑似教务系统改版：门户首页里没有找到课表挂件参数'
        '（预期形如 semester.id=<学期>&ids=<编号>）。'
        '${semesterId == null ? '【缺 semester.id】' : ''}'
        '${ids == null ? '【缺 ids】' : ''}'
        // 指纹用于分辨两种完全不同的成因：
        // ① 首页真的改版（挂件参数不再服务端直出）；
        // ② 登录其实没生效 —— POST 回的仍是登录页（登录页没有 actionError，
        //    故不会触发上面的失败判定），于是首页也拿回登录页。
        '\n首页响应：${describePage(home.body)}',
      );
    }

    // ④ 课表响应体。注意：不能访问外侧页 /eams/courseTableForStd.action
    //（实测返回 error.courseTable.unknown）。
    final http.Response table =
        await _post(jar, '/eams/courseTableForStd!courseTable.action', <String, String>{
      'ignoreHead': '1',
      'setting.kind': 'std',
      'startWeek': '',
      'semester.id': semesterId,
      'ids': ids,
    });
    _throwIfCaptcha(table.body);
    if (table.body.contains('error.courseTable')) {
      throw const EamsProtocolException(
        '教务系统返回课表错误：可能是课表挂件参数失效或系统改版，请稍后重试。',
      );
    }
    if (table.body.trim().isEmpty) {
      throw const EamsProtocolException('教务系统返回了空的课表响应。');
    }
    return table.body;
  }

  /// 释放内部持有的 [http.Client]（外部注入的客户端由注入方负责关闭）。
  void close() {
    if (_ownsHttp) _http.close();
  }

  // ---- 请求原语 ----

  /// 补足「登录页 GET → 登录 POST」的最小间隔（见 [defaultLoginFormDwell]）。
  ///
  /// 用 [Stopwatch] 计的是**真实耗时**（含 GET 自身的网络往返），因此网络慢时
  /// 自动少等甚至不等。间隔设为 [Duration.zero] 时直接返回（单元测试用）。
  Future<void> _awaitLoginFormDwell(Stopwatch dwell) async {
    final Duration remain = loginFormDwell - dwell.elapsed;
    if (remain > Duration.zero) {
      await Future<void>.delayed(remain);
    }
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<http.Response> _get(EamsCookieJar jar, String path) => _send(
        () => _http.get(_uri(path), headers: _headers(jar)),
        jar,
      );

  Future<http.Response> _post(
    EamsCookieJar jar,
    String path,
    Map<String, String> form,
  ) =>
      _send(
        () => _http.post(
          _uri(path),
          headers: _headers(jar),
          body: form,
        ),
        jar,
      );

  Map<String, String> _headers(EamsCookieJar jar) {
    return <String, String>{
      // 无 Cookie 时整个条目省略（null-aware map entry）。
      'Cookie': ?jar.headerValue,
      'User-Agent': 'Mozilla/5.0 (Plai)',
    };
  }

  Future<http.Response> _send(
    Future<http.Response> Function() run,
    EamsCookieJar jar,
  ) async {
    final http.Response response;
    try {
      response = await run().timeout(timeout);
    } on TimeoutException {
      throw EamsNetworkException('连接教务系统超时（${timeout.inSeconds} 秒），请检查网络后重试。');
    } on IOException catch (e) {
      throw EamsNetworkException('无法连接教务系统：${e.toString()}');
    } on http.ClientException catch (e) {
      throw EamsNetworkException('与教务系统通信失败：${e.message}');
    }
    jar.absorbResponse(response);
    return response;
  }

  void _throwIfCaptcha(String body) {
    if (looksLikeCaptcha(body)) {
      throw const EamsCaptchaException(
        '教务系统要求输入验证码，本应用不代为识别。请先在浏览器登录学校门户确认账号正常，'
        '再稍后重试；若持续出现，请手动导入课表文件。',
      );
    }
  }

  // ---- 静态纯函数（单测直接打这些，不需要起网络） ----

  /// 给一段响应体做**指纹**，用于「拿到的到底是哪个页面」的判断。
  ///
  /// 出问题时把这段附在异常消息里，可一眼分辨「页面改版」还是「登录没生效
  /// 导致被服务端退回登录页」—— 两者都会让后续的字段提取失败，但成因完全不同。
  static String describePage(String html) {
    final RegExpMatch? title = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    final String t = (title?.group(1) ?? '').trim();
    return '${html.length} 字节'
        '${t.isEmpty ? '' : '，title="$t"'}'
        '${html.contains('loginForm') ? '，含登录表单（疑似未登录 / 被退回登录页）' : ''}';
  }

  /// 从登录页 HTML 提取本轮随机 salt（`CryptoJS.SHA1('<salt>-' + …)`）。
  ///
  /// 取不到（页面改版 / 非登录页）返回 null，**绝不编造默认值** —— salt 每次响应
  /// 都不同，写死会让登录必然失败。
  static String? extractSalt(String loginPageHtml) {
    final RegExpMatch? m = _rgxSalt.firstMatch(loginPageHtml);
    if (m == null) return null;
    String salt = m.group(1)!;
    // 页面里的字面量是 `'<salt>-'`（salt 与明文之间由代码补 '-'），去掉尾随连字符。
    if (salt.endsWith('-')) salt = salt.substring(0, salt.length - 1);
    return salt.isEmpty ? null : salt;
  }

  /// `SHA1(salt + '-' + 明文密码)` 的十六进制小写摘要。
  ///
  /// 注意：该摘要**等价于密码**（明文通道可被中间人重放），故本函数结果只在
  /// 登录请求体内使用，绝不落盘、绝不打印。
  static String hashPassword(String salt, String password) =>
      sha1.convert(utf8.encode('$salt-$password')).toString();

  /// 从响应体提取登录失败文案（`<div class="actionError">…</div>`）。
  ///
  /// 无 `actionError`（登录成功）返回 null；元素存在但无文字返回空串。
  static String? extractLoginError(String body) {
    final RegExpMatch? m = _rgxActionError.firstMatch(body);
    if (m == null) return null;
    final String text = _stripTags(m.group(2) ?? '').trim();
    return text;
  }

  /// 响应体是否含验证码输入元素（出现即停，不硬闯）。
  static bool looksLikeCaptcha(String body) => _rgxCaptcha.hasMatch(body);

  /// 从门户首页提取 `semester.id`（形如 `…&semester.id=297&ids=…`）。取不到返回 null。
  static String? extractSemesterId(String homeHtml) =>
      _rgxSemesterIds.firstMatch(homeHtml)?.group(1);

  /// 从门户首页提取 `ids`（形如 `…&semester.id=297&ids=…`）。取不到返回 null。
  static String? extractIds(String homeHtml) =>
      _rgxSemesterIds.firstMatch(homeHtml)?.group(2);

  static String _stripTags(String html) =>
      html.replaceAll(_rgxHtmlTag, '').replaceAll('&nbsp;', ' ');
}

/// 手写 Cookie jar（只有 `JSESSIONID` + `GSESSIONID` 两个，无需引入依赖）。
///
/// 语义（按 RFC 6265 简化）：
/// - 解析 `Set-Cookie`：取首个分号前的 `name=value`（忽略 `Path` / `Expires` 等属性）；
/// - 同名覆盖（后到者胜）；
/// - 发送时以 `name=value; name2=value2` 拼接。
class EamsCookieJar {
  final Map<String, String> _values = <String, String>{};

  /// 当前持有的 Cookie（只读视图，便于测试断言）。
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  /// 吸收一个响应的全部 `Set-Cookie` 头。
  ///
  /// 用 [http.BaseResponse.headersSplitValues] 而非 `headers`：后者会把多个
  /// `Set-Cookie` 用 `, ` 拼成一条，而 Cookie 值里的 `Expires` 日期本身含逗号。
  void absorbResponse(http.BaseResponse response) {
    response.headersSplitValues.forEach((String name, List<String> values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final String raw in values) {
        absorbSetCookie(raw);
      }
    });
  }

  /// 吸收单条 `Set-Cookie` 字符串（`name=value; Path=/; HttpOnly`）。
  void absorbSetCookie(String raw) {
    final int semicolon = raw.indexOf(';');
    final String pair = (semicolon < 0 ? raw : raw.substring(0, semicolon)).trim();
    if (pair.isEmpty) return;
    final int eq = pair.indexOf('=');
    if (eq <= 0) return;
    final String name = pair.substring(0, eq).trim();
    if (name.isEmpty) return;
    _values[name] = pair.substring(eq + 1).trim();
  }

  /// 拼好的 `Cookie` 请求头值；无 Cookie 时为 null。
  String? get headerValue => _values.isEmpty
      ? null
      : _values.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join('; ');

  /// 清空（换会话时用）。
  void clear() => _values.clear();
}

// ---------------------------------------------------------------------------
// 异常体系（消息面向用户，UI 可直接展示）
// ---------------------------------------------------------------------------

/// 教务导入异常基类。
class EamsException implements Exception {
  const EamsException(this.message);

  /// 面向用户的说明文字。
  final String message;

  @override
  String toString() => message;
}

/// 登录被拒（账号或密码异常等，服务端返回的文案由 [message] 承载）。
///
/// 收到本异常**不得自动重试** —— 教务系统普遍「密码错 N 次锁号」。
class EamsLoginException extends EamsException {
  const EamsLoginException(super.message);
}

/// 遇到验证码：只能提示用户，不代为识别、不硬闯。
class EamsCaptchaException extends EamsException {
  const EamsCaptchaException(super.message);
}

/// 网络层问题：超时 / 连不上 / 传输失败。
class EamsNetworkException extends EamsException {
  const EamsNetworkException(super.message);
}

/// 协议层问题：页面结构与预期不符（取不到 salt / ids / 课表等），疑似系统改版。
class EamsProtocolException extends EamsException {
  const EamsProtocolException(super.message);
}

// ---------------------------------------------------------------------------
// 正则
// ---------------------------------------------------------------------------

/// 登录页：`CryptoJS.SHA1('<salt>-' + form['password'].value)`。
///
/// 用 `\x27` / `\x22` 表示引号：Dart 原始字符串里 `\'` 不转义，写引号会截断字符串。
final RegExp _rgxSalt = RegExp(
  r"CryptoJS\.SHA1\(\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]\s*\+\s*form\s*"
  r"\[\s*[\x27\x22][^\x27\x22]*[\x27\x22]\s*\]\s*\.\s*value",
);

/// 登录失败元素：`<div class="actionError">…</div>`（可能含嵌套标签）。
final RegExp _rgxActionError = RegExp(
  r"<([a-zA-Z][\w-]*)\b[^>]*class\s*=\s*[\x22\x27][^\x22\x27]*\bactionError\b"
  r"[^\x22\x27]*[\x22\x27][^>]*>(.*?)</\1>",
  dotAll: true,
);

/// 验证码输入元素：`captcha` / `checkcode` / `validateCode` / `verifyCode` 等常见命名。
final RegExp _rgxCaptcha = RegExp(
  r"<[a-zA-Z][\w-]*\b[^>]*\b(?:name|id)\s*=\s*[\x22\x27]?\s*"
  r"(?:captcha|j_captcha|checkcode|check_code|validatecode|validate_code|"
  r"verifycode|verify_code)",
  caseSensitive: false,
);

/// 门户首页课表挂件参数：`semester.id=<id>&ids=<ids>`。
final RegExp _rgxSemesterIds = RegExp(r'semester\.id=(\d+)&ids=(\d+)');

final RegExp _rgxHtmlTag = RegExp(r'<[^>]*>');
