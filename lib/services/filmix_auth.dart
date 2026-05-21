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
  if (!host.includes('filmix') && !host.includes('kinogo') && !host.includes('hdrezka')) return;
  
  // ===== 1. ПРОВЕРЯЕМ, ЗАЛОГИНЕН ЛИ УЖЕ =====
  var loggedIn = document.querySelector('.user-logged, .profile-link, .cabinet, a[href*="profile"], .login-username, .user-name, .user-menu');
  
  if (loggedIn) {
    // Уже залогинен — просто сносим возможные оверлеи-заглушки
    setTimeout(function() {
      var blockers = document.querySelectorAll('[class*="register"], [class*="premium"], [class*="restrict"], .reg-block, .paywall');
      blockers.forEach(function(el) {
        if (el.offsetParent && (el.innerText||'').match(/регистрац|недоступ|стране/)) {
          el.remove();
        }
      });
    }, 2000);
    return;
  }
  
  // ===== 2. НЕ ЗАЛОГИНЕН — СРАЗУ СТАВИМ БАЛАНСЕР =====
  // Капчу не пройдём, поэтому логин только вручную (один раз).
  // А пока — подменяем плеер на бесплатный Kodik.
  
  setTimeout(function() {
    var kpId = '';
    // Ищем KP ID в meta-тегах
    var metaOg = document.querySelector('meta[property="og:url"]');
    if (metaOg) {
      var m = metaOg.content.match(/\/(\d+)[\/\-]/);
      if (m) kpId = m[1];
    }
    // Ищем в ссылках на Кинопоиск
    if (!kpId) {
      var links = document.querySelectorAll('a[href*="kinopoisk"], a[href*="kp_id"]');
      for (var i = 0; i < links.length; i++) {
        var lm = links[i].href.match(/(\d+)/);
        if (lm) { kpId = lm[1]; break; }
      }
    }
    // Ищем в data-атрибутах
    if (!kpId) {
      var dataKp = document.querySelector('[data-kp], [data-kp-id], [data-film-id]');
      if (dataKp) kpId = dataKp.getAttribute('data-kp') || dataKp.getAttribute('data-kp-id') || dataKp.getAttribute('data-film-id');
    }
    
    if (kpId) {
      var balancerDiv = document.createElement('div');
      balancerDiv.id = 'vakh-balancer';
      balancerDiv.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:99999;background:#000;';
      balancerDiv.innerHTML = '<div style="position:absolute;top:10px;left:10px;color:orange;font:13px sans-serif;z-index:999;background:rgba(0,0,0,0.7);padding:4px 8px;border-radius:4px">Плеер Вахтовика — Kodik</div><iframe src="https://kodik.info/video/' + kpId + '" style="width:100%;height:100%;border:none;" allowfullscreen></iframe>';
      
      // Находим контейнер с плеером и заменяем его
      var playerArea = document.querySelector('.player-area, .video-box, #player, .player, .film-player, [class*="player"], .video-container');
      if (playerArea) {
        playerArea.innerHTML = '';
        playerArea.appendChild(balancerDiv);
      } else {
        document.body.innerHTML = '';
        document.body.appendChild(balancerDiv);
      }
    }
  }, 3000);
})();
""";
  }
}
