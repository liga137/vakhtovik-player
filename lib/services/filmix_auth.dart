import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Сервис Filmix: авто-логин + балансер Kodik
class FilmixAuth {
  static const String filmixLogin = "vakhtovik_player";
  static const String filmixPassword = "ZaqXswCde123";

  static Future<void> injectCookies(InAppWebViewController controller, Uri url) async {}

  /// JS для автологина на любом домене Filmix (filmix.ac, filmix.me, filmix.biz и др.)
  static String getInjectionScript() {
    return """
(function() {
  if (!window.location.hostname.includes('filmix')) return;

  // Уже залогинен?
  var ok = document.querySelector(
    '.user-logged,.profile-link,.cabinet,a[href*=\"profile\"],' +
    '.login-username,.user-name,.user-menu,.header-user,[class*=\"logged\"]'
  );
  if (ok) {
    // Убираем баннеры ограничений
    setTimeout(function() {
      document.querySelectorAll(
        '[class*=\"register\"],[class*=\"premium\"],[class*=\"restrict\"],' +
        '.reg-block,.paywall,[class*=\"paywall\"],[id*=\"paywall\"]'
      ).forEach(function(b) {
        if (b.offsetParent && (b.innerText||'').match(/регистрац|недоступ|стране|подпис/i)) b.remove();
      });
    }, 2000);
    return;
  }

  function fillAndSubmit() {
    var u = document.querySelector(
      'input[name=\"email\"],input[name=\"login\"],input[type=\"email\"],' +
      'input[name=\"login_name\"],#login_name,input[name=\"username\"],' +
      'input[placeholder*=\"mail\" i],input[placeholder*=\"логин\" i]'
    );
    var p = document.querySelector(
      'input[name=\"password\"],input[name=\"pass\"],input[type=\"password\"],' +
      '#login_password,input[placeholder*=\"пароль\" i]'
    );
    if (!u || !p) return false;
    u.value = '""" + filmixLogin + """';
    p.value = '""" + filmixPassword + """';
    ['input','change'].forEach(function(ev) {
      u.dispatchEvent(new Event(ev,{bubbles:true}));
      p.dispatchEvent(new Event(ev,{bubbles:true}));
    });
    setTimeout(function() {
      var btn = document.querySelector(
        'button[type=\"submit\"],input[type=\"submit\"],.login-submit,' +
        '#login_btn,button.log_btn,form button[class*=\"btn\"],.btn-primary'
      );
      if (btn) btn.click();
      else { var f = u.closest('form'); if (f) f.submit(); }
    }, 500);
    return true;
  }

  function tryOpenAndLogin() {
    // Пробуем открыть форму входа
    var trigger = document.querySelector(
      'a[href*=\"login\"],a[href*=\"signin\"],a[href*=\"auth\"],' +
      '.login-btn,.signin-btn,#login-btn,.btn-login,button.login,' +
      '[class*=\"login_btn\"],.header-login,.auth-btn,[data-modal*=\"login\"],' +
      '[data-target*=\"login\"],[data-bs-target*=\"login\"]'
    );
    if (trigger) {
      trigger.click();
      setTimeout(fillAndSubmit, 1500);
    } else {
      fillAndSubmit();
    }
  }

  setTimeout(tryOpenAndLogin, 1500);
})();
""";
  }

  static String getCookieExtractorJS() {
    return "(function(){var c=document.cookie;prompt('Cookie:',c);return c;})();";
  }
}
