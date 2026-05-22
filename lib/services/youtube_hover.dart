/// JS для YouTube: ховер-кнопка + режим «Сжатое»
class YouTubeHover {
  static String getInjectionJS() {
    return """
(function() {
  if (document.getElementById('vakh-yt-style')) return;
  
  var style = document.createElement('style');
  style.id = 'vakh-yt-style';
  style.textContent = 
    '#vakh-hover-btn{position:fixed;z-index:2147483646;background:#e53935;color:#fff;padding:6px 14px;border-radius:6px;font:bold 13px sans-serif;cursor:pointer;display:none;white-space:nowrap;box-shadow:0 2px 12px rgba(0,0,0,0.6);user-select:none}' +
    '#vakh-hover-btn:hover{background:#c62828;transform:scale(1.05)}' +
    '.vakh-btn{display:inline-block;background:#e53935;color:#fff;padding:3px 10px;border-radius:4px;font:bold 11px sans-serif;cursor:pointer;margin-left:6px;white-space:nowrap;box-shadow:0 1px 3px rgba(0,0,0,0.4)}' +
    '.vakh-btn:hover{background:#c62828}';
  document.head.appendChild(style);
  
  // Ховер-кнопка
  var hoverBtn = document.createElement('div');
  hoverBtn.id = 'vakh-hover-btn';
  hoverBtn.innerHTML = '&#9654; Cжать';
  hoverBtn.onclick = function(e) {
    e.preventDefault(); e.stopPropagation();
    var url = hoverBtn.dataset.url;
    if (url && window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('compressUrl', url);
    }
  };
  hoverBtn.onmouseover = function() { hoverBtn.style.display = 'block'; };
  document.body.appendChild(hoverBtn);
  
  var curUrl = '';
  document.addEventListener('mouseover', function(e) {
    var link = e.target.closest('a[href*="/watch"]');
    if (link && link.href) {
      var href = link.href.split('&')[0];
      if (href !== curUrl) {
        curUrl = href;
        hoverBtn.dataset.url = href;
        hoverBtn.style.display = 'block';
        hoverBtn.style.top = Math.min(e.clientY - 40, window.innerHeight - 50) + 'px';
        hoverBtn.style.left = Math.min(e.clientX + 15, window.innerWidth - 120) + 'px';
      }
    }
  }, true);
  
  document.addEventListener('mouseout', function(e) {
    var rel = e.relatedTarget;
    if (!rel || (!rel.closest('a[href*="/watch"]') && rel.id !== 'vakh-hover-btn')) {
      setTimeout(function() {
        if (!hoverBtn.matches(':hover')) { hoverBtn.style.display = 'none'; curUrl = ''; }
      }, 200);
    }
  }, true);
  
  window.addEventListener('scroll', function() { hoverBtn.style.display = 'none'; curUrl = ''; });
  
  // Функция переключения режима «Сжатое» (вызывается из Dart)
  window.vakhCompressMode = function(on) {
    if (on) {
      var links = document.querySelectorAll('a[href*="/watch"]:not([href*="list="]):not([href*="&list="])');
      for (var i = 0; i < links.length; i++) {
        if (links[i].querySelector('.vakh-btn')) continue;
        var btn = document.createElement('span');
        btn.className = 'vakh-btn';
        btn.textContent = '\\u25B6 Cжать';
        (function(link) {
          btn.addEventListener('click', function(e) {
            e.preventDefault(); e.stopPropagation();
            if (window.flutter_inappwebview) {
              window.flutter_inappwebview.callHandler('compressUrl', link.href.split('&')[0]);
            }
          });
        })(links[i]);
        links[i].style.position = 'relative';
        links[i].appendChild(btn);
      }
    } else {
      var btns = document.querySelectorAll('.vakh-btn');
      for (var j = 0; j < btns.length; j++) btns[j].remove();
    }
  };
})();
""";
  }
}
