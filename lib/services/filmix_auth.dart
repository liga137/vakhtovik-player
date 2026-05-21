/// Сервис авто-логина на Filmix через преднастроенные куки
/// + балансер Kodik как запасной вариант
class FilmixAuth {
  // ========== КУКИ ЕДИНОГО АККАУНТА ==========
  // Олег логинится вручную один раз → жмёт кнопку «Слить куки» → вставляет строку сюда
  // Формат: "key1=value1; key2=value2; ..."
  static const String filmixCookies = "PLACEHOLDER_COOKIES";

  /// Инжектит куки в WebView через CookieManager
  static Future<void> injectCookies(InAppWebViewController controller, Uri url) async {
    if (filmixCookies == "PLACEHOLDER_COOKIES") return; // куки ещё не прописаны
    
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

  /// JS для извлечения кук (Олег копирует и вставляет сюда)
  static String getCookieExtractorJS() {
    return "(function() { var c = document.cookie; prompt('Скопируй куки (Ctrl+C):', c); return c; })();";
  }

  /// JS для инъекции: проверка логина + автослив кук + обход заглушек + балансер Kodik
  static String getInjectionScript() {
    return """
(function() {
  var host = window.location.hostname;
  if (!host.includes('filmix') && !host.includes('kinogo') && !host.includes('hdrezka')) return;
  
  // Проверяем, залогинены ли
  var loggedIn = document.querySelector('.user-logged, .profile-link, .cabinet, a[href*="profile"], .login-username, .user-name, .user-menu');
  
  // ===== АВТО-СЛИВ КУК (если залогинены и куки ещё не слиты) =====
  if (loggedIn && document.cookie && !sessionStorage.getItem('vakh_cookies_dumped')) {
    sessionStorage.setItem('vakh_cookies_dumped', '1');
    var c = document.cookie;
    // Показываем alert чтобы Олег скопировал
    alert('КУКИ FILMIX (скопируй и пришли Бобру):\\n\\n' + c);
    // Дубль в консоль
    console.log('VAKH_COOKIES:', c);
  }
  
  if (loggedIn) {
    // Всё ок, сносим оверлеи
    setTimeout(function() {
      var blockers = document.querySelectorAll('[class*="register"], [class*="premium"], [class*="restrict"], .reg-block, .paywall');
      blockers.forEach(function(el) {
        if (el.offsetParent && (el.innerText||'').match(/регистрац|недоступ|стране/)) el.remove();
      });
    }, 2000);
    return;
  }
  
  // Кук нет — включаем балансер Kodik
  setTimeout(function() {
    var kpId = '';
    var metaOg = document.querySelector('meta[property="og:url"]');
    if (metaOg) { var m = metaOg.content.match(/\/(\d+)[\/\-]/); if (m) kpId = m[1]; }
    if (!kpId) {
      var links = document.querySelectorAll('a[href*="kinopoisk"], a[href*="kp_id"]');
      for (var i = 0; i < links.length; i++) { var lm = links[i].href.match(/(\d+)/); if (lm) { kpId = lm[1]; break; } }
    }
    if (!kpId) {
      var dataKp = document.querySelector('[data-kp], [data-kp-id], [data-film-id]');
      if (dataKp) kpId = dataKp.getAttribute('data-kp') || dataKp.getAttribute('data-kp-id') || dataKp.getAttribute('data-film-id');
    }
    
    if (kpId) {
      var balancerDiv = document.createElement('div');
      balancerDiv.id = 'vakh-balancer';
      balancerDiv.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;z-index:99999;background:#000;';
      balancerDiv.innerHTML = '<div style="position:absolute;top:10px;left:10px;color:orange;font:13px sans-serif;z-index:999;background:rgba(0,0,0,0.7);padding:4px 8px;border-radius:4px">Плеер Вахтовика — Kodik</div><iframe src="https://kodik.info/video/' + kpId + '" style="width:100%;height:100%;border:none;" allowfullscreen></iframe>';
      var playerArea = document.querySelector('.player-area, .video-box, #player, .player, .film-player, [class*="player"], .video-container');
      if (playerArea) { playerArea.innerHTML = ''; playerArea.appendChild(balancerDiv); }
      else { document.body.innerHTML = ''; document.body.appendChild(balancerDiv); }
    }
  }, 3000);
})();
""";
  }
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
