import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:video_player/video_player.dart';
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
    super.dispose();
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
      _videoController = VideoPlayerController.networkUrl(Uri.parse(hlsUrl));
      await _videoController!.initialize();

      if (mounted) {
        setState(() {
          _showInterceptor = false;
          _isLoading = false;
          _showPlayer = true;
        });
        _videoController!.play();
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  void _stopPlayer() {
    _videoController?.pause();
    _videoController?.dispose();
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
                    var uri = request.url.toString();
                    var method = request.method ?? "GET";
                    
                    // Перехват сырых медиа-запросов (даже из чужих плееров и iframe)
                    if (method.toUpperCase() == "GET" && 
                       (uri.contains('.mp4') || uri.contains('.m3u8') || uri.contains('playlist.m3u8') || 
                        uri.contains('.mkv') || uri.contains('.webm') || uri.contains('.3gp') || 
                        uri.contains('.avi') || uri.contains('.flv') || uri.contains('video'))) {
                      
                      // Чтобы шторка не прыгала по 100 раз на каждый чанк
                      if (!_showInterceptor && !_showPlayer) {
                        // Используем Future.microtask чтобы безопасно вызвать setState из фонового потока WebView
                        Future.microtask(() {
                          setState(() {
                            _interceptedUrl = uri;
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
                        ],
                      ),
                    ),
                    Expanded(
                      child: _videoController != null && _videoController!.value.isInitialized
                          ? AspectRatio(
                              aspectRatio: _videoController!.value.aspectRatio,
                              child: VideoPlayer(_videoController!),
                            )
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
