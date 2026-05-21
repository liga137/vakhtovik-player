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
  // Универсальный скрипт для Filmix и похожих сайтов
  var host = window.location.hostname;
  
  // ===== 1. АВТО-ЛОГИН (если мы на странице входа) =====
  if (host.includes('filmix')) {
    // Проверяем, залогинены ли уже
    var loggedIn = document.querySelector('.user-logged, .profile-link, .cabinet, a[href*="profile"]');
    if (!loggedIn) {
      // Ищем форму логина — пробуем разные селекторы
      var emailField = document.querySelector('input[name="email"], input[name="login"], input[type="email"], input[name="login_name"], #login_name');
      var passField = document.querySelector('input[name="password"], input[name="pass"], input[type="password"], #login_password');
      var submitBtn = document.querySelector('button[type="submit"], input[type="submit"], .login-btn, #login_btn, button.log_btn');
      
      if (emailField && passField) {
        // Заполняем поля единого аккаунта
        emailField.value = 'FILMIX_LOGIN_PLACEHOLDER';
        passField.value = 'FILMIX_PASS_PLACEHOLDER';
        
        // Триггерим события, чтобы сайт понял, что поля заполнены
        emailField.dispatchEvent(new Event('input', { bubbles: true }));
        emailField.dispatchEvent(new Event('change', { bubbles: true }));
        passField.dispatchEvent(new Event('input', { bubbles: true }));
        passField.dispatchEvent(new Event('change', { bubbles: true }));
        
        // Жмём кнопку входа
        if (submitBtn) {
          setTimeout(function() { submitBtn.click(); }, 500);
        } else {
          // Если кнопка не найдена — пробуем сабмитнуть форму
          var form = emailField.closest('form');
          if (form) setTimeout(function() { form.submit(); }, 500);
        }
      }
    }
  }
  
  // ===== 2. ОБХОД ЗАГЛУШКИ «Зарегистрируйтесь для просмотра» =====
  // Если мы уже залогинены, но сайт показывает заглушку — значит
  // страница не обновилась. Пробуем скрыть оверлей.
  setTimeout(function() {
    var blockers = document.querySelectorAll('.reg-block, .need-register, .register-overlay, .paywall, .premium-wall, [class*="register"], [class*="premium"]');
    blockers.forEach(function(el) {
      if (el.offsetParent !== null && (el.innerText || '').includes('регистрац')) {
        el.style.display = 'none';
        el.remove();
      }
    });
    // Снимаем overflow hidden с body (часто блокирует скролл)
    document.body.style.overflow = '';
  }, 2000);
  
  // ===== 3. БАЛАНСЕР: замена плеера на бесплатный Kodik/Vibix =====
  // Если на странице фильма нет нормального плеера — вставляем iframe с балансера
  // (срабатывает, если авторизация не помогла или сайт слишком жадный)
  setTimeout(function() {
    var hasPlayer = document.querySelector('video, iframe[src*="player"], iframe[src*="kodik"], iframe[src*="trailer"], .plyr, [class*="player"], #player');
    if (!hasPlayer) {
      // Пробуем достать Kinopoisk ID или название фильма из DOM
      var kpId = '';
      var metaKp = document.querySelector('meta[itemprop="url"], meta[property="og:url"]');
      if (metaKp) {
        var match = metaKp.content.match(/\\/(\\d+)[\\/-]/);
        if (match) kpId = match[1];
      }
      
      if (kpId) {
        var balancerDiv = document.createElement('div');
        balancerDiv.id = 'vakh-balancer';
        balancerDiv.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:99999;background:#000;';
        balancerDiv.innerHTML = '<iframe src=\"https://kodik.info/video/' + kpId + '\" style=\"width:100%;height:100%;border:none;\" allowfullscreen></iframe>';
        
        // Находим место для вставки — главный контейнер фильма
        var mainArea = document.querySelector('.main, .content, .film-page, #main, article, main') || document.body;
        mainArea.innerHTML = '';
        mainArea.appendChild(balancerDiv);
      }
    }
  }, 3000);
})();
""".replaceAll('FILMIX_LOGIN_PLACEHOLDER', filmixLogin)
    .replaceAll('FILMIX_PASS_PLACEHOLDER', filmixPassword);
  }
}
