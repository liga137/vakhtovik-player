/// Сервис авто-логина на Filmix через единый аккаунт «Плеера Вахтовика»
/// Инжектирует JS в WebView для автоматического входа и замены плеера
class FilmixAuth {
  // ========== ЕДИНЫЙ АККАУНТ ==========
  static const String filmixLogin = "vakhtovik_player";
  static const String filmixPassword = "ZaqXswCde123";

  /// Главный метод: возвращает JS-скрипт для инъекции при загрузке Filmix
  static String getInjectionScript() {
    return """
(function() {
  var host = window.location.hostname;
  var triedLogin = sessionStorage.getItem('vakh_login_tried');
  
  // ===== 1. АВТО-ЛОГИН (с модальным окном) =====
  if (!triedLogin && (host.includes('filmix') || host.includes('kinogo') || host.includes('hdrezka'))) {
    sessionStorage.setItem('vakh_login_tried', '1');
    
    // Проверяем, залогинены ли уже
    var loggedIn = document.querySelector('.user-logged, .profile-link, .cabinet, a[href*="profile"], .login-username, .user-name');
    if (!loggedIn) {
      // Шаг 1: ищем и кликаем кнопку «Войти» чтобы открыть модалку
      setTimeout(function() {
        var loginBtn = document.querySelector('a[href*="login"], a[href*="signin"], .login-btn, .signin-btn, #login-btn, .btn-login, button.login, a[data-modal*="login"], [class*="login_btn"], .header-login, .auth-btn');
        if (loginBtn) {
          loginBtn.click();
          
          // Шаг 2: ждём появления формы в модалке
          setTimeout(function() {
            var emailField = document.querySelector('input[name="email"], input[name="login"], input[type="email"], input[name="login_name"], #login_name, input[name="username"], input[name="user"]');
            var passField = document.querySelector('input[name="password"], input[name="pass"], input[type="password"], #login_password');
            var submitBtn = document.querySelector('button[type="submit"], input[type="submit"], .login-submit, #login_btn, button.log_btn, .modal-login-btn, form button');
            
            if (emailField && passField) {
              // Хитрый ввод: эмулируем поведение пользователя
              emailField.focus();
              emailField.value = 'FILMIX_LOGIN_PLACEHOLDER';
              emailField.dispatchEvent(new Event('input', { bubbles: true }));
              emailField.dispatchEvent(new Event('change', { bubbles: true }));
              emailField.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
              
              passField.focus();
              passField.value = 'FILMIX_PASS_PLACEHOLDER';
              passField.dispatchEvent(new Event('input', { bubbles: true }));
              passField.dispatchEvent(new Event('change', { bubbles: true }));
              passField.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
              
              // Жмём кнопку входа
              setTimeout(function() {
                if (submitBtn) {
                  submitBtn.click();
                } else {
                  var form = emailField.closest('form');
                  if (form) form.submit();
                }
                // Сбрасываем флаг при успехе (чтобы при перезагрузке не дёргало)
                sessionStorage.removeItem('vakh_login_tried');
              }, 800);
            }
          }, 2000); // ждём 2 сек пока модалка откроется
        }
      }, 1500); // ждём 1.5 сек пока страница загрузится
    }
  }
  
  // ===== 2. ОБХОД ЗАГЛУШЕК =====
  setTimeout(function() {
    // Удаляем оверлеи «недоступно в вашей стране» / «зарегистрируйтесь»
    var blockers = document.querySelectorAll('.reg-block, .need-register, .register-overlay, .paywall, .premium-wall, .country-block, .geo-block, [class*="register"], [class*="premium"], [class*="country"], [class*="restrict"]');
    blockers.forEach(function(el) {
      if (el.offsetParent !== null) {
        var txt = (el.innerText || '').toLowerCase();
        if (txt.includes('регистрац') || txt.includes('стране') || txt.includes('доступ') || txt.includes('недоступ')) {
          el.style.display = 'none';
          el.remove();
        }
      }
    });
    document.body.style.overflow = '';
  }, 3000);
  
  // ===== 3. БАЛАНСЕР: подмена плеера на бесплатный Kodik =====
  setTimeout(function() {
    var hasRealPlayer = document.querySelector('video[src], iframe[src*="player"], iframe[src*="kodik"], iframe[src*="trailer"], .plyr video');
    if (!hasRealPlayer) {
      // Ищем KP ID или IMDb ID
      var kpId = '';
      var metaOg = document.querySelector('meta[property="og:url"]');
      if (metaOg) {
        var m = metaOg.content.match(/\/(\d+)[\/\-]/);
        if (m) kpId = m[1];
      }
      // Альтернативный поиск в ссылках
      if (!kpId) {
        var links = document.querySelectorAll('a[href*="kinopoisk"]');
        for (var i = 0; i < links.length; i++) {
          var lm = links[i].href.match(/\/(\d+)\//);
          if (lm) { kpId = lm[1]; break; }
        }
      }
      
      if (kpId) {
        var balancerDiv = document.createElement('div');
        balancerDiv.id = 'vakh-balancer';
        balancerDiv.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:99999;background:#000;';
        balancerDiv.innerHTML = '<div style=\"position:absolute;top:10px;left:10px;color:orange;font:14px sans-serif;z-index:1\">Плеер Вахтовика — балансер Kodik</div><iframe src=\"https://kodik.info/video/' + kpId + '\" style=\"width:100%;height:100%;border:none;\" allowfullscreen></iframe>';
        
        var mainArea = document.querySelector('.main, .content, .film-page, #main, article, main, .container') || document.body;
        // Сохраняем то, что есть, но вставляем перед ним
        mainArea.insertBefore(balancerDiv, mainArea.firstChild);
      }
    }
  }, 4000);
})();
""".replaceAll('FILMIX_LOGIN_PLACEHOLDER', filmixLogin)
    .replaceAll('FILMIX_PASS_PLACEHOLDER', filmixPassword);
  }
}
