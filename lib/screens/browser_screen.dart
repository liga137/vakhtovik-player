import 'dart:async';
import 'dart:typed_data';
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

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    try {
      final presets = await ApiService.getPresets();
      if (mounted) {
        setState(() {
          _presets = presets;
          if (presets.isNotEmpty) _selectedQuality = presets.first.id;
        });
      }
    } catch (e) {
      print("Failed to load presets: $e");
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
    
    // Ставим флаг: следующие перехваченные URL обрабатываем автоматически
    _waitingForNextEpisode = true;
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Переключаю серию...'), duration: Duration(seconds: 1))
    );
    
    // Инжектим клик по кнопке «Следующая серия»
    webViewController!.evaluateJavascript(source: """
      (function() {
        // ===== SEASONVAR: плейлист #htmlPlayer_playlist =====
        var playlist = document.querySelector('#htmlPlayer_playlist');
        if (playlist) {
          var items = playlist.querySelectorAll('li, div, a, span');
          for (var i = 0; i < items.length; i++) {
            var cls = items[i].className || '';
            // Ищем активный/текущий эпизод
            if (cls.includes('active') || cls.includes('current') || cls.includes('playing') || cls.includes('sel')) {
              if (i + 1 < items.length) {
                items[i + 1].click();
                return 'seasonvar-playlist-next';
              }
            }
          }
          // Если не нашли активный — просто кликаем первый (сброс)
          if (items.length > 0) {
            items[0].click();
            return 'seasonvar-playlist-first';
          }
        }
        
        // ===== Резерв: поиск кнопок «следующая» =====
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
        return 'not-found';
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

      // Ждём первый кадр чтобы получить реальный aspectRatio
      await Future.delayed(const Duration(milliseconds: 500));
      
      final ar = _videoController!.value.aspectRatio > 0 
          ? _videoController!.value.aspectRatio 
          : 16 / 9; // fallback 16:9 если HLS не дал размер

      final dur = _videoController!.value.duration;

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
      _videoController!.addListener(() {
        if (!_videoController!.value.isInitialized) return;
        final pos = _videoController!.value.position;
        final dur = _videoController!.value.duration;
        
        // Способ 1: точное знание длительности
        if (dur > Duration.zero && pos >= dur - const Duration(seconds: 1) && pos > Duration.zero) {
          _playNextEpisode();
          return;
        }
        // Способ 2: HLS без duration — ждём что видео играло хотя бы 10 сек и позиция застыла
        if (dur == Duration.zero && _videoController!.value.isPlaying) {
          _lastPosition = pos;
          // Проверим через секунду — если позиция не изменилась, считаем что конец
          Future.delayed(const Duration(seconds: 2), () {
            if (_videoController != null && 
                _videoController!.value.isInitialized &&
                _videoController!.value.duration == Duration.zero &&
                _videoController!.value.position == _lastPosition &&
                _lastPosition > const Duration(seconds: 5)) {
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
      }
    } catch (e) {
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
    
    _interceptedUrl = ytUrl;
    _currentReferer = ytUrl;
    setState(() => _showInterceptor = true);
  }

  void _updateYouTubeState(Uri url) {
    final isYT = url.host.contains('youtube.com') && url.path.contains('/watch');
    if (isYT != _onYouTube) {
      setState(() => _onYouTube = isYT);
    }
    // На всех страницах youtube.com показываем переключатель режима
    if (url.host.contains('youtube.com') && !_onYouTube) {
      setState(() => _onYouTube = true);
    } else if (!url.host.contains('youtube.com') && _onYouTube) {
      setState(() => _onYouTube = false);
    }
  }

  void _toggleYouTubeCompressMode() {
    if (webViewController == null) return;
    final mode = _compressMode;
    webViewController!.evaluateJavascript(source: """
      (function() {
        if ($mode) {
          // Добавляем кнопки «▶ Сжать» ко всем ссылкам на видео
          var links = document.querySelectorAll('a[href*="/watch"]');
          for (var i = 0; i < links.length; i++) {
            if (links[i].querySelector('.vakh-compress-btn')) continue;
            var btn = document.createElement('span');
            btn.className = 'vakh-compress-btn';
            btn.innerHTML = '&#9654; Сжать';
            btn.style.cssText = 'display:inline-block;background:#e53935;color:#fff;padding:3px 10px;border-radius:4px;font:bold 11px sans-serif;cursor:pointer;margin:0 0 0 6px;white-space:nowrap;box-shadow:0 1px 3px rgba(0,0,0,0.4);';
            btn.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              window.location.href = links[i].href;
            });
            // Вставляем после названия видео
            var title = links[i].querySelector('#video-title, .ytd-rich-grid-media, yt-formatted-string');
            if (title) title.parentElement.appendChild(btn);
            else links[i].appendChild(btn);
          }
        } else {
          // Убираем все кнопки
          var btns = document.querySelectorAll('.vakh-compress-btn');
          for (var j = 0; j < btns.length; j++) btns[j].remove();
        }
      })();
    """);
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
                    // Режим YouTube: «Оригинал» / «Сжатое»
                    if (_onYouTube)
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
                    useOnLoadResource: true,
                    mediaPlaybackRequiresUserGesture: false,
                    // Сохранение кук и сессий для ВСЕХ сайтов
                    domStorageEnabled: true,
                    databaseEnabled: true,
                    cacheEnabled: true,
                    javaScriptEnabled: true,
                    transparentBackground: true,
                  ),
                  onWebViewCreated: (controller) {
                    webViewController = controller;
                  },
                  onLoadStop: (controller, url) {
                    if (url != null) {
                      urlController.text = url.toString();
                       // Filmix: инжектим скрипт (балансер + автослив кук если залогинен)
                       if (url.host.contains('filmix')) {
                         // Куки НЕ инжектим — WebView сам хранит сессию после ручного входа.
                         // Если не залогинен — балансер Kodik подставит плеер.
                         controller.evaluateJavascript(source: FilmixAuth.getInjectionScript());
                       }
                       // YouTube: инжектим ховер-кнопку на всех страницах
                       if (url.host.contains('youtube.com')) {
                         controller.evaluateJavascript(source: YouTubeHover.getInjectionJS());
                       }
                       // YouTube fallback — если страница /watch загрузилась, глушим и предлагаем сжать
                       if (url.host.contains('youtube.com') && url.path.contains('/watch') && !_showInterceptor && !_showPlayer) {
                        setState(() {
                          _interceptedUrl = url.toString();
                          _currentReferer = url.toString();
                          _showInterceptor = true;
                          _onYouTube = true;
                        });
                        controller.evaluateJavascript(source: "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;e.pause();});");
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
                    
                    // Перехват YouTube: не грузим страницу, сразу предлагаем сжать
                    if (url.host.contains('youtube.com') && url.path.contains('/watch') && !_showInterceptor) {
                      Future.microtask(() {
                        if (mounted) {
                          _interceptedUrl = url.toString();
                          _currentReferer = url.toString();
                          setState(() => _showInterceptor = true);
                        }
                      });
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
                      return null; // пропускаем как есть
                    }

                    // 2. Ищем признаки медиа, исключая фоновые превьюшки и рекламу
                    bool isMedia = false;
                    if (uri.contains('.mp4') || uri.contains('.m3u8') || uri.contains('playlist.m3u8') || 
                        uri.contains('.mkv') || uri.contains('.webm') || uri.contains('.3gp') || 
                        uri.contains('.avi') || uri.contains('.flv')) {
                      
                      // Защита от ложных срабатываний (на превьюшки и баннеры)
                      if (!uri.contains('trailer') && !uri.contains('preview') && 
                          !uri.contains('banner') && !uri.contains('ad.mp4') && !uri.contains('promo')) {
                        isMedia = true;
                      }
                    }

                    // Исключаем системные чанки YouTube (googlevideo.com), так как yt-dlp 
                    // на сервере нужна ссылка на саму страницу, а не на отдельный кусочек видео.
                    if (uri.contains('googlevideo.com')) {
                      isMedia = false;
                    }

                    // Перехват сырых медиа-запросов (даже из чужих плееров и iframe)
                    if (method.toUpperCase() == "GET" && isMedia) {
                      
                      // Режим авто-переключения серий: не показываем шторку, сразу сжимаем
                      if (_waitingForNextEpisode) {
                        _waitingForNextEpisode = false;
                        Future.microtask(() {
                          if (mounted) {
                            _interceptedUrl = request.url.toString();
                            _currentReferer = urlController.text;
                            // Не показываем шторку — сразу запускаем сжатие
                            _startMagic();
                          }
                        });
                        return WebResourceResponse(
                          contentType: "text/plain",
                          data: Uint8List.fromList([]),
                          statusCode: 200
                        );
                      }
                      
                      // Обычный режим: показываем шторку выбора качества
                      if (!_showInterceptor && !_showPlayer) {
                        // Используем Future.microtask чтобы безопасно вызвать setState из фонового потока WebView
                        Future.microtask(() {
                          setState(() {
                            _interceptedUrl = request.url.toString();
                            _currentReferer = urlController.text;
                            _showInterceptor = true;
                          });
                        });
                      }
                      
                      // Возвращаем "пустой" ответ, чтобы чужой плеер не начал жрать трафик
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

          // YouTube FAB: большая плавающая кнопка поверх WebView
          if (_onYouTube && !_showInterceptor && !_showPlayer)
            Positioned(
              bottom: 80,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Кнопка сжать
                  FloatingActionButton.extended(
                    heroTag: 'youtube',
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    icon: const Icon(Icons.compress),
                    label: const Text('Сжать видео', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: _compressYouTube,
                  ),
                  const SizedBox(height: 8),
                  // Подсказка
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'YouTube не перехватывается авто — нажми сюда',
                      style: TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),

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
                            onPressed: () => setState(() => _showInterceptor = false),
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
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back, color: Colors.white),
                                onPressed: _stopPlayer,
                              ),
                              Text('Стриминг: $_selectedQuality', style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _playNextEpisode,
                                icon: const Icon(Icons.skip_next, color: Colors.orange),
                                label: const Text('След. серия', style: TextStyle(color: Colors.orange)),
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
                    // Аварийный таймер + буфер: показываем если HLS без duration
                    if (_videoController != null && _videoController!.value.isInitialized && 
                        _videoController!.value.duration == Duration.zero)
                      Positioned(
                        bottom: 40,
                        left: 20,
                        right: 20,
                        child: _MiniProgressOverlay(controller: _videoController!),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Аварийный индикатор времени и буфера для HLS без duration
class _MiniProgressOverlay extends StatefulWidget {
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
