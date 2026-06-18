import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Локальный прокси-сервер для многопоточной (IDM-style) загрузки HLS.
/// Запускается на 127.0.0.1:0 (динамический порт) и агрессивно скачивает
/// следующие чанки в фоновых потоках, забивая канал спутника на 100%.
class HlsProxyService {
  static final HlsProxyService instance = HlsProxyService._();
  HlsProxyService._();

  HttpServer? _server;
  int get port => _server?.port ?? 0;

  String _baseUrl = '';
  String _cacheDir = '';
  
  // Настройки "разгона" (IDM)
  final int _prefetchCount = 4;
  
  final List<String> _chunkNames = [];
  final Map<String, String> _diskCache = {};
  final Map<String, Future<File?>> _activeDownloads = {};

  bool get isRunning => _server != null;

  /// Запускает локальный сервер и привязывает его к HLS URL на VPS.
  Future<void> start(String originalHlsUrl) async {
    _baseUrl = originalHlsUrl.substring(0, originalHlsUrl.lastIndexOf('/'));
    _chunkNames.clear();
    _diskCache.clear();
    _activeDownloads.clear();

    final temp = await getTemporaryDirectory();
    final proxyDir = Directory('${temp.path}/vakh_hls_proxy');
    if (proxyDir.existsSync()) {
      try {
        proxyDir.deleteSync(recursive: true);
      } catch (_) {}
    }
    proxyDir.createSync(recursive: true);
    _cacheDir = proxyDir.path;

    _server?.close(force: true);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    print('[HlsProxy] Started on 127.0.0.1:$port');

    _server!.listen((HttpRequest request) {
      _handleRequest(request);
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _activeDownloads.clear();
    try {
      final proxyDir = Directory(_cacheDir);
      if (proxyDir.existsSync()) proxyDir.deleteSync(recursive: true);
    } catch (_) {}
    print('[HlsProxy] Stopped');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final filename = request.uri.pathSegments.last;
    
    // 1. Плейлист запрашиваем напрямую (он может обновляться)
    if (filename.endsWith('.m3u8')) {
      try {
        final client = _createClient();
        final targetUrl = '$_baseUrl/$filename';
        final req = await client.getUrl(Uri.parse(targetUrl));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        
        if (filename == 'playlist.m3u8') {
          _extractChunkNames(body);
        }
        
        request.response.statusCode = resp.statusCode;
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        // Разрешаем CORS на всякий случай
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.write(body);
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
      return;
    }

    // 2. Чанки или init.mp4 — отдаём из кэша или скачиваем
    try {
      final file = await _getOrDownloadChunk(filename);
      if (file != null && file.existsSync()) {
        request.response.statusCode = 200;
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        
        if (filename.endsWith('.mp4') || filename.endsWith('.m4s')) {
          request.response.headers.contentType = ContentType('video', 'mp4');
        } else {
          request.response.headers.contentType = ContentType('video', 'mp2t');
        }
        
        request.response.contentLength = file.lengthSync();
        await file.openRead().pipe(request.response);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }

    // 3. Агрессивно предзагружаем следующие N чанков (Магия IDM!)
    if (filename.startsWith('chunk_')) {
      _triggerPrefetch(filename);
    }
  }

  Future<File?> _getOrDownloadChunk(String filename) {
    // 1. Уже скачан?
    if (_diskCache.containsKey(filename)) {
      final f = File(_diskCache[filename]!);
      if (f.existsSync()) return Future.value(f);
    }

    // 2. Уже качается в фоне? Присоединяемся к ожиданию!
    if (_activeDownloads.containsKey(filename)) {
      return _activeDownloads[filename]!;
    }

    // 3. Качаем сами
    final future = _downloadChunk(filename).then((file) {
      _activeDownloads.remove(filename);
      return file;
    });

    _activeDownloads[filename] = future;
    return future;
  }

  Future<File?> _downloadChunk(String filename) async {
    final client = _createClient();
    final targetUrl = '$_baseUrl/$filename';
    
    try {
      final req = await client.getUrl(Uri.parse(targetUrl));
      final resp = await req.close();
      
      if (resp.statusCode != 200) {
        client.close(force: true);
        return null;
      }
      
      final filePath = '$_cacheDir/$filename';
      final file = File(filePath);
      final sink = file.openWrite();
      await resp.pipe(sink);
      
      _diskCache[filename] = filePath;
      print('[HlsProxy] Downloaded $filename');
      return file;
    } catch (e) {
      print('[HlsProxy] Failed to download $filename: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  void _triggerPrefetch(String currentFilename) {
    if (_chunkNames.isEmpty) return;
    
    final idx = _chunkNames.indexOf(currentFilename);
    if (idx == -1) return;
    
    // Берём следующие N чанков
    final nextChunks = _chunkNames.skip(idx + 1).take(_prefetchCount).toList();
    
    for (final chunk in nextChunks) {
      if (!_diskCache.containsKey(chunk) && !_activeDownloads.containsKey(chunk)) {
        print('[HlsProxy] Prefetching $chunk...');
        _getOrDownloadChunk(chunk);
      }
    }
  }

  void _extractChunkNames(String m3u8Body) {
    _chunkNames.clear();
    final lines = m3u8Body.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        _chunkNames.add(trimmed);
      }
    }
  }

  static HttpClient _createClient() {
    final client = HttpClient();
    if (Platform.isWindows || Platform.isAndroid) {
      client.findProxy = (uri) => 'PROXY 127.0.0.1:1080; DIRECT';
    }
    client.badCertificateCallback = (_, __, ___) => true;
    client.connectionTimeout = const Duration(seconds: 15);
    return client;
  }
}
