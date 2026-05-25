// Filmix deep probe for DevTools Console.
// Paste once on film/series page, then click episodes/translations in player.
// After 20-60 sec run: window.__vakhProbe.dump()
// Stop hooks: window.__vakhProbe.stop()
(function () {
  const now = () => new Date().toISOString();
  const norm = (v) => (v || '').replace(/\s+/g, ' ').trim();
  const mediaRe =
    /(https?:\/\/[^\s"'<>\\]+(?:\.m3u8|\.mp4|\.mkv|master\.m3u8|playlist\.m3u8|manifest)[^\s"'<>\\]*)/ig;
  const isMediaLike = (url) => {
    const u = String(url || '').toLowerCase();
    if (!u) return false;
    if (u.startsWith('blob:')) return false;
    return (
      u.includes('.m3u8') ||
      u.includes('.mp4') ||
      u.includes('.mkv') ||
      u.includes('/hls/') ||
      u.includes('playlist') ||
      u.includes('manifest') ||
      u.includes('/stream/') ||
      u.includes('/vod/') ||
      u.includes('/video/')
    );
  };

  const state = {
    startedAt: now(),
    href: location.href,
    host: location.host,
    title: document.title,
    iframes: [],
    videos: [],
    seasonNodes: [],
    episodeNodes: [],
    translationNodes: [],
    mediaUrls: [],
    postMessages: [],
    fetchHits: [],
    xhrHits: [],
    notes: [],
  };

  const seenMedia = new Set();
  const addMedia = (url, source) => {
    const clean = String(url || '').split('#')[0];
    if (!clean || !isMediaLike(clean)) return;
    if (seenMedia.has(clean)) return;
    seenMedia.add(clean);
    state.mediaUrls.push({ ts: now(), source, url: clean });
    console.log('[probe][media]', source, clean);
  };

  const pickNodes = (selector, limit) =>
    Array.from(document.querySelectorAll(selector))
      .slice(0, limit)
      .map((el, i) => ({
        i,
        tag: el.tagName,
        id: el.id || '',
        cls: norm(el.className || ''),
        text: norm(el.textContent || ''),
        href: el.getAttribute?.('href') || '',
        src: el.getAttribute?.('src') || '',
        dataSeason: el.getAttribute?.('data-season') || '',
        dataEpisode: el.getAttribute?.('data-episode') || '',
        dataTranslation: el.getAttribute?.('data-translation') || '',
        dataVoice: el.getAttribute?.('data-voice') || '',
      }));

  const snapshot = () => {
    state.href = location.href;
    state.title = document.title;
    state.iframes = Array.from(document.querySelectorAll('iframe')).map((fr, i) => ({
      i,
      src: fr.src || fr.getAttribute('src') || '',
      id: fr.id || '',
      cls: norm(fr.className || ''),
    }));
    state.videos = Array.from(
      document.querySelectorAll('video, source, pjsdiv video, .pjsdiv video')
    ).map((v, i) => ({
      i,
      tag: v.tagName,
      src: v.currentSrc || v.src || v.getAttribute('src') || '',
      dataSrc: v.getAttribute('data-src') || '',
    }));
    state.seasonNodes = pickNodes(
      '[data-season], .season, .seasons, [class*="season"]',
      120
    );
    state.episodeNodes = pickNodes(
      '[data-episode], .episode, .episodes, [class*="episode"]',
      200
    );
    state.translationNodes = pickNodes(
      '[data-translation], [data-voice], .translation, .translations, [class*="voice"], [class*="translate"]',
      120
    );
    for (const it of state.iframes) addMedia(it.src, 'iframe-src');
    for (const it of state.videos) {
      addMedia(it.src, 'video-src');
      addMedia(it.dataSrc, 'video-data-src');
    }
  };

  const extractMediaFromText = (text, source) => {
    if (!text || text.length < 6) return;
    let m;
    while ((m = mediaRe.exec(text)) !== null) addMedia(m[1], source);
  };

  const oldFetch = window.fetch;
  window.fetch = function (input, init) {
    let reqUrl = '';
    try {
      reqUrl = typeof input === 'string' ? input : input?.url || '';
      if (reqUrl) {
        state.fetchHits.push({ ts: now(), phase: 'request', url: reqUrl });
        addMedia(reqUrl, 'fetch-request');
      }
    } catch (_) {}
    return oldFetch.apply(this, arguments).then((resp) => {
      try {
        const respUrl = resp?.url || reqUrl;
        state.fetchHits.push({ ts: now(), phase: 'response', url: respUrl, status: resp?.status || 0 });
        addMedia(respUrl, 'fetch-response');
        if (/playlist|manifest|video|player|kodik|filmix|hls/i.test(respUrl)) {
          resp.clone().text().then((txt) => extractMediaFromText(txt, 'fetch-body')).catch(() => {});
        }
      } catch (_) {}
      return resp;
    });
  };

  const oldOpen = XMLHttpRequest.prototype.open;
  const oldSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__vakhProbeUrl = String(url || '');
    this.__vakhProbeMethod = String(method || 'GET');
    state.xhrHits.push({ ts: now(), phase: 'open', method: this.__vakhProbeMethod, url: this.__vakhProbeUrl });
    addMedia(this.__vakhProbeUrl, 'xhr-open');
    return oldOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('readystatechange', function () {
      if (this.readyState !== 4) return;
      try {
        const respUrl = this.responseURL || this.__vakhProbeUrl || '';
        state.xhrHits.push({
          ts: now(),
          phase: 'done',
          status: this.status || 0,
          method: this.__vakhProbeMethod || 'GET',
          url: respUrl,
        });
        addMedia(respUrl, 'xhr-done');
        if (/playlist|manifest|video|player|kodik|filmix|hls/i.test(respUrl)) {
          extractMediaFromText(this.responseText || '', 'xhr-body');
        }
      } catch (_) {}
    });
    return oldSend.apply(this, arguments);
  };

  const onMessage = (event) => {
    try {
      let data = event.data;
      if (typeof data === 'string') {
        extractMediaFromText(data, 'postMessage-string');
        try {
          data = JSON.parse(data);
        } catch (_) {}
      }
      const row = {
        ts: now(),
        origin: event.origin || '',
        type: typeof data,
        keys: data && typeof data === 'object' ? Object.keys(data).slice(0, 40) : [],
      };
      state.postMessages.push(row);
      if (data && typeof data === 'object') {
        const dump = JSON.stringify(data);
        extractMediaFromText(dump, 'postMessage-json');
        const playlist =
          data?.player_links?.playlist ||
          data?.data?.player_links?.playlist ||
          data?.post?.player_links?.playlist ||
          data?.playlist;
        if (playlist) {
          state.notes.push({
            ts: now(),
            note: 'playlist-detected',
            seasons: Object.keys(playlist || {}).length,
          });
          console.log('[probe][playlist-detected]', playlist);
        }
      }
    } catch (_) {}
  };
  window.addEventListener('message', onMessage, true);

  const mo = new MutationObserver(() => snapshot());
  mo.observe(document.documentElement || document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src', 'data-src', 'class'],
  });

  snapshot();

  window.__vakhProbe = {
    dump() {
      snapshot();
      const result = JSON.parse(JSON.stringify(state));
      console.log('[probe][dump]', result);
      return result;
    },
    stop() {
      try {
        mo.disconnect();
      } catch (_) {}
      try {
        window.removeEventListener('message', onMessage, true);
      } catch (_) {}
      try {
        window.fetch = oldFetch;
      } catch (_) {}
      try {
        XMLHttpRequest.prototype.open = oldOpen;
        XMLHttpRequest.prototype.send = oldSend;
      } catch (_) {}
      console.log('[probe][stopped]');
      return true;
    },
  };

  console.log('[probe][started] run window.__vakhProbe.dump() after interactions');
})();
