/// JS для кнопки «Сжать» при наведении на видео YouTube
class YouTubeHover {
  static String getInjectionJS() {
    return r"""
(function() {
  if (document.getElementById('vakh-hover-style')) return;
  
  // Стили
  var style = document.createElement('style');
  style.id = 'vakh-hover-style';
  style.textContent = 
    '#vakh-hover-btn { position:fixed; z-index:2147483646; background:#e53935; color:#fff; padding:6px 14px; border-radius:6px; font:bold 13px sans-serif; cursor:pointer; display:none; white-space:nowrap; box-shadow:0 2px 12px rgba(0,0,0,0.6); user-select:none; letter-spacing:0.5px; }' +
    '#vakh-hover-btn:hover { background:#c62828; transform:scale(1.05); }';
  document.head.appendChild(style);
  
  // Кнопка
  var btn = document.createElement('div');
  btn.id = 'vakh-hover-btn';
  btn.innerHTML = '&#9654; Сжать';
  btn.onclick = function(e) {
    e.preventDefault();
    e.stopPropagation();
    var url = btn.dataset.url;
    if (url) {
      // Навигация — наш shouldOverrideUrlLoading перехватит
      window.location.href = url;
    }
  };
  btn.onmouseover = function() { btn.style.display = 'block'; };
  document.body.appendChild(btn);
  
  // Отслеживаем наведение на любые ссылки с /watch
  var currentUrl = '';
  document.addEventListener('mouseover', function(e) {
    var link = e.target.closest('a[href*="/watch"]');
    if (link && link.href) {
      var href = link.href.split('&')[0]; // чистим от лишних параметров
      if (href !== currentUrl) {
        currentUrl = href;
        btn.dataset.url = href;
        btn.style.display = 'block';
        btn.style.top = Math.min(e.clientY - 40, window.innerHeight - 50) + 'px';
        btn.style.left = Math.min(e.clientX + 15, window.innerWidth - 120) + 'px';
      }
    }
  }, true);
  
  document.addEventListener('mouseout', function(e) {
    var rel = e.relatedTarget;
    if (!rel || (!rel.closest('a[href*="/watch"]') && rel.id !== 'vakh-hover-btn')) {
      setTimeout(function() {
        if (!btn.matches(':hover')) {
          btn.style.display = 'none';
          currentUrl = '';
        }
      }, 200);
    }
  }, true);
  
  // Дополнительно: прячем кнопку при скролле
  window.addEventListener('scroll', function() {
    btn.style.display = 'none';
    currentUrl = '';
  });
})();
""";
  }
}
