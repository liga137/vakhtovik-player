import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Сервис Filmix: куки + балансер Kodik
class FilmixAuth {
  // ========== КУКИ ЕДИНОГО АККАУНТА ==========
  // Олег логинится вручную → копирует строку из alert → вставляет сюда
  static const String filmixCookies = "PLACEHOLDER_COOKIES";

  /// Заливает куки в WebView
  static Future<void> injectCookies(InAppWebViewController controller, Uri url) async {
    if (filmixCookies == "PLACEHOLDER_COOKIES") return;
    final cookieManager = CookieManager.instance();
    final cookies = filmixCookies.split(';');
    for (final cookie in cookies) {
      final trimmed = cookie.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('=');
      if (parts.length >= 2) {
        await cookieManager.setCookie(
          url: WebUri(url.toString()),
          name: parts[0].trim(),
          value: parts.sublist(1).join('=').trim(),
          domain: url.host,
          path: '/',
        );
      }
    }
  }

  /// JS для инъекции на Filmix
  static String getInjectionScript() {
    return """
(function() {
  var host = window.location.hostname;
  if (!host.includes('filmix') && !host.includes('kinogo') && !host.includes('hdrezka')) return;

  var loggedIn = document.querySelector('.user-logged, .profile-link, .cabinet, a[href*="profile"], .login-username, .user-name, .user-menu');

  // АВТО-СЛИВ КУК (один раз после ручного логина)
  if (loggedIn && document.cookie && !sessionStorage.getItem('vakh_cookies_dumped')) {
    sessionStorage.setItem('vakh_cookies_dumped', '1');
    alert('\\u041A\\u0423\\u041A\\u0418 FILMIX (скопируй и пришли Бобру):\\n\\n' + document.cookie);
  }

  if (loggedIn) {
    setTimeout(function() {
      var b = document.querySelectorAll('[class*="register"], [class*="premium"], [class*="restrict"], .reg-block, .paywall');
      for (var i = 0; i < b.length; i++) {
        if (b[i].offsetParent && (b[i].innerText||'').match(/регистрац|недоступ|стране/)) b[i].remove();
      }
    }, 2000);
    return;
  }

  // БАЛАНСЕР KODIK (если не залогинен)
  setTimeout(function() {
    var kpId = '';
    var meta = document.querySelector('meta[property="og:url"]');
    if (meta) { var m = meta.content.match(/\\/(\\d+)[\\/\\-]/); if (m) kpId = m[1]; }
    if (!kpId) {
      var links = document.querySelectorAll('a[href*="kinopoisk"]');
      for (var i = 0; i < links.length; i++) { var m = links[i].href.match(/(\\d+)/); if (m) { kpId = m[1]; break; } }
    }
    if (!kpId) {
      var d = document.querySelector('[data-kp], [data-kp-id], [data-film-id]');
      if (d) kpId = d.getAttribute('data-kp') || d.getAttribute('data-kp-id') || d.getAttribute('data-film-id');
    }
    if (kpId) {
      var div = document.createElement('div');
      div.id = 'vakh-balancer';
      div.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:99999;background:#000;';
      div.innerHTML = '<div style="position:absolute;top:10px;left:10px;color:orange;font:13px sans-serif;z-index:999;background:rgba(0,0,0,0.7);padding:4px 8px;border-radius:4px">\\u041F\\u043B\\u0435\\u0435\\u0440 \\u0412\\u0430\\u0445\\u0442\\u043E\\u0432\\u0438\\u043A\\u0430 \\u2014 Kodik</div><iframe src="https://kodik.info/video/' + kpId + '" style="width:100%;height:100%;border:none" allowfullscreen></iframe>';
      var pa = document.querySelector('.player-area,.video-box,#player,.player,.film-player,[class*="player"],.video-container');
      if (pa) { pa.innerHTML = ''; pa.appendChild(div); }
      else { document.body.innerHTML = ''; document.body.appendChild(div); }
    }
  }, 3000);
})();
""";
  }

  /// JS для извлечения кук вручную (кнопка «Слить куки»)
  static String getCookieExtractorJS() {
    return "(function(){var c=document.cookie;prompt('\\u0421\\u043A\\u043E\\u043F\\u0438\\u0440\\u0443\\u0439 \\u043A\\u0443\\u043A\\u0438 (Ctrl+C):',c);return c;})();";
  }
}
