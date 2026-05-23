import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Сервис Filmix: авто-логин + балансер Kodik
class FilmixAuth {
  static const String filmixLogin = "vakhtovik_player";
  static const String filmixPassword = "ZaqXswCde123";

  static Future<void> injectCookies(
      InAppWebViewController controller, Uri url) async {}

  /// JS для автологина на любом домене Filmix (filmix.ac, filmix.me, filmix.biz и др.)
  static String getInjectionScript() {
    return """
(function() {
  if (!window.location.hostname.includes('filmix')) return;
  if (window.__vakhtovikFilmixLoginStarted) return 'already-started';
  window.__vakhtovikFilmixLoginStarted = true;

  var LOGIN = '""" +
        filmixLogin +
        """';
  var PASS = '""" +
        filmixPassword +
        """';

  function visible(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    var s = window.getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden';
  }

  function setValue(el, value) {
    if (!el) return;
    var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, value);
    ['input','change','keyup','blur'].forEach(function(ev) {
      el.dispatchEvent(new Event(ev,{bubbles:true}));
    });
  }

  // Уже залогинен?
  function loggedIn() {
    var ok = document.querySelector(
    '.user-logged,.profile-link,.cabinet,a[href*=\"profile\"],' +
    '.login-username,.user-name,.user-menu,.header-user,[class*=\"logged\"]'
    );
    return !!ok && !(document.body.innerText || '').match(/Авторизация|Введите свои логин пароль/i);
  }

  function fillAndSubmit() {
    if (loggedIn()) return 'logged';
    var u = document.querySelector('#login_name') || document.querySelector(
      'input[name=\"email\"],input[name=\"login\"],input[type=\"email\"],' +
      'input[name=\"login_name\"],#login_name,input[name=\"username\"],' +
      'input[placeholder*=\"mail\" i],input[placeholder*=\"логин\" i],input[placeholder*=\"Логин\" i]'
    );
    var p = document.querySelector('#login_password') || document.querySelector(
      'input[name=\"password\"],input[name=\"pass\"],input[type=\"password\"],' +
      '#login_password,input[placeholder*=\"пароль\" i]'
    );
    if (!u || !p || !visible(u) || !visible(p)) return false;
    setValue(u, LOGIN);
    setValue(p, PASS);

    document.querySelectorAll('input[type=\"checkbox\"]').forEach(function(cb) {
      var txt = ((cb.closest('label')||cb.parentElement||{}).innerText || '').toLowerCase();
      if (txt.includes('запом') || cb.name.toLowerCase().includes('remember')) cb.checked = true;
    });

    setTimeout(function() {
      var btn = document.querySelector('button.enter') || Array.from(document.querySelectorAll(
        'button[type=\"submit\"],input[type=\"submit\"],.login-submit,' +
        '#login_btn,button.log_btn,form button[class*=\"btn\"],.btn-primary,button,a'
      )).find(function(x) {
        var t = ((x.innerText || x.value || '') + '').trim().toLowerCase();
        return visible(x) && (t === 'войти' || t.includes('войти') || t.includes('login'));
      });
      if (btn) btn.click();
      else { var f = u.closest('form'); if (f) f.submit(); }
    }, 500);
    return true;
  }

  function openLogin() {
    if (loggedIn()) return 'logged';
    var exact = document.querySelector('#auth .open') || document.querySelector('#auth') || document.querySelector('.login.guest');
    if (exact && visible(exact)) { exact.click(); return 'clicked-exact'; }
    // Пробуем открыть форму входа
    var trigger = Array.from(document.querySelectorAll(
      'a[href*=\"login\"],a[href*=\"signin\"],a[href*=\"auth\"],' +
      '.login-btn,.signin-btn,#login-btn,.btn-login,button.login,' +
      '[class*=\"login_btn\"],.header-login,.auth-btn,[data-modal*=\"login\"],' +
      '[data-target*=\"login\"],[data-bs-target*=\"login\"],button,a,span,div'
    )).find(function(x) {
      var t = (x.innerText || x.title || x.getAttribute('aria-label') || '').trim().toLowerCase();
      return visible(x) && (t === 'авторизация' || t.includes('авторизац') || t === 'вход' || t.includes('войти'));
    });
    if (trigger) {
      trigger.click();
      return 'clicked';
    }
    return 'no-trigger';
  }

  var tries = 0;
  var timer = setInterval(function() {
    tries++;
    if (loggedIn()) { clearInterval(timer); return; }
    var filled = fillAndSubmit();
    if (!filled) openLogin();
    if (tries > 40) clearInterval(timer);
  }, 750);

  setTimeout(openLogin, 400);
  return 'filmix-autologin-started';
})();
""";
  }

  static String getCookieExtractorJS() {
    return "(function(){var c=document.cookie;prompt('Cookie:',c);return c;})();";
  }
}
