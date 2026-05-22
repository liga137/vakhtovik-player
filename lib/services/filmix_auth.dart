import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Сервис Filmix: куки + балансер Kodik
class FilmixAuth {
  // ========== КУКИ ЕДИНОГО АККАУНТА ==========
  // Олег логинится вручную → копирует строку из alert → вставляет сюда
  static const String filmixCookies = "x-a-key=sinatra; minotaurs=7dqlyhWZNBSZDJ1o1a7%2Fp1s%2BtrHicEV2iA51Fb1h8dc%3D; _ga=GA1.1.1747278366.1779404389; _ga_GYLWSWSZ3C=GS2.1.s1779404389\$o1\$g1\$t1779404510\$j60\$l0\$h0";

  /// Инжектит куки через JS (надёжнее чем CookieManager, работает на всех платформах)
  static Future<void> injectCookies(InAppWebViewController controller, Uri url) async {
    if (filmixCookies == "PLACEHOLDER_COOKIES") return;
    // Экранируем кавычки для безопасной вставки в JS
    final safeCookies = filmixCookies.replaceAll("'", "\\'");
    await controller.evaluateJavascript(source: """
      (function(){
        var cookies = '$safeCookies'.split(';');
        for (var i = 0; i < cookies.length; i++) {
          var c = cookies[i].trim();
          if (c) document.cookie = c + '; path=/; domain=.filmix.biz; max-age=31536000';
        }
      })();
    """);
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
