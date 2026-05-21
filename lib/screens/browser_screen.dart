import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../services/api_service.dart';
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

  // Скрипт для авто-переключения серии (кликает по кнопкам "Следующая серия" на известных сайтах)
  void _playNextEpisode() {
    if (webViewController != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Включаю следующую серию...'), duration: Duration(seconds: 2))
      );
      webViewController!.evaluateJavascript(source: """
        (function() {
          // Seasonvar
          var svNext = document.querySelector('.pgs-player-next');
          if (svNext) { svNext.click(); return true; }
          // Filmix (примерные классы)
          var fxNext = document.querySelector('.icon-next') || document.querySelector('.next-btn');
          if (fxNext) { fxNext.click(); return true; }
          // Любой элемент с текстом "следующая"
          var elements = document.getElementsByTagName('*');
          for (var i = 0; i < elements.length; i++) {
            var text = elements[i].innerText || elements[i].textContent;
            if (text && text.toLowerCase().includes('следующая') && elements[i].onclick) {
              elements[i].click();
              return true;
            }
          }
          return false;
        })();
      """);
      // Закрываем текущий плеер, ждем перехвата новой ссылки
      _stopPlayer();
    }
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

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoController!.value.aspectRatio,
        allowFullScreen: true,
        allowMuting: true,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              errorMessage,
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
        customControls: const MaterialControls(),
      );

      // Слушаем окончание видео для автопереключения
      _videoController!.addListener(() {
        if (_videoController!.value.isInitialized && 
            _videoController!.value.position >= _videoController!.value.duration &&
            _videoController!.value.duration > Duration.zero) {
          // Видео закончилось
          _playNextEpisode();
        }
      });

      if (mounted) {
        setState(() {
          _showInterceptor = false;
          _isLoading = false;
          _showPlayer = true;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
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
                    mediaPlaybackRequiresUserGesture: false,
                    domStorageEnabled: true, // Включаем кэш и локальное хранилище для ускорения загрузки
                    databaseEnabled: true,
                    javaScriptEnabled: true,
                    transparentBackground: true,
                  ),
                  onWebViewCreated: (controller) {
                    webViewController = controller;
                  },
                  onLoadStop: (controller, url) {
                    if (url != null) {
                      urlController.text = url.toString();
                    }
                  },
                  shouldOverrideUrlLoading: (controller, navigationAction) async {
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

                    // Перехват сырых медиа-запросов (даже из чужих плееров и iframe)
                    if (method.toUpperCase() == "GET" && isMedia) {
                      
                      // Чтобы шторка не прыгала по 100 раз на каждый чанк
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
                child: Column(
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
              ),
            ),
        ],
      ),
    );
  }
}
