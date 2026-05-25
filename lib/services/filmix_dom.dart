/// JS для Filmix/Kodik/Videocdn: сбор сезонов/серий/озвучек и перехват media URL
class FilmixDom {
  static String getInjectionJS() {
    return r'''
(function() {
  var host = (window.location.hostname || '').toLowerCase();
  if (!host) return 'no-host';
  if (!(host.includes('filmix') || host.includes('kodik') || host.includes('videocdn'))) {
    return 'skip-host';
  }

  function normText(t) {
    return (t || '').replace(/\s+/g, ' ').trim();
  }
  function low(t) {
    return normText(t).toLowerCase();
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
    if (u.startsWith('blob:')) return false;
    if (u.includes('trailer') || u.includes('preview') || u.includes('poster') || u.includes('thumb')) return false;
    return /\.m3u8|\.mp4|\.mkv|\.webm|\.mpd|\/hls\/|master\.m3u8|playlist\.m3u8|manifest|\/stream\/|\/vod\/|\/video\//i.test(u);
  }

  function emitMedia(url) {
    if (!mediaLike(url)) return;
    var clean = String(url).split('#')[0];
    if (!clean) return;
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
    if (!text || text.length < 8) return;
    var re = /(https?:\/\/[^\s"'<>\\]+(?:\.m3u8|\.mp4|\.mkv|\.webm|master\.m3u8|playlist\.m3u8|manifest)[^\s"'<>\\]*)/ig;
    var m;
    while ((m = re.exec(text)) !== null) {
      emitMedia(m[1]);
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
      } catch (_) {}
    }
    return docs;
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
      return { season: String(season || ''), episode: String(episode || '') };
    } catch (_) {
      return { season: '', episode: '' };
    }
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
    var parsed = parseSeasonEpisodeFromText(text);
    if (!season) season = parsed.season;
    if (!episode) episode = parsed.episode;
    return { season: String(season || ''), episode: String(episode || '') };
  }

  function readTranslation(el, text) {
    var tr = '';
    if (el.getAttribute) {
      tr = el.getAttribute('data-translation') || el.getAttribute('data-voice') || el.getAttribute('data-dubbing') || '';
    }
    if (!tr && el.dataset) tr = el.dataset.translation || el.dataset.voice || el.dataset.dubbing || '';
    if (!tr) {
      var t = normText(text);
      var m = t.match(/\[([^\]]{2,64})\]/);
      if (m) tr = m[1];
    }
    return normText(tr);
  }

  var EPISODE_SELECTORS = [
    '[data-season][data-episode]',
    '[data-episode]',
    '.episodes li', '.episode-list li', '.serial-episodes li', '.playlist li',
    '.b-simple_episode__item', '.b-simple_episode__link',
    '.serial__episodes li',
    '[class*="episode"]'
  ];

  function addEpisode(out, seen, title, season, episode, translation) {
    var t = normText(title);
    var s = String(season || '');
    var e = String(episode || '');
    var tr = normText(translation || '');
    if (!t && !s && !e) return;
    var key = [s, e, tr.toLowerCase(), t.toLowerCase()].join('|');
    if (seen[key]) return;
    seen[key] = true;
    out.push({
      title: t || ('Серия ' + (e || '?')),
      season: s,
      episode: e,
      translation: tr
    });
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

  function emitMeta(meta) {
    if (!meta || typeof meta !== 'object') return;
    window.__vakhFilmixMeta = meta;
    safeCall('filmixMeta', JSON.stringify(meta));
  }

  function makeMetaFromEpisodes(episodes) {
    var tMap = {};
    var sMap = {};
    for (var i = 0; i < episodes.length; i++) {
      var e = episodes[i];
      var tr = normText(e.translation || '');
      var sn = String(e.season || '');
      if (tr) tMap[tr] = true;
      if (sn) sMap[sn] = true;
    }
    var translations = Object.keys(tMap).sort(function(a, b) { return a.localeCompare(b); })
      .map(function(name) { return { id: name, name: name }; });
    var seasons = Object.keys(sMap).sort(function(a, b) { return (parseInt(a, 10) || 0) - (parseInt(b, 10) || 0); })
      .map(function(num) { return { id: num, name: 'Сезон ' + num }; });

    var activeTranslation = '';
    var activeSeason = '';
    var st = window.__vakhFilmixState || {};
    if (st.translation) activeTranslation = st.translation;
    if (st.season) activeSeason = st.season;

    return {
      translations: translations,
      seasons: seasons,
      activeTranslation: activeTranslation,
      activeSeason: activeSeason
    };
  }

  function collectEpisodesFromDoc(doc, out, seen) {
    for (var i = 0; i < EPISODE_SELECTORS.length; i++) {
      var found = [];
      try { found = doc.querySelectorAll(EPISODE_SELECTORS[i]); } catch (_) { found = []; }
      for (var j = 0; j < found.length; j++) {
        var el = found[j];
        if (!visible(el)) continue;
        var text = normText(el.textContent);
        if (!text || text.length > 140) continue;
        var meta = readSeasonAndEpisode(el, text);
        var looksLikeEpisode = /серия|эпизод|episode|\bep\b|\d+\s*[xх]\s*\d+/i.test(text);
        if (!looksLikeEpisode && !meta.episode && !meta.season) continue;
        addEpisode(out, seen, text, meta.season, meta.episode, readTranslation(el, text));
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
      addEpisode(out, seen, 'iframe S' + (meta.season || '?') + ' E' + (meta.episode || '?'), meta.season, meta.episode, '');
    }
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
    safeCall('filmixEpisodes', JSON.stringify(out.slice(0, 350)));
    emitMeta(makeMetaFromEpisodes(out));
    return out.length;
  }

  function normalizePlaylist(raw) {
    var data = raw;
    if (!data) return null;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (_) { return null; }
    }
    if (!data || typeof data !== 'object') return null;
    if (data.playlist && typeof data.playlist === 'object') data = data.playlist;
    return data;
  }

  function emitEpisodesFromPlaylist(rawPlaylist) {
    var playlist = normalizePlaylist(rawPlaylist);
    if (!playlist || typeof playlist !== 'object') return 0;

    var out = [];
    var seen = {};
    var tStats = {};

    function pushEpisode(season, episode, translation, title, link) {
      var s = String(season || '');
      var e = String(episode || '');
      var tr = normText(translation || '');
      var t = normText(title || '');
      if (!t) t = 'S' + (s || '?') + ' E' + (e || '?');
      if (tr && !t.includes('[' + tr + ']')) t = t + ' [' + tr + ']';
      if (link) emitMedia(link);
      addEpisode(out, seen, t, s, e, tr);
      if (tr) {
        if (!tStats[tr]) tStats[tr] = { seasons: {}, episodes: 0 };
        if (s) tStats[tr].seasons[s] = true;
        tStats[tr].episodes++;
      }
    }

    var seasonKeys = Object.keys(playlist);
    for (var si = 0; si < seasonKeys.length; si++) {
      var seasonKey = seasonKeys[si];
      var seasonTranslations = playlist[seasonKey];
      if (!seasonTranslations || typeof seasonTranslations !== 'object') continue;
      var translationKeys = Object.keys(seasonTranslations);
      for (var ti = 0; ti < translationKeys.length; ti++) {
        var trKey = translationKeys[ti];
        var translationData = seasonTranslations[trKey];
        if (!translationData) continue;
        if (Array.isArray(translationData)) {
          for (var ei = 0; ei < translationData.length; ei++) {
            var epData = translationData[ei] || {};
            var epNum = epData.episode || epData.e || epData.id || (ei + 1);
            var epTitle = epData.title || epData.name || epData.label || ('Episode ' + epNum);
            pushEpisode(seasonKey, epNum, trKey, epTitle, epData.link || '');
          }
        } else if (typeof translationData === 'object') {
          var episodeKeys = Object.keys(translationData);
          for (var ek = 0; ek < episodeKeys.length; ek++) {
            var episodeKey = episodeKeys[ek];
            var epObj = translationData[episodeKey] || {};
            var epTitle2 = epObj.title || epObj.name || epObj.label || ('Episode ' + episodeKey);
            pushEpisode(seasonKey, episodeKey, trKey, epTitle2, epObj.link || '');
          }
        }
      }
    }

    if (out.length > 0) {
      sortEpisodes(out);
      safeCall('filmixEpisodes', JSON.stringify(out.slice(0, 350)));
      var translations = Object.keys(tStats).sort(function(a, b) { return a.localeCompare(b); })
        .map(function(name) {
          return { id: name, name: name };
        });
      var seasons = seasonKeys
        .filter(function(s) { return String(s).trim().length > 0; })
        .sort(function(a, b) { return (parseInt(a, 10) || 0) - (parseInt(b, 10) || 0); })
        .map(function(s) { return { id: String(s), name: 'Сезон ' + s }; });
      emitMeta({
        translations: translations,
        seasons: seasons,
        activeTranslation: (window.__vakhFilmixState && window.__vakhFilmixState.translation) || '',
        activeSeason: (window.__vakhFilmixState && window.__vakhFilmixState.season) || ''
      });
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
      for (var i = 0; i < nodes.length; i++) emitMediaFromElement(nodes[i]);
    }
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

  function scoreEpisodeElement(el, season, episode, titleLower, translationLower) {
    var text = low(el.textContent || '');
    if (!text || text.length > 180) return 0;
    var meta = readSeasonAndEpisode(el, text);
    var tr = low(readTranslation(el, text));
    var score = 0;
    if (season) {
      if (meta.season === season) score += 130;
      else if (text.includes('сезон ' + season) || text.includes('season ' + season)) score += 70;
    }
    if (episode) {
      if (meta.episode === episode) score += 130;
      else if (text.includes('серия ' + episode) || text.includes('episode ' + episode) || text.includes('ep ' + episode)) score += 70;
    }
    if (titleLower && text.includes(titleLower)) score += 90;
    if (translationLower && (tr === translationLower || text.includes(translationLower))) score += 100;
    if (/active|current|selected/.test((el.className || '').toString().toLowerCase())) score += 5;
    return score;
  }

  function clickEpisode(season, episode, title, translation) {
    season = String(season || '').trim();
    episode = String(episode || '').trim();
    var titleLower = low(title || '');
    var translationLower = low(translation || '');

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
          var score = scoreEpisodeElement(el, season, episode, titleLower, translationLower);
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

    var payload = { type: 'setEpisode', season: season, episode: episode, translation: translation };
    var iframes = document.querySelectorAll('iframe');
    for (var f = 0; f < iframes.length; f++) {
      try {
        if (iframes[f].contentWindow) iframes[f].contentWindow.postMessage(payload, '*');
      } catch (_) {}
    }
    return best ? ('low-score:' + bestScore) : 'not-found';
  }

  function debugDump() {
    var frames = document.querySelectorAll('iframe');
    var outFrames = [];
    for (var i = 0; i < frames.length; i++) {
      var src = frames[i].src || frames[i].getAttribute('src') || '';
      outFrames.push({ index: i, src: src });
    }
    var payload = {
      host: host,
      href: window.location.href,
      iframes: outFrames,
      lastMedia: window.__vakhLastFilmixMedia || '',
      state: window.__vakhFilmixState || {},
      meta: window.__vakhFilmixMeta || {}
    };
    safeCall('filmixDebug', JSON.stringify(payload));
    return payload;
  }

  window.__vakhFilmixScanEpisodes = collectEpisodes;
  window.__vakhFilmixClickEpisode = clickEpisode;
  window.__vakhFilmixDebug = debugDump;

  if (!window.__vakhFilmixFetchWrapped) {
    window.__vakhFilmixFetchWrapped = true;
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function(input) {
        try {
          var reqUrl = typeof input === 'string' ? input : (input && input.url ? input.url : '');
          emitMedia(reqUrl);
        } catch (_) {}
        return origFetch.apply(this, arguments).then(function(resp) {
          try {
            var reqUrl2 = (resp && resp.url) ? resp.url : '';
            emitMedia(reqUrl2);
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
            var t = '';
            if (typeof this.responseText === 'string') t = this.responseText;
            extractMediaFromText(t);
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

        var dump = '';
        try { dump = JSON.stringify(data); } catch (_) {}
        if (dump) extractMediaFromText(dump);

        var candidates = [
          data.player_links && data.player_links.playlist,
          data.data && data.data.player_links && data.data.player_links.playlist,
          data.post && data.post.player_links && data.post.player_links.playlist,
          data.data && data.data.post && data.data.post.player_links && data.data.post.player_links.playlist,
          data.playlist
        ];
        for (var i = 0; i < candidates.length; i++) {
          if (candidates[i]) emitEpisodesFromPlaylist(candidates[i]);
        }

        var pi = data.player_info || (data.data && data.data.player_info) || data;
        var season = String((pi && (pi.season || pi.s || pi.num_season)) || '');
        var episode = String((pi && (pi.episode || pi.e || pi.num_episode)) || '');
        var translation = normText((pi && (pi.translation || pi.voice || pi.translate || '')) || '');
        var title = normText((pi && (pi.title || pi.name || '')) || '');
        if (season || episode || translation || title) {
          window.__vakhFilmixState = {
            season: season,
            episode: episode,
            translation: translation,
            title: title
          };
          safeCall('filmixEpisodeHint', JSON.stringify({
            title: title,
            season: season,
            episode: episode,
            translation: translation
          }));
        }
      } catch (_) {}
    }, true);
  }

  if (!window.__vakhFilmixObserverSet) {
    window.__vakhFilmixObserverSet = true;
    var mo = new MutationObserver(function() {
      scanDirectPlayerUrls();
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
  debugDump();
  return 'filmix-dom-hooked';
})();
''';
  }

