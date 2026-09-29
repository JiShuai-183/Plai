import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/features/timetable/eams/eams_client.dart';

/// 郑航教务网络层单测。
///
/// 全部**不起真网络**：纯函数直测，端到端流程用 `package:http/testing.dart` 的
/// [MockClient] 假实现。样本结构取自 `docs/教务一键导入-实施计划.md` §2.1–2.3
/// 的实测证据；其中的 salt / `_csrf` 取值已替换为**同形态合成值**（发布前脱敏），
/// 另附一组「每次响应都不同」的合成反例。

/// 登录页下发的 `_csrf` 令牌（**合成值，脱敏**）。真实形态：登录页
/// `<input name="_csrf">` 的 `value`，为 64 位小写 hex（与当轮会话 cookie 绑定，
/// 无凭据意义、令牌早已失效）。
const String _csrfToken = '3ac1f0d24b7e58691f2a3b4c5d6e7f809a1b2c3d4e5f60718293a4b5c6d7e8f9';

/// 登录页里 salt 的声明形态（**合成值，脱敏**）。真实形态：页面脚本
/// `CryptoJS.SHA1('<salt>-' + form['password'].value)`，salt 为 UUID 形 + 尾随
/// `-`（提取逻辑会去掉该连字符）。页面里的 `refreshCaptcha` 是死代码，故当前
/// 登录页**不应**被判定为含验证码。`_csrf` 隐藏域属性顺序 name / type / value、
/// 自闭合，登录 POST 必须回带。
const String _loginPageHtml = '''
<!DOCTYPE html>
<html>
<body>
<form id="loginForm" method="post">
  <input type="text" name="username"/>
  <input type="password" name="password"/>
  <input type="hidden" name="login_from" value="login_from"/>
  <input name="_csrf" type="hidden" value="$_csrfToken"/>
</form>
<script>
  form['password'].value = CryptoJS.SHA1('a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d-' + form['password'].value);
  function refreshCaptcha() { /* 死代码 */ }
</script>
</body>
</html>
''';

/// 旧版 / 学校回滚后的登录页：**无** `_csrf` 隐藏域（兼容路径用）。
const String _loginPageNoCsrfHtml = '''
<!DOCTYPE html>
<html>
<body>
<form id="loginForm" method="post">
  <input type="text" name="username"/>
  <input type="password" name="password"/>
</form>
<script>
  form['password'].value = CryptoJS.SHA1('a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d-' + form['password'].value);
</script>
</body>
</html>
''';

/// 门户首页里课表挂件参数的声明形态（计划书 §2.2 原文，semester.id 取实测 297）。
const String _homeHtml = '''
<script>
bg.page("/eams/courseTableForStd!courseTable.action","");
var _paramstring = 'ignoreHead=1&setting.kind=std&startWeek=&semester.id=297&ids=1234567890';
</script>
''';

/// 课表响应体（结构合法即可，解析正确性由解析层单测负责）。
const String _tableHtml = '''
var table0 = new CourseTable(2026, 70);
var unitCount = 10;
''';

/// 2026-09-28 实测：真实登录页正文里**出现 captcha 相关字样**（JS / 静态串），
/// 但并**没有验证码输入元素**（`<input name="captcha">` 之类）。此处以合成样本
/// 固化「这些字样不得触发验证码异常」，否则正常登录会被误判为需要验证码。
const String _loginPageWithCaptchaStrings = '''
<!DOCTYPE html>
<html>
<body>
<form id="loginForm" method="post">
  <input type="text" name="username"/>
  <input type="password" name="password"/>
  <input type="hidden" name="login_from" value="login_from"/>
</form>
<script src="/eams/js/captcha.js"></script>
<script>
  var captchaEnabled = false;
  function refreshCaptcha() { captchaImg.src = '/eams/captcha.jpg'; }
  form['password'].value = CryptoJS.SHA1('11112222-3333-4444-5555-666677778888-' + form['password'].value);
</script>
</body>
</html>
''';

