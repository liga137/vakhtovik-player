import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Сервис Filmix: авто-логин + балансер Kodik
class FilmixAuth {
  static const String filmixLogin = "vakhtovik_player";
  static const String filmixPassword = "ZaqXswCde123";

  /// Инжектит куки через JS (если нужно)
  static Future<void> injectCookies(InAppWebViewController controller, Uri url) async {}

  /// JS для инъекции на Filmix
  static String getInjectionScript() {
    return """
(function() {
  var host = window.location.hostname;
  if (!host.includes('filmix') && !host.includes('kinogo') && !host.includes('hdrezka')) return;

  var loggedIn = document.querySelector('.user-logged,.profile-link,.cabinet,a[href*="profile"],.login-username,.user-name,.user-menu');

  if (!loggedIn) {
    setTimeout(function() {
      var loginTrigger = document.querySelector('a[href*="login"],a[href*="signin"],.login-btn,.signin-btn,#login-btn,.btn-login,button.login,[class*="login_btn"],.header-login,.auth-btn,[data-modal*="login"]');
      if (loginTrigger) {
        loginTrigger.click();
        setTimeout(function() {
          var u = document.querySelector('input[name="email"],input[name="login"],input[type="email"],input[name="login_name"],#login_name,input[name="username"]');
          var p = document.querySelector('input[name="password"],input[name="pass"],input[type="password"],#login_password');
          var s = document.querySelector('button[type="submit"],input[type="submit"],.login-submit,#login_btn,button.log_btn,form button,.btn-primary');
          if (u && p) {
            u.value = '""" + filmixLogin + """';
            p.value = '""" + filmixPassword + """';
            u.dispatchEvent(new Event('input',{bubbles:true}));
            u.dispatchEvent(new Event('change',{bubbles:true}));
            p.dispatchEvent(new Event('input',{bubbles:true}));
            p.dispatchEvent(new Event('change',{bubbles:true}));
            setTimeout(function() {
              if (s) s.click();
              else { var f = u.closest('form'); if (f) f.submit(); }
            }, 500);
          }
        }, 2000);
      }
    }, 1500);
    return;
  }

  setTimeout(function() {
    var b = document.querySelectorAll('[class*="register"],[class*="premium"],[class*="restrict"],.reg-block,.paywall');
    for (var i = 0; i < b.length; i++) {
      if (b[i].offsetParent && (b[i].innerText||'').match(/регистрац|недоступ|стране/)) b[i].remove();
    }
  }, 2000);
})();
""";
  }

  /// JS для кнопки ручного слива кук
  static String getCookieExtractorJS() {
    return "(function(){var c=document.cookie;prompt('Cookie:',c);return c;})();";
  }
}
