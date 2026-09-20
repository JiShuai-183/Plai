import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plai/features/timetable/eams/eams_client.dart';

/// 郑航教务网络层单测。
///
/// 全部**不起真网络**：纯函数直测，端到端流程用 `package:http/testing.dart` 的
/// [MockClient] 假实现。样本片段取自 `docs/教务一键导入-实施计划.md` §2.1–2.3
/// 的实测证据（salt 串为计划书原文，含「每次响应都不同」的另一组反例）。

/// 真实登录页里 salt 的声明形态（计划书 §2.1 原文）。页面里的 `refreshCaptcha`
/// 是死代码，故当前登录页**不应**被判定为含验证码。
const String _loginPageHtml = '''
<!DOCTYPE html>
<html>
<body>
<form id="loginForm" method="post">
  <input type="text" name="username"/>
  <input type="password" name="password"/>
  <input type="hidden" name="login_from" value="login_from"/>
</form>
<script>
  form['password'].value = CryptoJS.SHA1('7ab898f1-fa9e-4c6d-853e-29b5a27aae71-' + form['password'].value);
  function refreshCaptcha() { /* 死代码 */ }
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
    test('命真实样本片段（本轮随机 salt 原样取出）', () {
      expect(EamsClient.extractSalt(_loginPageHtml),
          '7ab898f1-fa9e-4c6d-853e-29b5a27aae71');
    });

    test('另一组实测 salt（证明不写死、每次不同）', () {
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

  group('hashPassword（SHA1(salt-密码)，hex 小写）', () {
    test('已知 salt + 密码 → 固定摘要', () {
      // sha1('abc123-secret')
      expect(EamsClient.hashPassword('abc123', 'secret'),
          'fddd08155da1aa0a8c2754beabc24fc2998433e8');
      // sha1('7ab898f1-fa9e-4c6d-853e-29b5a27aae71-123456')
      expect(
        EamsClient.hashPassword('7ab898f1-fa9e-4c6d-853e-29b5a27aae71', '123456'),
        '98ebba87a60e16ddbca5c73657a24d694bf1ffaa',
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

    EamsClient build({String homeHtml = _homeHtml, String loginResponse = '<html>ok</html>'}) {
      seen = <http.Request>[];
      final MockClient mock = MockClient((http.Request request) async {
        seen.add(request);
        final String path = request.url.path;
        if (path == '/eams/loginExt.action') {
          if (request.method == 'GET') {
            return _res(_loginPageHtml, headers: <String, String>{
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
        EamsClient.hashPassword('7ab898f1-fa9e-4c6d-853e-29b5a27aae71', 'SuperSecret!'),
      );
      expect(loginPost.body, isNot(contains('SuperSecret!')));
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
  });
}
