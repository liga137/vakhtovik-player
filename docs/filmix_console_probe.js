/*
  Filmix iframe reconnaissance script for DevTools console.
  Usage:
    1) Open Filmix serial page.
    2) Open DevTools Console.
    3) Paste and run this script.
    4) Click seasons/episodes/translations in UI and watch console logs.
*/
(function filmixProbe() {
  const NS = '[VAKH-FILMIX-PROBE]';
  const mediaSeen = new Set();
  const docSeen = new WeakSet();

  const norm = (v) => String(v || '').replace(/\s+/g, ' ').trim();
  const log = (...args) => console.log(NS, ...args);

  function safeDocs() {
    const docs = [document];
    const iframes = Array.from(document.querySelectorAll('iframe'));
    iframes.forEach((fr, i) => {
      const src = fr.src || fr.getAttribute('src') || '';
      log(`iframe[${i}]`, src || '(no src)');
      try {
        if (fr.contentDocument && fr.contentDocument.documentElement) {
          docs.push(fr.contentDocument);
        }
      } catch (e) {
        log(`iframe[${i}] cross-origin (DOM locked)`);
      }
    });
    return docs;
  }

  function findInDoc(doc) {
    const scope = doc === document ? 'main' : 'iframe';
    const translations = Array.from(
      doc.querySelectorAll(
        '.translation li, .translations li, .voice li, [data-translate], [data-voice], [class*="translate"], [class*="voice"]'
      )
    )
      .map((el, idx) => ({
        idx,
        text: norm(el.textContent),
        id: el.getAttribute('data-translate') || el.getAttribute('data-id') || el.getAttribute('data-voice') || '',
      }))
      .filter((x) => x.text.length > 0 && x.text.length < 80);

    const seasons = Array.from(
      doc.querySelectorAll(
        '.season li, .seasons li, [class*="season"] li, [data-season], a[href*="season"], button[data-season]'
      )
    )
      .map((el, idx) => ({
        idx,
        text: norm(el.textContent),
        season:
          el.getAttribute('data-season') ||
          (el.dataset ? el.dataset.season : '') ||
          ((norm(el.textContent).match(/(?:season|сезон)\s*(\d{1,2})/i) || [])[1] || ''),
      }))
      .filter((x) => x.text.length > 0 && x.text.length < 80);

    const episodes = Array.from(
      doc.querySelectorAll(
        '.episode li, .episodes li, [class*="episode"] li, [data-episode], a[href*="episode"], button[data-episode], li'
      )
    )
      .map((el, idx) => {
        const t = norm(el.textContent);
        if (!t || t.length > 120) return null;
        const epByText = (t.match(/(?:episode|серия|ep)\s*(\d{1,3})/i) || [])[1] || '';
        return {
          idx,
          text: t,
          season: el.getAttribute('data-season') || (el.dataset ? el.dataset.season : '') || '',
          episode: el.getAttribute('data-episode') || (el.dataset ? el.dataset.episode : '') || epByText,
        };
      })
      .filter(Boolean)
      .filter((x) => /episode|серия|ep|\d+\s*[xх]\s*\d+/i.test(x.text) || x.episode);

    return { scope, translations, seasons, episodes };
  }

  function scan() {
    const docs = safeDocs();
    docs.forEach((doc) => {
      if (docSeen.has(doc)) return;
      docSeen.add(doc);
      const out = findInDoc(doc);
      log(`scan:${out.scope}`, {
        translations: out.translations.slice(0, 30),
        seasons: out.seasons.slice(0, 30),
        episodes: out.episodes.slice(0, 80),
      });
    });
  }

  function emitMedia(url, from) {
    const u = String(url || '').split('#')[0];
    if (!u) return;
    if (!/\.m3u8|\.mp4|\.mpd|googlevideo|kodik|videocdn|manifest|playlist|hls/i.test(u)) return;
    if (mediaSeen.has(u)) return;
    mediaSeen.add(u);
    log(`media:${from}`, u);
  }

  function hookFetch() {
    if (window.__vakhProbeFetchWrapped) return;
    window.__vakhProbeFetchWrapped = true;
    const orig = window.fetch;
    if (!orig) return;
    window.fetch = function wrappedFetch(input) {
      try {
        const reqUrl = typeof input === 'string' ? input : input && input.url ? input.url : '';
        emitMedia(reqUrl, 'fetch:req');
      } catch (_) {}
      return orig.apply(this, arguments).then((resp) => {
        try {
          emitMedia(resp && resp.url ? resp.url : '', 'fetch:resp');
        } catch (_) {}
        return resp;
      });
    };
  }

  function hookXHR() {
    if (window.__vakhProbeXhrWrapped) return;
    window.__vakhProbeXhrWrapped = true;
    const oldOpen = XMLHttpRequest.prototype.open;
    const oldSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function open(method, url) {
      try {
        this.__vakhProbeUrl = String(url || '');
        emitMedia(this.__vakhProbeUrl, 'xhr:open');
      } catch (_) {}
      return oldOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function send() {
      try {
        this.addEventListener('readystatechange', () => {
          if (this.readyState !== 4) return;
          emitMedia(this.responseURL || this.__vakhProbeUrl || '', 'xhr:done');
        });
      } catch (_) {}
      return oldSend.apply(this, arguments);
    };
  }

  function hookVideoObserver() {
    if (window.__vakhProbeObserver) return;
    window.__vakhProbeObserver = new MutationObserver(() => {
      const docs = safeDocs();
      docs.forEach((doc) => {
        const nodes = Array.from(doc.querySelectorAll('video, source, iframe'));
        nodes.forEach((n) => {
          emitMedia(n.src || n.getAttribute('src') || '', 'dom');
        });
      });
    });
    window.__vakhProbeObserver.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src'],
    });
  }

  function hookMessage() {
    if (window.__vakhProbeMsgWrapped) return;
    window.__vakhProbeMsgWrapped = true;
    window.addEventListener(
      'message',
      (event) => {
        try {
          if (typeof event.data === 'string') {
            const urls = event.data.match(/https?:\/\/[^\s"'<>\\]+/g) || [];
            urls.forEach((u) => emitMedia(u, 'postMessage:str'));
          } else if (event.data && typeof event.data === 'object') {
            const dump = JSON.stringify(event.data);
            const urls = dump.match(/https?:\/\/[^\s"'<>\\]+/g) || [];
            urls.forEach((u) => emitMedia(u, 'postMessage:obj'));
            log('postMessage:object', event.data);
          }
        } catch (_) {}
      },
      true
    );
  }

  hookFetch();
  hookXHR();
  hookVideoObserver();
  hookMessage();
  scan();
  setInterval(scan, 3000);
  log('probe started');
})();
