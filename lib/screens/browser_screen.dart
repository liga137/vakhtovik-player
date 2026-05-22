import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../services/api_service.dart';
import '../services/filmix_auth.dart';
import '../services/youtube_hover.dart';
import '../models/preset.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? webViewController;
  String url = "https://seasonvar.ru/";
  final urlController = TextEditingController(text: "https://seasonvar.ru/");
  
  bool _showInterceptor = false;
  String _interceptedUrl = "";
  String _currentReferer = "";
  List<Preset> _presets = [];
  String _selectedQuality = "240p";
  bool _isLoading = false;

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _showPlayer = false;
  bool _waitingForNextEpisode = false; // флаг: ждём перехвата новой серии
  bool _onYouTube = false; // флаг: мы на странице YouTube
  bool _compressMode = false; // Режим «Сжатое» — кнопки на всех видео YouTube
  Duration _lastPosition = Duration.zero; // для детекта конца HLS без duration
  bool _endReached = false; // защита от множественных вызовов _playNextEpisode
  bool _interceptedAlready = false; // защита от повторного перехвата одного URL
  bool _scanningSeasonvar = false;
  List<Map<String, String>> _seasonvarEpisodes = [];
  int _seasonvarIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    // Жёсткий фолбэк — если сервер не отвечает, качество всё равно будет
    const fallback = [
      Preset(id: '480p', label: '480p', width: 854, crf: 43, audioBitrate: '32k'),
      Preset(id: '360p', label: '360p', width: 640, crf: 40, audioBitrate: '32k'),
      Preset(id: '240p', label: '240p', width: 426, crf: 38, audioBitrate: '32k'),
      Preset(id: '144p', label: '144p', width: 256, crf: 34, audioBitrate: '32k'),
    ];
    try {
      final presets = await ApiService.getPresets().timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() {
          _presets = List<Preset>.from(presets.isNotEmpty ? presets : fallback);
          if (_presets.isNotEmpty) _selectedQuality = _presets.first.id;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _presets = List<Preset>.from(fallback);
          _selectedQuality = '240p';
        });
      }
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  // Скрипт для авто-переключения серии — НЕ закрывает плеер, ждёт новый перехват
  void _playNextEpisode() {
    if (webViewController == null) return;

    // Правильный режим Seasonvar: следующая серия берётся из собранного списка прямых ссылок
    if (_seasonvarEpisodes.isNotEmpty && _seasonvarIndex + 1 < _seasonvarEpisodes.length) {
      _seasonvarIndex++;
      final ep = _seasonvarEpisodes[_seasonvarIndex];
      _interceptedUrl = ep['url'] ?? '';
      _currentReferer = urlController.text;
      _interceptedAlready = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Серия ${_seasonvarIndex + 1}: ${ep['title'] ?? ''}'), duration: const Duration(seconds: 2)),
      );
      _startMagic();
      return;
    }
    
    // Ставим флаг: следующие перехваченные URL обрабатываем автоматически
    _waitingForNextEpisode = true;
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Переключаю серию...'), duration: Duration(seconds: 1))
    );
    
    // Инжектим клик по кнопке «Следующая серия»
    // Перед кликом читаем индекс текущей серии (записан трекером при загрузке страницы)
    webViewController!.evaluateJavascript(source: """
      (function() {
        var idx = (typeof window.__vakh_idx !== 'undefined') ? window.__vakh_idx : -1;
        var items = document.querySelectorAll('#htmlPlayer_playlist > *');
        
        // Если трекер знает индекс — кликаем следующий
        if (idx >= 0 && idx + 1 < items.length) {
          window.__vakh_idx = idx + 1;
          items[idx + 1].click();
          return 'tracker-next:' + (idx+1);
        }
        
        // Fallback: ищем активный элемент по жёлтой точке (span с background)
        for (var i = 0; i < items.length; i++) {
          var dot = items[i].querySelector('span[style*="background"], i[style*="background"], .dot, .active, [class*="active"]');
          var isCurrent = dot !== null || (items[i].className && (items[i].className.includes('active') || items[i].className.includes('current')));
          if (isCurrent && i + 1 < items.length) {
            window.__vakh_idx = i + 1;
            items[i + 1].click();
            return 'dot-next:' + (i+1);
          }
        }
        
        // ===== Резерв: кнопки по селектору =====
        var sel = document.querySelector('.pgs-player-next, .pgs-next-btn, .pgs_next, .player-next, .next-episode, [title*="След"], [title*="след"], .next-link, #next, .pnext, .plnext, [data-action="next"]');
        if (sel) { sel.click(); return 'button-click'; }
        
        // ===== Filmix =====
        var fx = document.querySelector('.icon-next, .next-btn, .next-video, .vnext');
        if (fx) { fx.click(); return 'filmix-click'; }
        
        // ===== Универсальный поиск по тексту =====
        var all = document.querySelectorAll('a, button, span, div');
        for (var i = 0; i < all.length; i++) {
          if (all[i].offsetParent === null) continue;
          var t = (all[i].textContent || '').toLowerCase();
          if ((t.includes('следующая') || t.includes('след.') || t.includes('next')) && t.length < 30) {
            all[i].click();
            return 'text-click';
          }
        }
        return 'not-found:idx=' + idx + ',items=' + items.length;
      })();
    """);
    
    // Таймаут: если за 15 секунд новая серия не перехватилась — закрываем плеер
    Future.delayed(const Duration(seconds: 15), () {
      if (_waitingForNextEpisode && mounted) {
        _waitingForNextEpisode = false;
        _stopPlayer();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось переключить серию'), duration: Duration(seconds: 2))
        );
      }
    });
  }

  void _startMagic() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final result = await ApiService.transcode(url: _interceptedUrl, quality: _selectedQuality, referer: _currentReferer);
      final hlsUrl = ApiService.hlsUrl(result.playlistUrl);

      // Инициализируем новый контроллер
      _videoController?.dispose();
      _chewieController?.dispose();
      
      _videoController = VideoPlayerController.networkUrl(Uri.parse(hlsUrl));
      await _videoController!.initialize();
      // Всегда начинаем с начала (HLS event может стартовать с live-edge)
      await _videoController!.seekTo(Duration.zero);

      // Ждём первый кадр чтобы получить реальный aspectRatio
      await Future.delayed(const Duration(milliseconds: 500));
      
      final ar = _videoController!.value.aspectRatio > 0 
          ? _videoController!.value.aspectRatio 
          : 16 / 9; // fallback 16:9 если HLS не дал размер

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        aspectRatio: ar,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        showControlsOnInitialize: true,
        // НЕ используем кастомные контролы — даём Chewie самому выбрать (MaterialDesktopControls на Windows)
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(errorMessage, style: const TextStyle(color: Colors.white, fontSize: 16), textAlign: TextAlign.center),
            ),
          );
        },
      );

      // Слушаем окончание видео
      // ВАЖНО: listener вызывается каждый кадр (30 раз/сек).
      // _endReached — защита от создания сотен Future.delayed таймеров.
      _endReached = false;
      _videoController!.addListener(() {
        if (!_videoController!.value.isInitialized) return;
        if (_endReached) return; // уже обработали конец — ничего не делаем

        final pos = _videoController!.value.position;
        final dur = _videoController!.value.duration;
        
        // Способ 1: точное знание длительности
        if (dur > Duration.zero && pos >= dur - const Duration(seconds: 1) && pos > Duration.zero) {
          _endReached = true;
          _playNextEpisode();
          return;
        }
        // Способ 2: HLS без duration — позиция застыла на 2 сек
        if (dur == Duration.zero && _videoController!.value.isPlaying) {
          final snapshot = pos;
          _lastPosition = snapshot;
          // Один таймер — проверяем через 2 сек. Если позиция не изменилась = конец.
          Future.delayed(const Duration(seconds: 2), () {
            if (_endReached) return;
            if (_videoController != null &&
                _videoController!.value.isInitialized &&
                _videoController!.value.duration == Duration.zero &&
                _videoController!.value.position == snapshot &&
                snapshot > const Duration(seconds: 5)) {
              _endReached = true;
              _playNextEpisode();
            }
          });
        }
      });

      // Дополнительно: слушаем событие завершения от Chewie
      
      if (mounted) {
        setState(() {
          _showInterceptor = false;
          _isLoading = false;
          _showPlayer = true;
        });
        // Глушим WebView — чтобы фоном не орала реклама/оригинал
        _muteWebView();

        // Seasonvar: основной поток уже ушёл на транскодер, теперь можно тихо собрать список серий
        final isSeasonvar = _currentReferer.contains('seasonvar') || _interceptedUrl.contains('seasonvar');
        if (isSeasonvar && _seasonvarEpisodes.isEmpty && !_scanningSeasonvar) {
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted && _showPlayer) _scanSeasonvarPlaylist(silent: true);
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e'), duration: const Duration(seconds: 4))
      );
    }
  }

  void _muteWebView() {
    webViewController?.evaluateJavascript(source: """
      (function(){
        var vids = document.querySelectorAll('video, audio');
        for (var i = 0; i < vids.length; i++) {
          vids[i].muted = true;
          vids[i].pause();
        }
      })();
    """);
  }

  void _stopPlayer() {
    _chewieController?.pause();
    _videoController?.pause();
    _chewieController?.dispose();
    _videoController?.dispose();
    _chewieController = null;
    _videoController = null;
    setState(() {
      _showPlayer = false;
      _interceptedAlready = false; // сбрасываем флаг — готовы перехватить следующий поток
      _endReached = false;
    });
    // Возвращаем звук WebView
    webViewController?.evaluateJavascript(source: """
      (function(){
        var vids = document.querySelectorAll('video, audio');
        for (var i = 0; i < vids.length; i++) {
          vids[i].muted = false;
        }
      })();
    """);
  }

  // Сжатие YouTube: показывает шторку выбора качества (как обычный перехват)
  void _compressYouTube() {
    final ytUrl = urlController.text;
    if (!ytUrl.contains('youtube.com/watch')) return;

    _openCompressedUrl(ytUrl, referer: 'https://www.youtube.com/');
  }

  void _playSeasonvarEpisode(int index) {
    if (index < 0 || index >= _seasonvarEpisodes.length) return;
    _seasonvarIndex = index;
    final ep = _seasonvarEpisodes[index];
    final epUrl = ep['url'] ?? '';
    if (epUrl.isEmpty) return;
    _interceptedUrl = epUrl;
    _currentReferer = urlController.text;
    _interceptedAlready = false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Запускаю серию ${index + 1}'), duration: const Duration(seconds: 1)),
    );
    _startMagic();
  }

  void _openCompressedUrl(String url, {String? referer}) {
    if (url.trim().isEmpty) return;
    _interceptedUrl = url.trim();
    _currentReferer = referer ?? urlController.text;
    _interceptedAlready = true;
    _muteWebView();
    if (mounted) setState(() => _showInterceptor = true);
  }

  void _scanSeasonvarPlaylist({bool silent = false}) {
    if (webViewController == null) return;
    if (_scanningSeasonvar) return;
    _scanningSeasonvar = true;
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сканирую серии Seasonvar...'), duration: Duration(seconds: 2)),
      );
    }
    webViewController!.evaluateJavascript(source: r'''
      (async function(){
        const wait = (ms) => new Promise(r => setTimeout(r, ms));
        const waitForVideoSrc = (lastSrc) => new Promise((resolve) => {
          let attempts = 0;
          const check = setInterval(() => {
            const video = document.querySelector('video');
            if (video) { video.muted = true; video.pause(); }
            attempts++;
            if (video && video.src && video.src !== lastSrc && video.src.length > 10) {
              clearInterval(check); resolve(video.src);
            }
            if (attempts > 30) { clearInterval(check); resolve(null); }
          }, 350);
        });

        const items = Array.from(document.querySelectorAll('#htmlPlayer_playlist > *'));
        const result = [];
        let last = '';
        for (let i = 0; i < items.length; i++) {
          items[i].click();
          await wait(250);
          const src = await waitForVideoSrc(last);
          if (src) {
            result.push({
              index: String(i),
              title: (items[i].innerText || ('Серия ' + (i + 1))).trim(),
              url: src
            });
            last = src;
          }
        }
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('seasonvarPlaylist', JSON.stringify(result));
        }
        return result.length;
      })();
    ''');
  }

  void _updateYouTubeState(Uri url) {
    final onYT = url.host.contains('youtube.com');
    if (onYT != _onYouTube) setState(() => _onYouTube = onYT);
  }

  void _toggleYouTubeCompressMode() {
    if (webViewController == null) return;
    final mode = _compressMode;
    webViewController!.evaluateJavascript(source: "window.vakhCompressMode(" + (mode ? "true" : "false") + ");");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Browser UI
          Column(
            children: [
              // Browser Header
              Container(
                padding: const EdgeInsets.only(top: 40, left: 10, right: 10, bottom: 10),
                color: const Color(0xFF1A1A1A),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: 'Назад',
                      onPressed: () {
                        webViewController?.goBack();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.home, color: Colors.white),
                      onPressed: () {
                        webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri("https://seasonvar.ru/")));
                      },
                    ),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF333333),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: TextField(
                          controller: urlController,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            icon: Icon(Icons.lock, color: Colors.green, size: 16),
                          ),
                          onSubmitted: (value) {
                            var uri = Uri.parse(value);
                            if (!uri.hasScheme) value = "https://$value";
                            webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(value)));
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.person, color: Colors.orange),
                      onPressed: () {},
                    ),
                    // YouTube: кнопки «Сжать» + «Оригинал/Сжатое» в хедере
                    if (_onYouTube) ...[
                      // Кнопка «Сжать видео» — рядом с адресной строкой
                      GestureDetector(
                        onTap: _compressYouTube,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.shade700,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.compress, color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text('Сжать', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Переключатель «Оригинал/Сжатое» (режим наложения кнопок на превью)
                      GestureDetector(
                        onTap: () {
                          setState(() => _compressMode = !_compressMode);
                          _toggleYouTubeCompressMode();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _compressMode ? Colors.orange : const Color(0xFF333333),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _compressMode ? Colors.orange : Colors.grey, width: 1.5),
                          ),
                          child: Text(
                            _compressMode ? '🔥 Сжатое' : '🔄 Оригинал',
                            style: TextStyle(color: _compressMode ? Colors.black : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                    // Кнопка «Слить куки» — только на Filmix
                    if (urlController.text.contains('filmix'))
                      IconButton(
                        icon: const Icon(Icons.cookie, color: Colors.amber),
                        tooltip: 'Слить куки Filmix',
                        onPressed: () {
                          webViewController?.evaluateJavascript(source: FilmixAuth.getCookieExtractorJS());
                          Clipboard.setData(const ClipboardData(text: 'Жди prompt'));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Появился prompt — скопируй куки (Ctrl+C)'), duration: Duration(seconds: 4))
                          );
                        },
                      ),
                  ],
                ),
              ),
              
              // WebView
              Expanded(
                child: InAppWebView(
                  key: webViewKey,
                  initialUrlRequest: URLRequest(url: WebUri("https://seasonvar.ru/")),
                  initialSettings: InAppWebViewSettings(
                    useShouldOverrideUrlLoading: true,
                    useShouldInterceptRequest: true,
                    useOnLoadResource: false,
                    mediaPlaybackRequiresUserGesture: false,
                    domStorageEnabled: true,
                    databaseEnabled: true,
                    cacheEnabled: true,
                    javaScriptEnabled: true,
                    transparentBackground: false,
                    hardwareAcceleration: true,
                    // Chrome UA — YouTube блокирует Edge/WebView2 UA
                    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                  ),
                  onWebViewCreated: (controller) {
                    webViewController = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'compressUrl',
                      callback: (args) {
                        if (args.isEmpty) return null;
                        final raw = args.first?.toString() ?? '';
                        if (raw.isEmpty) return null;
                        _openCompressedUrl(raw, referer: 'https://www.youtube.com/');
                        return null;
                      },
                    );
                    controller.addJavaScriptHandler(
                      handlerName: 'seasonvarPlaylist',
                      callback: (args) {
                        _scanningSeasonvar = false;
                        if (args.isEmpty) return null;
                        try {
                          final decoded = jsonDecode(args.first.toString()) as List<dynamic>;
                          final episodes = decoded.map((e) {
                            final m = Map<String, dynamic>.from(e as Map);
                            return <String, String>{
                              'index': m['index']?.toString() ?? '',
                              'title': m['title']?.toString() ?? '',
                              'url': m['url']?.toString() ?? '',
                            };
                          }).where((e) => (e['url'] ?? '').isNotEmpty).toList();
                          if (mounted) {
                            var currentIndex = 0;
                            final currentUrl = _interceptedUrl;
                            final foundIndex = episodes.indexWhere((e) => (e['url'] ?? '') == currentUrl);
                            if (foundIndex >= 0) currentIndex = foundIndex;
                            setState(() {
                              _seasonvarEpisodes = episodes;
                              _seasonvarIndex = currentIndex;
                            });
                            if (episodes.isNotEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Список серий готов: ${episodes.length}'), duration: const Duration(seconds: 2)),
                              );
                            }
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ошибка скана Seasonvar: $e'), duration: const Duration(seconds: 4)),
                            );
                          }
                        }
                        return null;
                      },
                    );
                  },
                  onLoadStop: (controller, url) {
                    if (url != null) {
                      urlController.text = url.toString();

                       // Seasonvar: трекер кликов (плейлист грузится через plist.txt ~3с)
                       if (url.host.contains('seasonvar')) {
                         Future.delayed(const Duration(seconds: 4), () {
                           if (mounted) {
                             controller.evaluateJavascript(source:
                               "(function(){"
                               "if(window.__vt)return 'ok';"
                               "window.__vt=true;window.__vakh_idx=-1;"
                               "var pl=document.querySelector('#htmlPlayer_playlist');"
                               "if(!pl)return 'no-pl';"
                               "var its=Array.from(pl.querySelectorAll('li,a'));"
                               "its.forEach(function(it,i){it.addEventListener('click',function(){window.__vakh_idx=i;},true);});"
                               "for(var i=0;i<its.length;i++){"
                               "var d=its[i].querySelector('span[style]');"
                               "var c=its[i].className||'';"
                               "if(d||c.includes('active')||c.includes('current')){window.__vakh_idx=i;break;}"
                               "}"
                               "return 'ok:'+its.length+'/'+window.__vakh_idx;"
                               "})();"
                             );
                           }
                         });
                       }

                       // Filmix: автологин
                       if (url.host.contains('filmix')) {
                         controller.evaluateJavascript(source: FilmixAuth.getInjectionScript());
                       }

                       // YouTube: ховер-кнопки
                       if (url.host.contains('youtube.com')) {
                         controller.evaluateJavascript(source: YouTubeHover.getInjectionJS());
                       }

                       // YouTube /watch — глушим и показываем шторку
                       if (url.host.contains('youtube.com') && url.path.contains('/watch') && !_showInterceptor && !_showPlayer) {
                         controller.evaluateJavascript(source: "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;e.pause();});");
                         setState(() {
                           _interceptedUrl = url.toString();
                           _currentReferer = url.toString();
                           _showInterceptor = true;
                           _onYouTube = true;
                         });
                       }
                       _updateYouTubeState(url);
                     }
                  },
                  onUpdateVisitedHistory: (controller, url, isReload) {
                    // YouTube: ловим pushState-навигацию (YouTube SPA)
                    if (url != null) {
                      urlController.text = url.toString();
                      _updateYouTubeState(url);
                      if (url.host.contains('youtube.com') && url.path.contains('/watch') && !_showInterceptor && !_showPlayer) {
                        setState(() {
                          _interceptedUrl = url.toString();
                          _currentReferer = url.toString();
                          _showInterceptor = true;
                        });
                        controller.evaluateJavascript(source: "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;e.pause();});");
                      }
                    }
                  },
                  shouldOverrideUrlLoading: (controller, navigationAction) async {
                    var url = navigationAction.request.url;
                    if (url == null) return NavigationActionPolicy.ALLOW;
                    
                    // YouTube: не грузим страницу — грузим about:blank и показываем шторку
                    if (url.host.contains('youtube.com') && url.path.contains('/watch') && !_showInterceptor && !_showPlayer) {
                      Future.microtask(() {
                        if (mounted) {
                          _interceptedUrl = url.toString();
                          _currentReferer = url.toString();
                          setState(() => _showInterceptor = true);
                        }
                      });
                      // Возвращаем ALLOW но тут же редиректим на blank чтобы не грузить ютуб
                      controller.loadUrl(urlRequest: URLRequest(url: WebUri("about:blank")));
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  },
                  shouldInterceptRequest: (controller, request) async {
                    var uri = request.url.toString().toLowerCase();
                    var method = request.method ?? "GET";
                    
                    // 1. Исключаем мусор, скрипты, картинки и статику
                    if (uri.contains('.js') || uri.contains('.css') || uri.contains('.jpg') || 
                        uri.contains('.png') || uri.contains('.gif') || uri.contains('.webp') || 
                        uri.contains('.woff') || uri.contains('.ttf') || uri.contains('.svg')) {
                      return null;
                    }

                    // 2. Ищем признаки медиа, исключая превьюшки и рекламу
                    bool isMedia = false;
                    if (uri.contains('.mp4') || uri.contains('.m3u8') || uri.contains('playlist.m3u8') || 
                        uri.contains('.mkv') || uri.contains('.webm') || uri.contains('.3gp') || 
                        uri.contains('.avi') || uri.contains('.flv')) {
                      if (!uri.contains('trailer') && !uri.contains('preview') && 
                          !uri.contains('banner') && !uri.contains('ad.mp4') && !uri.contains('promo')) {
                        isMedia = true;
                      }
                    }

                    // Исключаем чанки YouTube — серверу нужна ссылка на страницу, не на кусочек
                    if (uri.contains('googlevideo.com')) isMedia = false;

                    // Во время фонового скана Seasonvar берём URL, но не даём сайту качать видео
                    if (_scanningSeasonvar && isMedia) {
                      return WebResourceResponse(
                        contentType: "text/plain",
                        data: Uint8List.fromList([]),
                        statusCode: 200,
                      );
                    }

                    // Перехват медиа-запросов
                    if (method.toUpperCase() == "GET" && isMedia) {
                      
                      // Режим авто-переключения серий: сразу сжимаем без шторки
                      if (_waitingForNextEpisode) {
                        _waitingForNextEpisode = false;
                        _interceptedAlready = false;
                        Future.microtask(() {
                          if (mounted) {
                            _interceptedUrl = request.url.toString();
                            _currentReferer = urlController.text;
                            _startMagic();
                          }
                        });
                        return WebResourceResponse(
                          contentType: "text/plain",
                          data: Uint8List.fromList([]),
                          statusCode: 200
                        );
                      }
                      
                      // Обычный режим: показываем шторку выбора качества.
                      // _interceptedAlready — защита от повторного срабатывания на тот же поток
                      if (!_showInterceptor && !_showPlayer && !_interceptedAlready) {
                        _interceptedAlready = true;
                        Future.microtask(() {
                          if (mounted) {
                            setState(() {
                              _interceptedUrl = request.url.toString();
                              _currentReferer = urlController.text;
                              _showInterceptor = true;
                            });
                          }
                        });
                      }
                      
                      // Пустой ответ — чужой плеер не начинает жрать трафик
                      return WebResourceResponse(
                        contentType: "text/plain",
                        data: Uint8List.fromList([]),
                        statusCode: 200
                      );
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),

          // YouTube FAB убран — кнопка «Сжать» теперь в хедере

          // Interceptor Overlay
          if (_showInterceptor)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, -5))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('✨ Видеопоток перехвачен!', style: TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    const Text('Выберите качество сжатия:', style: TextStyle(color: Colors.grey, fontSize: 14)),
                    const SizedBox(height: 15),
                    
                    if (_presets.isEmpty)
                      const CircularProgressIndicator()
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _presets.map((preset) {
                            final isActive = _selectedQuality == preset.id;
                            return GestureDetector(
                              onTap: () => setState(() => _selectedQuality = preset.id),
                              child: Container(
                                margin: const EdgeInsets.only(right: 10),
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isActive ? Colors.orange.withOpacity(0.2) : const Color(0xFF2A2A2A),
                                  border: Border.all(color: isActive ? Colors.orange : const Color(0xFF555555), width: 2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(preset.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _showInterceptor = false;
                                _interceptedAlready = false;
                              });
                              // Возвращаем звук WebView — пользователь выбрал оригинал
                              webViewController?.evaluateJavascript(source:
                                "document.querySelectorAll('video,audio').forEach(function(e){e.muted=false;});");
                            },
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.grey)),
                            child: const Text('Оригинал'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _startMagic,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.black),
                            child: _isLoading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2)) : const Text('Сжать и смотреть ▶', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

           // Native Player Screen
          if (_showPlayer)
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    // Chewie плеер
                    Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.only(top: 40, left: 10, right: 10, bottom: 10),
                          color: Colors.black87,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                                    onPressed: _stopPlayer,
                                  ),
                                  Text(
                                    _seasonvarEpisodes.isNotEmpty
                                        ? 'Серия ${_seasonvarIndex + 1} / ${_seasonvarEpisodes.length} · $_selectedQuality'
                                        : 'Стриминг: $_selectedQuality',
                                    style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: _playNextEpisode,
                                    icon: const Icon(Icons.skip_next, color: Colors.orange),
                                    label: const Text('След. серия', style: TextStyle(color: Colors.orange)),
                                  ),
                                ],
                              ),
                              if (_seasonvarEpisodes.isNotEmpty)
                                SizedBox(
                                  height: 38,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _seasonvarEpisodes.length,
                                    itemBuilder: (context, index) {
                                      final active = index == _seasonvarIndex;
                                      return Padding(
                                        padding: const EdgeInsets.only(right: 6),
                                        child: OutlinedButton(
                                          onPressed: () => _playSeasonvarEpisode(index),
                                          style: OutlinedButton.styleFrom(
                                            backgroundColor: active ? Colors.orange : Colors.transparent,
                                            foregroundColor: active ? Colors.black : Colors.white,
                                            side: BorderSide(color: active ? Colors.orange : Colors.white38),
                                            padding: const EdgeInsets.symmetric(horizontal: 12),
                                          ),
                                          child: Text('${index + 1}'),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _chewieController != null && _videoController != null && _videoController!.value.isInitialized
                              ? Chewie(controller: _chewieController!)
                              : const Center(child: CircularProgressIndicator(color: Colors.orange)),
                        ),
                      ],
                    ),
                    // _MiniProgressOverlay убран — Chewie уже показывает время снизу
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// _MiniProgressOverlay удалён — Chewie показывает время в своих контролах
// (виджет существовал для HLS без duration, но создавал дублирующий таймер)
class _MiniProgressOverlay extends StatefulWidget { // оставлен для совместимости на случай отката
  final VideoPlayerController controller;
  const _MiniProgressOverlay({required this.controller});

  @override
  State<_MiniProgressOverlay> createState() => _MiniProgressOverlayState();
}

class _MiniProgressOverlayState extends State<_MiniProgressOverlay> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
    // Принудительный тик каждые 500мс — HLS без duration не дёргает listener
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer.cancel();
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.controller.value.position;
    final buf = widget.controller.value.buffered.isNotEmpty 
        ? widget.controller.value.buffered.last.end - pos 
        : Duration.zero;
    final buffering = widget.controller.value.isBuffering;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer, color: Colors.orange, size: 14),
          const SizedBox(width: 6),
          Text(
            _fmt(pos),
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          if (buffering) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
            ),
          ],
          const SizedBox(width: 8),
          Text(
            buf > Duration.zero ? '(буфер ${_fmt(buf)})' : '(длит. неизвестна)',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