/// 构造 UTF-8 响应（`http.Response` 默认按 latin1 编码，含中文会抛）。
http.Response _res(
  String body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) =>
    http.Response.bytes(
      utf8.encode(body),
      status,
      headers: <String, String>{
        'content-type': 'text/html; charset=utf-8',
        ...headers,
      },
    );

void main() {
  group('extractSalt（静态纯函数）', () {
    test('命样本片段（salt 原样取出）', () {
      expect(EamsClient.extractSalt(_loginPageHtml),
          'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d');
    });

    test('另一组 salt（证明不写死、每次不同）', () {
      const String page =
          "form['password'].value = CryptoJS.SHA1('54d85fde-0000-1111-2222-333333333333-' + form['password'].value);";
      expect(EamsClient.extractSalt(page),
          '54d85fde-0000-1111-2222-333333333333');
    });

    test('取不到返回 null（页面改版 / 非登录页）', () {
      expect(EamsClient.extractSalt('<html>no salt here</html>'), isNull);
      expect(EamsClient.extractSalt(''), isNull);
      expect(EamsClient.extractSalt(_homeHtml), isNull);
    });
  });

  group('extractCsrfToken（静态纯函数）', () {
    test('命样本：属性顺序 name/type/value → 取到值', () {
      expect(EamsClient.extractCsrfToken(_loginPageHtml), _csrfToken);
    });

    test('属性顺序颠倒（value 在 name 前）→ 仍取到', () {
      const String page =
          '<input type="hidden" value="tok123" name="_csrf"/>';
      expect(EamsClient.extractCsrfToken(page), 'tok123');
    });

    test('单引号属性 → 取到', () {
      const String page =
          "<input name='_csrf' type='hidden' value='tok-abc' />";
      expect(EamsClient.extractCsrfToken(page), 'tok-abc');
    });

    test('其它 input 环绕时只取 _csrf 那个（不吃错值，如 username）', () {
      const String page = '<form>'
          '<input type="text" name="username" value="alice"/>'
          '<input name="_csrf" type="hidden" value="right"/>'
          '<input type="hidden" name="login_from" value="login_from"/>'
          '</form>';
      expect(EamsClient.extractCsrfToken(page), 'right');
    });

    test('页面无该字段 → null（不编造空串）', () {
      expect(EamsClient.extractCsrfToken(_loginPageNoCsrfHtml), isNull);
      expect(EamsClient.extractCsrfToken(_homeHtml), isNull);
      expect(EamsClient.extractCsrfToken(''), isNull);
    });

    test('有 _csrf 但 value 为空 → null', () {
      expect(
          EamsClient.extractCsrfToken(
              '<input name="_csrf" type="hidden" value=""/>'),
          isNull);
      expect(
          EamsClient.extractCsrfToken(
              "<input name='_csrf' type='hidden' value=''/>"),
          isNull);
    });

    test('有 _csrf 但无 value 属性 → null', () {
      expect(
          EamsClient.extractCsrfToken('<input name="_csrf" type="hidden"/>'),
          isNull);
    });

    test('值含 HTML 实体 → 照实取（本家族无 entity decode，不引入新依赖）', () {
      // extract* 家族（extractSalt / extractSemesterId / extractIds）均不 decode
      // 实体，此处保持一致：`&amp;` 原样返回，不做替换。
      expect(
          EamsClient.extractCsrfToken(
              '<input name="_csrf" value="a&amp;b"/>'),
          'a&amp;b');
    });
  });

  group('hashPassword（SHA1(salt-密码)，hex 小写）', () {
    test('已知 salt + 密码 → 固定摘要', () {
      // sha1('abc123-secret')
      expect(EamsClient.hashPassword('abc123', 'secret'),
          'fddd08155da1aa0a8c2754beabc24fc2998433e8');
      // sha1('a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d-123456')
      expect(
        EamsClient.hashPassword('a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d', '123456'),
        '86f6fc0467baa11fbea29750d86e0d4b11278147',
      );
    });

    test('摘要有 40 位且只含小写十六进制', () {
      final String hash = EamsClient.hashPassword('s', 'p');
      expect(hash, hasLength(40));
      expect(hash, matches(RegExp(r'^[0-9a-f]{40}$')));
    });
  });

  group('extractLoginError（actionError 判定）', () {
    test('含 actionError → 精确提取文案（含嵌套标签已剥）', () {
      const String body = '<html><body>'
          '<div class="actionError"><span>账号或密码异常</span></div>'
          '</body></html>';
      expect(EamsClient.extractLoginError(body), '账号或密码异常');
    });

    test('单引号 class 也能识别', () {
      const String body = "<div class='actionError'>账号已锁定</div>";
      expect(EamsClient.extractLoginError(body), '账号已锁定');
    });

    test('无 actionError（登录成功）→ null', () {
      expect(EamsClient.extractLoginError(_loginPageHtml), isNull);
      expect(EamsClient.extractLoginError('<html>ok</html>'), isNull);
    });

    test('actionError 存在但无文字 → 空串（非 null）', () {
      expect(EamsClient.extractLoginError('<div class="actionError"></div>'), '');
    });
  });

  group('looksLikeCaptcha（出现即停，不硬闯）', () {
    test('name="captcha" / id="captcha" 命中', () {
      expect(EamsClient.looksLikeCaptcha(
          '<input type="text" name="captcha" id="captcha"/>'), isTrue);
      expect(EamsClient.looksLikeCaptcha(
          '<input name="j_captcha" type="text"/>'), isTrue);
    });

    test('验证码图片元素（captchaImg）命中', () {
      expect(EamsClient.looksLikeCaptcha('<img id="captchaImg" src="/x.png"/>'),
          isTrue);
    });

    test('普通登录页（refreshCaptcha 是死代码）+ 课表页 不命中', () {
      expect(EamsClient.looksLikeCaptcha(_loginPageHtml), isFalse);
      expect(EamsClient.looksLikeCaptcha(_tableHtml), isFalse);
    });

    test('A4：真实登录页的 captcha 静态串（JS / 死代码）不误伤', () {
      expect(EamsClient.looksLikeCaptcha(_loginPageWithCaptchaStrings), isFalse);
    });
  });

  group('isLoginPage（结构标记判定，纯函数）', () {
    test('登录页样本 → true（id / name 两种写法、大小写不敏感）', () {
      expect(EamsClient.isLoginPage(_loginPageHtml), isTrue);
      expect(EamsClient.isLoginPage(_loginPageWithCaptchaStrings), isTrue);
      expect(EamsClient.isLoginPage('<form name="loginForm" action="/x">'), isTrue);
    });

    test('普通家页样本（最小合成 HTML）→ false', () {
      expect(
        EamsClient.isLoginPage('<html><body><h1>门户首页</h1></body></html>'),
        isFalse,
      );
      expect(EamsClient.isLoginPage(_homeHtml), isFalse);
      expect(EamsClient.isLoginPage(_tableHtml), isFalse);
      expect(EamsClient.isLoginPage(''), isFalse);
    });
  });

  group('extractSemesterId / extractIds（门户首页挂件参数）', () {
    test('命真实样本片段', () {
      expect(EamsClient.extractSemesterId(_homeHtml), '297');
      expect(EamsClient.extractIds(_homeHtml), '1234567890');
    });

    test('取不到返回 null', () {
      expect(EamsClient.extractSemesterId('<html>nope</html>'), isNull);
      expect(EamsClient.extractIds('<html>nope</html>'), isNull);
      // 只有半截（缺 ids）也不认。
      expect(EamsClient.extractSemesterId('semester.id=297'), isNull);
      expect(EamsClient.extractIds('semester.id=297'), isNull);
    });
  });

  group('EamsCookieJar（手写 jar）', () {
    test('多次 Set-Cookie 覆盖同名、忽略属性', () {
      final EamsCookieJar jar = EamsCookieJar();
      jar.absorbSetCookie('JSESSIONID=old; Path=/eams; HttpOnly');
      jar.absorbSetCookie('GSESSIONID=gs; Path=/');
      expect(jar.values, <String, String>{'JSESSIONID': 'old', 'GSESSIONID': 'gs'});

      jar.absorbSetCookie(
          'JSESSIONID=new; Path=/eams; Expires=Tue, 01 Jan 2026 00:00:00 GMT');
      expect(jar.values['JSESSIONID'], 'new');
      expect(jar.headerValue, 'JSESSIONID=new; GSESSIONID=gs');
    });

    test('无 Cookie 时 headerValue 为 null；clear 生效', () {
      final EamsCookieJar jar = EamsCookieJar();
      expect(jar.headerValue, isNull);
      jar.absorbSetCookie('A=b');
      jar.clear();
      expect(jar.headerValue, isNull);
    });

    test('吸收非法串不崩', () {
      final EamsCookieJar jar = EamsCookieJar();
      jar.absorbSetCookie('garbage');
      jar.absorbSetCookie('=noName');
      jar.absorbSetCookie('');
      expect(jar.values, isEmpty);
    });

    test('absorbResponse 走 headersSplitValues（只吃 set-cookie）', () {
      final EamsCookieJar jar = EamsCookieJar();
      jar.absorbResponse(http.Response('x', 200, headers: <String, String>{
        'set-cookie': 'JSESSIONID=abc; Path=/eams',
        'content-type': 'text/html',
      }));
      expect(jar.values, <String, String>{'JSESSIONID': 'abc'});
    });
  });

  group('fetchCourseTableHtml 全流程（MockClient 假客户端）', () {
    late List<http.Request> seen;

    EamsClient build({
      String homeHtml = _homeHtml,
      String loginResponse = '<html>ok</html>',
      String loginPageHtml = _loginPageHtml,
    }) {
      seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request request) async {
        seen.add(request);
        final String path = request.url.path;
        if (path == '/eams/loginExt.action') {
          if (request.method == 'GET') {
            return _res(loginPageHtml, headers: <String, String>{
              'set-cookie': 'JSESSIONID=abc123; Path=/eams',
            });
          }
          return _res(loginResponse);
        }
        if (path == '/eams/homeExt!main.action') {
          return _res(homeHtml, headers: <String, String>{
            'set-cookie': 'GSESSIONID=xyz; Path=/',
          });
        }
        if (path == '/eams/courseTableForStd!courseTable.action') {
          return _res(_tableHtml);
        }
        return _res('not found', status: 404);
      });
      return EamsClient(httpClient: mock, loginFormDwell: Duration.zero);
    }

    test('四步流程顺序正确，返回课表响应体', () async {
      final EamsClient client = build();
      final String body = await client.fetchCourseTableHtml(
          username: '20240001', password: 'SuperSecret!');
      expect(body, _tableHtml);

      expect(seen, hasLength(4));
      expect(seen[0].method, 'GET');
      expect(seen[0].url.path, '/eams/loginExt.action');
      expect(seen[1].method, 'POST');
      expect(seen[1].url.path, '/eams/loginExt.action');
      expect(seen[2].method, 'GET');
      expect(seen[2].url.path, '/eams/homeExt!main.action');
      expect(seen[3].method, 'POST');
      expect(seen[3].url.path, '/eams/courseTableForStd!courseTable.action');
    });

    test('登录 POST 前补足最小停留间隔（防「请不要过快点击」）', () async {
      // 真实等待：间隔设 80ms，断言 GET 与 POST 的实际间隔 ≥ 该值。
      // 实测服务端阈值在 0.3s~0.5s 之间，不等待则登录 100% 被拦。
      seen = <http.Request>[];
      final List<DateTime> at = <DateTime>[];
      final MockClient mock = MockClient((http.Request request) async {
        seen.add(request);
        at.add(DateTime.now());
        final String path = request.url.path;
        if (path == '/eams/loginExt.action') {
          if (request.method == 'GET') {
            return _res(_loginPageHtml, headers: <String, String>{
              'set-cookie': 'JSESSIONID=abc123; Path=/eams',
            });
          }
          return _res('<html>ok</html>');
        }
        if (path == '/eams/homeExt!main.action') return _res(_homeHtml);
        return _res(_tableHtml);
      });
      final EamsClient client = EamsClient(
        httpClient: mock,
        loginFormDwell: const Duration(milliseconds: 80),
      );

      await client.fetchCourseTableHtml(username: 'u', password: 'p');

      final Duration gap = at[1].difference(at[0]);
      // 留 10ms 调度余量，避免 CI 抖动误报。
      expect(gap.inMilliseconds, greaterThanOrEqualTo(70));
    });

    test('服务端回「请不要过快点击」→ 换成人话，不误导为密码错', () async {
      final EamsClient client =
          build(loginResponse: '<div class="actionError">请不要过快点击</div>');

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsLoginException>().having(
            (EamsLoginException e) => e.message, 'message', contains('提交过快'))),
      );
    });

    test('登录 POST 带上 ① 的 Cookie，且密码摘要正确、无明文', () async {
      final EamsClient client = build();
      await client.fetchCourseTableHtml(
          username: '20240001', password: 'SuperSecret!');

      final http.Request loginPost = seen[1];
      expect(loginPost.headers['cookie'], contains('JSESSIONID=abc123'));

      final Map<String, String> form = Uri.splitQueryString(loginPost.body);
      expect(form['username'], '20240001');
      expect(form['needModify'], '0');
      expect(form['session_locale'], 'zh_CN');
      expect(form['login_from'], 'login_from');
      expect(form['submitBtn'], '登录');
      expect(
        form['password'],
        EamsClient.hashPassword('a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d', 'SuperSecret!'),
      );
      expect(loginPost.body, isNot(contains('SuperSecret!')));
    });

    test('登录 POST 回带登录页的 _csrf 令牌，且值与页面一致', () async {
      final EamsClient client = build();
      await client.fetchCourseTableHtml(username: 'u', password: 'p');

      final Map<String, String> form =
          Uri.splitQueryString(seen[1].body);
      expect(form['_csrf'], _csrfToken);
      expect(seen[1].body, contains('_csrf=$_csrfToken'));
      // 与 salt 同源：不额外多发请求（仍是 GET 登录页 + POST 登录两次）。
      expect(seen.where((http.Request r) =>
          r.url.path == '/eams/loginExt.action').length, 2);
    });

    test('登录页无 _csrf → 登录 POST 省略该字段（不出现空值键）', () async {
      final EamsClient client = build(loginPageHtml: _loginPageNoCsrfHtml);
      await client.fetchCourseTableHtml(username: 'u', password: 'p');

      final Map<String, String> form =
          Uri.splitQueryString(seen[1].body);
      expect(form.containsKey('_csrf'), isFalse);
      expect(seen[1].body, isNot(contains('_csrf')));
    });

    test('后续请求带齐两个 Cookie（JSESSIONID + GSESSIONID）', () async {
      final EamsClient client = build();
      await client.fetchCourseTableHtml(username: 'u', password: 'p');
      expect(seen[3].headers['cookie'], 'JSESSIONID=abc123; GSESSIONID=xyz');
    });

    test('课表 POST 的表单字段与实测一致', () async {
      final EamsClient client = build();
      await client.fetchCourseTableHtml(username: 'u', password: 'p');
      final Map<String, String> form = Uri.splitQueryString(seen[3].body);
      expect(form, <String, String>{
        'ignoreHead': '1',
        'setting.kind': 'std',
        'startWeek': '',
        'semester.id': '297',
        'ids': '1234567890',
      });
    });
  });

  group('失败路径（消息用户可读）', () {
    test('登录失败（HTTP 200 + actionError）→ EamsLoginException，且不重试', () async {
      final List<http.Request> seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request request) async {
        seen.add(request);
        if (request.url.path == '/eams/loginExt.action' && request.method == 'GET') {
          return _res(_loginPageHtml);
        }
        return _res('<div class="actionError">账号或密码异常</div>');
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'bad'),
        throwsA(isA<EamsLoginException>()
            .having((EamsLoginException e) => e.message, 'message',
                contains('账号或密码异常'))),
      );
      // 绝不自动重试：只 GET 登录页 + POST 一次，共 2 次请求。
      expect(seen, hasLength(2));
    });

    test('登录页出现验证码 → EamsCaptchaException，不提交登录', () async {
      final List<http.Request> seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request request) async {
        seen.add(request);
        return _res('$_loginPageHtml<input name="captcha"/>');
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsCaptchaException>()
            .having((EamsCaptchaException e) => e.message, 'message',
                contains('验证码'))),
      );
      expect(seen, hasLength(1));
    });

    test('登录页取不到 salt → EamsProtocolException（疑似改版），不提交登录', () async {
      final List<http.Request> seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request request) async {
        seen.add(request);
        return _res('<html>no salt</html>');
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsProtocolException>()
            .having((EamsProtocolException e) => e.message, 'message',
                contains('改版'))),
      );
      expect(seen, hasLength(1));
    });

    test('首页取不到 ids → EamsProtocolException 且说明缺什么', () async {
      final MockClient mock = MockClient((http.Request request) async {
        if (request.url.path == '/eams/loginExt.action') {
          return _res(
              request.method == 'GET' ? _loginPageHtml : '<html>ok</html>');
        }
        return _res('<html>no params</html>');
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);
      addTearDown(client.close);

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsProtocolException>()
            .having((EamsProtocolException e) => e.message, 'message',
                allOf(contains('改版'), contains('ids')))),
      );
    });

    test('A1：HTTP 404（网关罐头页）→ EamsNetworkException，含状态码与指纹，不再说「改版」', () async {
      // 2026-09-28 实测：登录 POST 间歇性撞上前置设备的 404 罐头页，页无 Server 头。
      const String gateway =
          '<html><head><title>Sorry, Page Not Found</title></head>'
          '<body>Sorry, Page Not Found</body></html>';
      final List<http.Request> seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request r) async {
        seen.add(r);
        return _res(gateway, status: 404);
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsNetworkException>().having(
          (EamsNetworkException e) => e.message,
          'message',
          allOf(
            contains('404'),
            contains('Sorry, Page Not Found'), // describePage 指纹（title）
            isNot(contains('疑似教务系统改版')),
          ),
        )),
      );
      // fail-closed：登录页 GET 即撞 404，立即停，不继续 POST。
      expect(seen, hasLength(1));
    });

    test('A3：登录 POST 后首页被退回登录页 → 「登录未生效」+ 指纹，不误报改版', () async {
      final List<http.Request> seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request r) async {
        seen.add(r);
        if (r.url.path == '/eams/loginExt.action') {
          return _res(r.method == 'GET' ? _loginPageHtml : '<html>ok</html>');
        }
        // 会话未登录 → 受保护页被退回登录页。
        return _res(_loginPageHtml);
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);

      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsLoginException>().having(
          (EamsLoginException e) => e.message,
          'message',
          allOf(
            contains('登录未生效'),
            contains('含登录表单'), // describePage 指纹
            isNot(contains('疑似教务系统改版')),
          ),
        )),
      );
      // 停在 home 之后：GET 登录页 + POST 登录 + GET home = 3 次，未继续取参数。
      expect(seen, hasLength(3));
    });

    test('A4：真实登录页的 captcha 静态串不触发 EamsCaptchaException，全流程正常走完', () async {
      final MockClient mock = MockClient((http.Request r) async {
        final String path = r.url.path;
        if (path == '/eams/loginExt.action') {
          return _res(r.method == 'GET'
              ? _loginPageWithCaptchaStrings
              : '<html>ok</html>');
        }
        if (path == '/eams/homeExt!main.action') return _res(_homeHtml);
        return _res(_tableHtml);
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);
      addTearDown(client.close);

      final String body =
          await client.fetchCourseTableHtml(username: 'u', password: 'p');
      expect(body, _tableHtml);
    });

    test('网络异常 → EamsNetworkException', () async {
      final MockClient mock = MockClient((http.Request request) async {
        throw http.ClientException('connection refused');
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);
      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsNetworkException>()),
      );
    });

    test('课表响应为 error.courseTable → EamsProtocolException', () async {
      final MockClient mock = MockClient((http.Request request) async {
        final String path = request.url.path;
        if (path == '/eams/loginExt.action') {
          return _res(
              request.method == 'GET' ? _loginPageHtml : '<html>ok</html>');
        }
        if (path == '/eams/homeExt!main.action') return _res(_homeHtml);
        return _res('<html>error.courseTable.unknown</html>');
      });
      final EamsClient client = EamsClient(httpClient: mock, loginFormDwell: Duration.zero);
      await expectLater(
        client.fetchCourseTableHtml(username: 'u', password: 'p'),
        throwsA(isA<EamsProtocolException>()),
      );
    });

    test('走默认 loginFormDwell（不传该参数）同样可用', () async {
      // 生产里 EamsImportService 就是 `EamsClient()` 无参构造 —— 这条默认值路径
      // 若不覆盖，改动构造默认值时不会被任何测试发现。
      final List<http.Request> seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request r) async {
        seen.add(r);
        if (r.url.path == '/eams/loginExt.action') {
          return r.method == 'GET'
              ? _res(_loginPageHtml, headers: <String, String>{
                  'set-cookie': 'JSESSIONID=abc123; Path=/eams',
                })
              : _res('<html>ok</html>');
        }
        if (r.url.path == '/eams/homeExt!main.action') return _res(_homeHtml);
        return _res(_tableHtml);
      });
      final EamsClient client = EamsClient(httpClient: mock); // 默认 1s 间隔

      final String body =
          await client.fetchCourseTableHtml(username: 'u', password: 'p');

      expect(body, _tableHtml);
      expect(seen, hasLength(4));
    });
  });

  group('学期表：parseSemesterOptions / pickCurrentSemesterId（真机实测数据）', () {
    // 2026-09-20 真机实测 `/eams/dataQuery.action?dataType=semesterCalendar&empty=false`
    // 的响应结构（实测共 53 条，按学年分组 y00…y26；此处保留首尾以示意分组）。
    const String dataQueryBody = 'foo:1,'
        'semesters:{'
        'y00:[{id:43,schoolYear:"2000-2001",name:"1"},'
        '{id:44,schoolYear:"2000-2001",name:"2"}],'
        'y25:[{id:257,schoolYear:"2025-2026",name:"1"},'
        '{id:277,schoolYear:"2025-2026",name:"2"}],'
        'y26:[{id:297,schoolYear:"2026-2027",name:"1"}]},'
        'yearIndex:"-1",termIndex:"-1",semesterId:""}';

    test('解析出全部学期条目（含最后一个学年组）', () {
      final List<EamsSemesterOption> options =
          EamsClient.parseSemesterOptions(dataQueryBody);
      expect(options, hasLength(5));
      expect(options.first, (id: '43', schoolYear: '2000-2001', term: '1'));
      expect(options.last, (id: '297', schoolYear: '2026-2027', term: '1'));
    });

    test('首页文案精确匹配 → 取对应学期 id（真机：2026-2027第1学期 → 297）', () {
      expect(
        EamsClient.pickCurrentSemesterId(
          options: EamsClient.parseSemesterOptions(dataQueryBody),
          homeHtml: '未读消息0条 2026-2027第1学期 第2教学周 2026年09月',
        ),
        '297',
      );
    });

    test('首页显示的是旧学期 → 取旧的那个，而不是最新的', () {
      expect(
        EamsClient.pickCurrentSemesterId(
          options: EamsClient.parseSemesterOptions(dataQueryBody),
          homeHtml: '2025-2026第2学期 第1教学周',
        ),
        '277',
      );
    });

    test('首页没有学期文案 → 退回学年+学期序最大的一条', () {
      expect(
        EamsClient.pickCurrentSemesterId(
          options: EamsClient.parseSemesterOptions(dataQueryBody),
          homeHtml: '<html>无学期文案</html>',
        ),
        '297',
      );
    });

    test('空表 → null；非响应体 → 解析为空', () {
      expect(
        EamsClient.pickCurrentSemesterId(
            options: const <EamsSemesterOption>[], homeHtml: 'x'),
        isNull,
      );
      expect(EamsClient.parseSemesterOptions('<html>nope</html>'), isEmpty);
    });
  });
}

