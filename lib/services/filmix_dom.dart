/// JS для Filmix: сбор сезонов/серий в т.ч. из iframe + перехват media URL
class FilmixDom {
  static String getInjectionJS() {
    return r'''
(function() {
  if (!window.location.hostname.includes('filmix')) return 'skip-host';

  function normText(t) {
    return (t || '').replace(/\s+/g, ' ').trim();
  }

  function safeCall(handler, payload) {
    try {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler(handler, payload);
      }
    } catch (_) {}
  }

  function mediaLike(url) {
    if (!url) return false;
    var u = String(url).toLowerCase();
    if (u.includes('blob:')) return false;
    if (u.includes('trailer') || u.includes('preview') || u.includes('poster') || u.includes('thumb')) return false;
    return /\.m3u8|\.mp4|\.mkv|\.webm|\.mpd|\/hls\/|master\.m3u8|playlist\.m3u8|manifest|googlevideo|kodik|videocdn|\/stream\/|\/vod\/|\/video\//i.test(u);
  }

  function emitMedia(url) {
    if (!mediaLike(url)) return;
    var clean = String(url).split('#')[0];
    if (window.__vakhLastFilmixMedia === clean) return;
    window.__vakhLastFilmixMedia = clean;
    safeCall('filmixMediaUrl', clean);
  }

  function emitMediaFromElement(el) {
    if (!el) return;
    try {
      var current = el.currentSrc || '';
      if (current) emitMedia(current);
    } catch (_) {}
    try {
      var src = el.src || (el.getAttribute && el.getAttribute('src')) || '';
      if (src) emitMedia(src);
    } catch (_) {}
    try {
      var ds = (el.getAttribute && el.getAttribute('data-src')) || (el.dataset && el.dataset.src) || '';
      if (ds) emitMedia(ds);
    } catch (_) {}
  }

  function extractMediaFromText(text) {
    if (!text || text.length < 10) return;
    var re = /(https?:\/\/[^\s"'<>\\]+(?:\.m3u8|\.mp4|\.mkv|master\.m3u8|playlist\.m3u8)[^\s"'<>\\]*)/ig;
    var m;
    while ((m = re.exec(text)) !== null) {
      emitMedia(m[1]);
    }
  }

  function parseSeasonEpisodeFromText(text) {
    var t = normText(text);
    var season = '';
    var episode = '';
    var sxey = t.match(/(\d{1,2})\s*[xх]\s*(\d{1,3})/i);
    if (sxey) {
      season = sxey[1];
      episode = sxey[2];
    }
    var sm = t.match(/(?:сезон|season)\s*(\d{1,2})/i) || t.match(/(\d{1,2})\s*(?:сезон|season)/i);
    var em = t.match(/(?:серия|эпизод|episode|ep)\s*(\d{1,3})/i) || t.match(/(\d{1,3})\s*(?:серия|эпизод|episode|ep)/i);
    if (!season && sm) season = sm[1];
    if (!episode && em) episode = em[1];
    return { season: String(season || ''), episode: String(episode || '') };
  }

  function parseSeasonEpisodeFromUrl(url) {
    try {
      var u = new URL(url, window.location.href);
      var season = u.searchParams.get('season') || u.searchParams.get('s') || u.searchParams.get('num_season') || '';
      var episode = u.searchParams.get('episode') || u.searchParams.get('e') || u.searchParams.get('num_episode') || '';

      if (!season || !episode) {
        var path = u.pathname || '';
        var tvPath = path.match(/\/tv\/[^\/]+\/(\d{1,2})\/(\d{1,3})(?:\/|$)/i);
        if (tvPath) {
          season = season || tvPath[1];
          episode = episode || tvPath[2];
        }
      }

      if (!season) {
        var sm = (u.pathname || '').match(/season[\/=_-]?(\d{1,2})/i);
        if (sm) season = sm[1];
      }
      if (!episode) {
        var em = (u.pathname || '').match(/episode[\/=_-]?(\d{1,3})/i);
        if (em) episode = em[1];
      }

      return { season: String(season || ''), episode: String(episode || '') };
    } catch (_) {
      return { season: '', episode: '' };
    }
  }

  function visible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    var w = (el.ownerDocument && el.ownerDocument.defaultView) || window;
    var r = el.getBoundingClientRect();
    var s = w.getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden';
  }

  function getAllDocuments() {
    var docs = [document];
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      var fr = frames[i];
      var src = fr.src || fr.getAttribute('src') || '';
      if (src) emitMedia(src);
      try {
        var d = fr.contentDocument;
        if (d && d.documentElement) docs.push(d);
      } catch (_) {
        // cross-origin iframe: доступ к DOM закрыт, остаётся postMessage/src
      }
    }
    return docs;
  }

  function readSeasonAndEpisode(el, text) {
    var season = '';
    var episode = '';
    if (el.getAttribute) {
      season = el.getAttribute('data-season') || el.getAttribute('data-sid') || el.getAttribute('data-num-season') || '';
      episode = el.getAttribute('data-episode') || el.getAttribute('data-eid') || el.getAttribute('data-num-episode') || '';
    }
    if (!season && el.dataset) season = el.dataset.season || el.dataset.sid || el.dataset.numSeason || '';
    if (!episode && el.dataset) episode = el.dataset.episode || el.dataset.eid || el.dataset.numEpisode || '';

    if (!season) {
      var p = el.closest ? el.closest('[data-season],[class*="season"]') : null;
      if (p) {
        season = (p.getAttribute && (p.getAttribute('data-season') || p.getAttribute('data-sid'))) || '';
      }
    }

    var parsed = parseSeasonEpisodeFromText(text);
    if (!season) season = parsed.season;
    if (!episode) episode = parsed.episode;

    return { season: String(season || ''), episode: String(episode || '') };
  }

  var EPISODE_SELECTORS = [
    '[data-season][data-episode]',
    '[data-episode]',
    '.episodes li', '.episode-list li', '.serial-episodes li',
    '.serial-series li', '.playlist li', '.series li',
    '.season-list li', '.seasons li',
    'pjsdiv [data-season][data-episode]', 'pjsdiv [data-episode]', 'pjsdiv li',
    '.pjsdiv [data-season][data-episode]', '.pjsdiv [data-episode]', '.pjsdiv li',
    '.b-simple_episode__item', '.b-simple_episode__link',
    '.b-simple_season__item', '.b-simple_season__link',
    '.serial__episodes li', '.serial__seasons li',
    '[class*="episode"]', '[class*="season"]'
  ];

  function addEpisode(out, seen, title, season, episode) {
    var t = normText(title);
    var s = String(season || '');
    var e = String(episode || '');
    if (!t && !s && !e) return;
    var key = [s, e, t.toLowerCase()].join('|');
    if (seen[key]) return;
    seen[key] = true;
    out.push({ title: t || ('Серия ' + (e || '?')), season: s, episode: e });
  }

  function collectEpisodesFromDoc(doc, out, seen) {
    for (var i = 0; i < EPISODE_SELECTORS.length; i++) {
      var found = [];
      try { found = doc.querySelectorAll(EPISODE_SELECTORS[i]); } catch (_) { found = []; }
      for (var j = 0; j < found.length; j++) {
        var el = found[j];
        if (!visible(el)) continue;
        var text = normText(el.textContent);
        if (!text || text.length > 120) continue;
        var looksLikeEpisode = /серия|эпизод|episode|\bep\b|\d+\s*[xх]\s*\d+/i.test(text);
        var looksLikeSeason = /сезон|season/i.test(text);
        var meta = readSeasonAndEpisode(el, text);
        if (!looksLikeEpisode && !looksLikeSeason && !meta.episode && !meta.season) continue;
        addEpisode(out, seen, text, meta.season, meta.episode);
      }
    }
  }

  function collectEpisodesFromIframeSrc(out, seen) {
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      var src = frames[i].src || frames[i].getAttribute('src') || '';
      if (!src) continue;
      var meta = parseSeasonEpisodeFromUrl(src);
      if (!meta.season && !meta.episode) continue;
      addEpisode(out, seen, 'iframe S' + (meta.season || '?') + ' E' + (meta.episode || '?'), meta.season, meta.episode);
    }
  }

  function sortEpisodes(list) {
    list.sort(function(a, b) {
      var sa = parseInt(a.season || '0', 10);
      var sb = parseInt(b.season || '0', 10);
      if (sa !== sb) return sa - sb;
      var ea = parseInt(a.episode || '0', 10);
      var eb = parseInt(b.episode || '0', 10);
      if (ea !== eb) return ea - eb;
      return (a.title || '').localeCompare(b.title || '');
    });
  }

  function collectEpisodes() {
    var out = [];
    var seen = {};
    var docs = getAllDocuments();
    for (var i = 0; i < docs.length; i++) {
      collectEpisodesFromDoc(docs[i], out, seen);
    }
    collectEpisodesFromIframeSrc(out, seen);
    sortEpisodes(out);
    safeCall('filmixEpisodes', JSON.stringify(out.slice(0, 250)));
    return out.length;
  }

  function emitEpisodesFromPlaylist(playlist) {
    if (!playlist || typeof playlist !== 'object') return 0;
    var out = [];
    var seen = {};

    function pushEpisode(season, episode, translation, title) {
      var s = String(season || '');
      var e = String(episode || '');
      var t = normText(title || '');
      var tr = normText(translation || '');
      if (!s && !e && !t) return;
      if (!t) t = 'S' + (s || '?') + ' E' + (e || '?');
      if (tr) t = t + ' [' + tr + ']';
      addEpisode(out, seen, t, s, e);
    }

    var seasonKeys = Object.keys(playlist);
    for (var si = 0; si < seasonKeys.length; si++) {
      var seasonKey = seasonKeys[si];
      var seasonTranslations = playlist[seasonKey];
      if (!seasonTranslations || typeof seasonTranslations !== 'object') continue;
      var translationKeys = Object.keys(seasonTranslations);
      for (var ti = 0; ti < translationKeys.length; ti++) {
        var translationKey = translationKeys[ti];
        var translationData = seasonTranslations[translationKey];
        if (!translationData) continue;

        if (Array.isArray(translationData)) {
          for (var ei = 0; ei < translationData.length; ei++) {
            var epData = translationData[ei];
            var epNum = (epData && (epData.episode || epData.e || epData.id)) || (ei + 1);
            var epTitle = (epData && (epData.title || epData.name || epData.label)) || ('Episode ' + epNum);
            var epLink = epData && epData.link;
            if (epLink) emitMedia(epLink);
            pushEpisode(seasonKey, epNum, translationKey, epTitle);
          }
          continue;
        }

        if (typeof translationData === 'object') {
          var episodeKeys = Object.keys(translationData);
          for (var ek = 0; ek < episodeKeys.length; ek++) {
            var episodeKey = episodeKeys[ek];
            var epObj = translationData[episodeKey];
            var epTitle2 = (epObj && (epObj.title || epObj.name || epObj.label)) || ('Episode ' + episodeKey);
            var epLink2 = epObj && epObj.link;
            if (epLink2) emitMedia(epLink2);
            pushEpisode(seasonKey, episodeKey, translationKey, epTitle2);
          }
        }
      }
    }

    if (out.length > 0) {
      sortEpisodes(out);
      safeCall('filmixEpisodes', JSON.stringify(out.slice(0, 250)));
    }
    return out.length;
  }

  function attachVideoListeners(doc) {
    var videos = [];
    try { videos = doc.querySelectorAll('video, pjsdiv video, .pjsdiv video'); } catch (_) { videos = []; }
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      if (v.__vakhFilmixBound) {
        emitMediaFromElement(v);
        continue;
      }
      v.__vakhFilmixBound = true;
      emitMediaFromElement(v);
      var onTick = function() {
        try { emitMediaFromElement(this); } catch (_) {}
      };
      try { v.addEventListener('loadedmetadata', onTick, true); } catch (_) {}
      try { v.addEventListener('playing', onTick, true); } catch (_) {}
      try { v.addEventListener('canplay', onTick, true); } catch (_) {}
      try { v.addEventListener('progress', onTick, true); } catch (_) {}
      try { v.addEventListener('timeupdate', onTick, true); } catch (_) {}
      try { v.addEventListener('durationchange', onTick, true); } catch (_) {}
    }
  }

  function scanDirectPlayerUrls() {
    var docs = getAllDocuments();
    for (var d = 0; d < docs.length; d++) {
      attachVideoListeners(docs[d]);
      var nodes = [];
      try { nodes = docs[d].querySelectorAll('video, source, iframe, pjsdiv video, .pjsdiv video, [data-src]'); } catch (_) { nodes = []; }
      for (var i = 0; i < nodes.length; i++) {
        emitMediaFromElement(nodes[i]);
      }
    }
  }

  function scoreEpisodeElement(el, season, episode, titleLower) {
    var text = normText(el.textContent).toLowerCase();
    if (!text || text.length > 140) return 0;
    var meta = readSeasonAndEpisode(el, text);
    var score = 0;

    if (season) {
      if (meta.season === season) score += 130;
      else if (text.includes('сезон ' + season) || text.includes('season ' + season)) score += 70;
    }
    if (episode) {
      if (meta.episode === episode) score += 130;
      else if (text.includes('серия ' + episode) || text.includes('episode ' + episode) || text.includes('ep ' + episode)) score += 70;
    }
    if (titleLower) {
      if (text.includes(titleLower)) score += 90;
    }
    if (/active|current|selected/.test((el.className || '').toString().toLowerCase())) score += 5;
    return score;
  }

  function clickElement(el) {
    try { el.scrollIntoView({ block: 'center', inline: 'center' }); } catch (_) {}
    try { el.click(); return true; } catch (_) {}
    try {
      var w = (el.ownerDocument && el.ownerDocument.defaultView) || window;
      var events = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
      for (var i = 0; i < events.length; i++) {
        el.dispatchEvent(new w.MouseEvent(events[i], { bubbles: true, cancelable: true, view: w }));
      }
      return true;
    } catch (_) {}
    return false;
  }

  function clickEpisode(season, episode, title) {
    season = String(season || '').trim();
    episode = String(episode || '').trim();
    var titleLower = normText(title || '').toLowerCase();

    var docs = getAllDocuments();
    var selectors = EPISODE_SELECTORS.concat(['a', 'button', 'li', 'div', 'span']);
    var best = null;
    var bestScore = 0;

    for (var d = 0; d < docs.length; d++) {
      for (var i = 0; i < selectors.length; i++) {
        var nodes = [];
        try { nodes = docs[d].querySelectorAll(selectors[i]); } catch (_) { nodes = []; }
        for (var j = 0; j < nodes.length; j++) {
          var el = nodes[j];
          if (!visible(el)) continue;
          var score = scoreEpisodeElement(el, season, episode, titleLower);
          if (score > bestScore) {
            bestScore = score;
            best = el;
          }
        }
      }
    }

    if (best && bestScore >= 90) {
      return clickElement(best) ? ('clicked:' + bestScore) : ('click-failed:' + bestScore);
    }

    // cross-origin iframe fallback: пробуем отдать команду в player через postMessage
    var payloads = [
      { type: 'setEpisode', season: season, episode: episode },
      { type: 'set_episode', season: season, episode: episode },
      { cmd: 'setEpisode', season: season, episode: episode },
      { command: 'setEpisode', season: season, episode: episode }
    ];
    var iframes = document.querySelectorAll('iframe');
    for (var f = 0; f < iframes.length; f++) {
      try {
        if (!iframes[f].contentWindow) continue;
        for (var p = 0; p < payloads.length; p++) {
          iframes[f].contentWindow.postMessage(payloads[p], '*');
        }
      } catch (_) {}
    }

    return best ? ('low-score:' + bestScore) : 'not-found';
  }

  window.__vakhFilmixScanEpisodes = collectEpisodes;
  window.__vakhFilmixClickEpisode = clickEpisode;

  if (!window.__vakhFilmixFetchWrapped) {
    window.__vakhFilmixFetchWrapped = true;
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function(input, init) {
        try {
          var reqUrl = typeof input === 'string' ? input : (input && input.url ? input.url : '');
          emitMedia(reqUrl);
        } catch (_) {}
        return origFetch.apply(this, arguments).then(function(resp) {
          try {
            var reqUrl2 = (resp && resp.url) ? resp.url : '';
            if (mediaLike(reqUrl2)) emitMedia(reqUrl2);
            if (reqUrl2 && /filmix|kodik|video|playlist|manifest|hls|player/i.test(reqUrl2)) {
              resp.clone().text().then(function(txt) { extractMediaFromText(txt); }).catch(function() {});
            }
          } catch (_) {}
          return resp;
        });
      };
    }
  }

  if (!window.__vakhFilmixXHRWrapped) {
    window.__vakhFilmixXHRWrapped = true;
    var oldOpen = XMLHttpRequest.prototype.open;
    var oldSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function(method, url) {
      try { this.__vakhUrl = url ? String(url) : ''; emitMedia(this.__vakhUrl); } catch (_) {}
      return oldOpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function() {
      try {
        this.addEventListener('readystatechange', function() {
          try {
            if (this.readyState !== 4) return;
            emitMedia(this.responseURL || this.__vakhUrl || '');
            var ct = (this.getResponseHeader && this.getResponseHeader('content-type')) || '';
            if (/json|text|mpegurl|application\/x-mpegurl/i.test(ct) || /filmix|kodik|video|playlist|manifest|hls|player/i.test(this.__vakhUrl || '')) {
              var t = '';
              if (typeof this.responseText === 'string') t = this.responseText;
              extractMediaFromText(t);
            }
          } catch (_) {}
        });
      } catch (_) {}
      return oldSend.apply(this, arguments);
    };
  }

  if (!window.__vakhFilmixMessageWrapped) {
    window.__vakhFilmixMessageWrapped = true;
    window.addEventListener('message', function(event) {
      try {
        var data = event.data;
        if (typeof data === 'string') {
          extractMediaFromText(data);
          try { data = JSON.parse(data); } catch (_) {}
        }
        if (!data || typeof data !== 'object') return;

        var textDump = '';
        try { textDump = JSON.stringify(data); } catch (_) {}
        if (textDump) extractMediaFromText(textDump);

        var playlist =
          (data.player_links && data.player_links.playlist) ||
          (data.data && data.data.player_links && data.data.player_links.playlist) ||
          (data.post && data.post.player_links && data.post.player_links.playlist) ||
          data.playlist;
        if (playlist && typeof playlist === 'object') {
          emitEpisodesFromPlaylist(playlist);
        }

        var pi = data.player_info || (data.data && data.data.player_info) || data;
        var season = String((pi && (pi.season || pi.s || pi.num_season)) || '');
        var episode = String((pi && (pi.episode || pi.e || pi.num_episode)) || '');
        if (season || episode) {
          safeCall('filmixEpisodeHint', JSON.stringify({
            title: normText((pi && (pi.title || pi.name || '')) || ''),
            season: season,
            episode: episode
          }));
        }
      } catch (_) {}
    }, true);
  }

  if (!window.__vakhFilmixObserverSet) {
    window.__vakhFilmixObserverSet = true;
    var mo = new MutationObserver(function() {
      var docs = getAllDocuments();
      for (var d = 0; d < docs.length; d++) {
        attachVideoListeners(docs[d]);
        var vids = [];
        try { vids = docs[d].querySelectorAll('video, source, iframe, pjsdiv video, .pjsdiv video, [data-src]'); } catch (_) { vids = []; }
        for (var i = 0; i < vids.length; i++) {
          emitMediaFromElement(vids[i]);
        }
      }
    });
    mo.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src']
    });
  }

  if (!window.__vakhFilmixTick) {
    window.__vakhFilmixTick = setInterval(function() {
      scanDirectPlayerUrls();
      collectEpisodes();
    }, 2000);
  }

  scanDirectPlayerUrls();
  setTimeout(scanDirectPlayerUrls, 700);
  setTimeout(scanDirectPlayerUrls, 2000);
  collectEpisodes();
  return 'filmix-dom-hooked';
})();
''';
  }
}
