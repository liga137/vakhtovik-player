// Filmix iframe probe script
// Usage: open Filmix page, press F12, paste this script into DevTools Console.
(function filmixProbe() {
  const norm = (v) => (v || '').replace(/\s+/g, ' ').trim();
  const pick = (selector, limit) =>
    Array.from(document.querySelectorAll(selector))
      .slice(0, limit)
      .map((el, idx) => ({
        idx,
        tag: el.tagName,
        cls: norm(el.className || ''),
        text: norm(el.textContent || ''),
        attrs: {
          id: el.id || '',
          href: el.getAttribute?.('href') || '',
          src: el.getAttribute?.('src') || '',
          dataSeason: el.getAttribute?.('data-season') || '',
          dataEpisode: el.getAttribute?.('data-episode') || '',
          dataTranslation: el.getAttribute?.('data-translation') || '',
          dataVoice: el.getAttribute?.('data-voice') || '',
        },
      }));

  const iframes = Array.from(document.querySelectorAll('iframe')).map((fr, idx) => ({
    idx,
    src: fr.src || fr.getAttribute('src') || '',
    id: fr.id || '',
    className: norm(fr.className || ''),
  }));

  const videos = Array.from(
    document.querySelectorAll('video, source, pjsdiv video, .pjsdiv video')
  ).map((v, idx) => ({
    idx,
    tag: v.tagName,
    src: v.currentSrc || v.src || v.getAttribute('src') || '',
    dataSrc: v.getAttribute('data-src') || '',
  }));

  const result = {
    ts: new Date().toISOString(),
    href: location.href,
    host: location.host,
    title: document.title,
    iframes,
    videos,
    seasonCandidates: pick('[data-season], .season, .seasons, [class*="season"]', 60),
    episodeCandidates: pick('[data-episode], .episode, .episodes, [class*="episode"]', 80),
    translationCandidates: pick(
      '[data-translation], [data-voice], .translation, .translations, [class*="voice"], [class*="translate"]',
      80
    ),
  };

  console.log('FILMIX_PROBE_RESULT', result);
  return result;
})();