  static String getProbeConsoleJS() {
    return r'''
(function() {
  var out = {
    href: location.href,
    host: location.host,
    title: document.title,
    iframes: Array.from(document.querySelectorAll('iframe')).map(function(fr, i) {
      return { index: i, src: fr.src || fr.getAttribute('src') || '' };
    }),
    videos: Array.from(document.querySelectorAll('video, source, pjsdiv video, .pjsdiv video')).map(function(v) {
      return {
        tag: v.tagName,
        src: v.currentSrc || v.src || v.getAttribute('src') || '',
        dataSrc: v.getAttribute('data-src') || ''
      };
    }),
    seasonNodes: Array.from(document.querySelectorAll('[data-season], .season, .seasons, [class*="season"]')).slice(0, 30).map(function(el) {
      return (el.textContent || '').replace(/\s+/g, ' ').trim();
    }),
    episodeNodes: Array.from(document.querySelectorAll('[data-episode], .episode, .episodes, [class*="episode"]')).slice(0, 60).map(function(el) {
      return (el.textContent || '').replace(/\s+/g, ' ').trim();
    }),
    translationNodes: Array.from(document.querySelectorAll('[data-translation], [data-voice], .translation, .translations, [class*="voice"], [class*="translate"]')).slice(0, 40).map(function(el) {
      return (el.textContent || '').replace(/\s+/g, ' ').trim();
    }),
  };
  console.log('FILMIX_PROBE', out);
  return out;
})();
''';
  }
}
