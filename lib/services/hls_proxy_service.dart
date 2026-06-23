import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Локальный HLS-прокси с принудительной предзагрузкой сегментов.
///
/// media_kit/mpv на слабом канале может читать HLS строго по одному чанку.
/// Этот прокси сам скачивает будущие чанки в temp-кэш, а плееру отдаёт уже
/// локальный playlist/chunk URL через 127.0.0.1.
class HlsProxyService {
  static final HlsProxyService instance = HlsProxyService._();
  HlsProxyService._();

  static const _playlistName = 'playlist.m3u8';
  static const _startupPrefetchCount = 24;
  static const _prefetchCount = 60;
  static const _maxConcurrentDownloads = 6;

  HttpServer? _server;
  Timer? _playlistTimer;

  String _baseUrl = '';
  String _cacheDir = '';
  String _playlistBody = '';
  String? _initName;
  int? _lastRequestedChunkIndex;

  final List<String> _chunkNames = [];
  final Map<String, String> _diskCache = {};
  final Map<String, Future<File?>> _activeDownloads = {};
  final Queue<String> _downloadQueue = Queue<String>();
  final Set<String> _queuedDownloads = <String>{};

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;
  String get localPlaylistUrl =>
      isRunning ? 'http://127.0.0.1:$port/$_playlistName' : '';

  Future<void> start(String originalHlsUrl) async {
    await stop();

    _baseUrl = originalHlsUrl.substring(0, originalHlsUrl.lastIndexOf('/'));
    _playlistBody = '';
    _initName = null;
    _lastRequestedChunkIndex = null;
    _chunkNames.clear();
    _diskCache.clear();
    _activeDownloads.clear();
    _downloadQueue.clear();
    _queuedDownloads.clear();

    final temp = await getTemporaryDirectory();
    final proxyDir = Directory('${temp.path}/vakh_hls_proxy');
    if (proxyDir.existsSync()) {
      try {
        proxyDir.deleteSync(recursive: true);
      } catch (_) {}
    }
    proxyDir.createSync(recursive: true);
    _cacheDir = proxyDir.path;

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) => unawaited(_handleRequest(request)));
    debugPrint('[HlsProxy] Started on 127.0.0.1:$port');

    unawaited(_refreshPlaylist());
    _playlistTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshPlaylist()),
    );
  }

  Future<void> stop() async {
    _playlistTimer?.cancel();
    _playlistTimer = null;
    await _server?.close(force: true);
    _server = null;
    _activeDownloads.clear();
    _downloadQueue.clear();
    _queuedDownloads.clear();

    try {
      final proxyDir = Directory(_cacheDir);
      if (proxyDir.existsSync()) proxyDir.deleteSync(recursive: true);
    } catch (_) {}

    if (_cacheDir.isNotEmpty) debugPrint('[HlsProxy] Stopped');
    _cacheDir = '';
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _addCommonHeaders(request.response.headers);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final filename = request.uri.pathSegments.isEmpty
        ? _playlistName
        : request.uri.pathSegments.last;

    if (filename.endsWith('.m3u8')) {
      await _servePlaylist(request);
      return;
    }

    if (filename.startsWith('chunk_')) {
      final index = _chunkNames.indexOf(filename);
      if (index >= 0) _lastRequestedChunkIndex = index;
      _schedulePrefetch();
    }

    try {
      final file = await _getOrDownload(filename, priority: true);
      if (file == null || !file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      await _serveFile(request, file, filename);
      if (filename.startsWith('chunk_')) _schedulePrefetch();
    } catch (e) {
      debugPrint('[HlsProxy] Serve failed $filename: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  Future<void> _servePlaylist(HttpRequest request) async {
    final freshBody = await _refreshPlaylist();
    final body = _rewritePlaylist(freshBody ?? _playlistBody);
    if (body.isEmpty) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }

    final bytes = utf8.encode(body);
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl');
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    request.response.contentLength = bytes.length;
    if (request.method != 'HEAD') request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _serveFile(
    HttpRequest request,
    File file,
    String filename,
  ) async {
    final total = file.lengthSync();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = total - 1;
    var partial = false;

    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (match != null) {
        start = int.parse(match.group(1)!);
        if ((match.group(2) ?? '').isNotEmpty) {
          end = int.parse(match.group(2)!);
        }
        if (start >= total) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers
              .set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await request.response.close();
          return;
        }
        if (end >= total) end = total - 1;
        partial = true;
      }
    }

    final length = end - start + 1;
    request.response.statusCode =
        partial ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.contentType = _contentTypeFor(filename);
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(
      HttpHeaders.cacheControlHeader,
      'public, max-age=31536000, immutable',
    );
    if (partial) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
    }
    request.response.contentLength = length;

    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }

    await file.openRead(start, end + 1).pipe(request.response);
  }

  Future<String?> _refreshPlaylist() async {
    final client = _createClient();
    try {
      final req = await client.getUrl(Uri.parse('$_baseUrl/$_playlistName'));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != HttpStatus.ok) return null;
      final body = await resp.transform(utf8.decoder).join();
      _playlistBody = body;
      _extractMediaNames(body);
      _schedulePrefetch();
      return body;
    } catch (e) {
      debugPrint('[HlsProxy] Playlist refresh failed: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  void _extractMediaNames(String body) {
    final chunks = <String>[];
    String? initName;

    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-MAP')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match != null) initName = _localName(match.group(1)!);
        continue;
      }

      if (!line.startsWith('#')) {
        final name = _localName(line);
        if (name.startsWith('chunk_')) chunks.add(name);
      }
    }

    _initName = initName;
    _chunkNames
      ..clear()
      ..addAll(chunks);
  }

  String _rewritePlaylist(String body) {
    if (body.isEmpty) return body;
    final lines = <String>[];
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('#EXT-X-MAP')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match != null) {
          lines.add(
              line.replaceFirst(match.group(1)!, _localName(match.group(1)!)));
          continue;
        }
      }
      if (line.isNotEmpty && !line.startsWith('#')) {
        lines.add(_localName(line));
      } else {
        lines.add(rawLine);
      }
    }
    return lines.join('\n');
  }

  void _schedulePrefetch() {
    final initName = _initName;
    if (initName != null) _enqueueDownload(initName);

    if (_chunkNames.isEmpty) {
      _pumpDownloads();
      return;
    }

    final lastIndex = _lastRequestedChunkIndex;
    final startIndex = lastIndex == null ? 0 : lastIndex + 1;
    final count = lastIndex == null ? _startupPrefetchCount : _prefetchCount;
    for (final chunk in _chunkNames.skip(startIndex).take(count)) {
      _enqueueDownload(chunk);
    }
    _pumpDownloads();
  }

  Future<File?> _getOrDownload(String filename, {required bool priority}) {
    final cachedPath = _diskCache[filename];
    if (cachedPath != null) {
      final file = File(cachedPath);
      if (file.existsSync()) return Future.value(file);
    }

    final active = _activeDownloads[filename];
    if (active != null) return active;

    if (priority) return _startDownload(filename);

    _enqueueDownload(filename);
    _pumpDownloads();
    return _activeDownloads[filename] ?? Future<File?>.value(null);
  }

  void _enqueueDownload(String filename) {
    if (filename.isEmpty || filename.endsWith('.m3u8')) return;
    if (_diskCache.containsKey(filename) ||
        _activeDownloads.containsKey(filename) ||
        _queuedDownloads.contains(filename)) {
      return;
    }
    _queuedDownloads.add(filename);
    _downloadQueue.add(filename);
  }

  void _pumpDownloads() {
    while (_activeDownloads.length < _maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final filename = _downloadQueue.removeFirst();
      _queuedDownloads.remove(filename);
      if (_diskCache.containsKey(filename) ||
          _activeDownloads.containsKey(filename)) {
        continue;
      }
      _startDownload(filename);
    }
  }

  Future<File?> _startDownload(String filename) {
    final future = _downloadFile(filename).whenComplete(() {
      _activeDownloads.remove(filename);
      _pumpDownloads();
    });
    _activeDownloads[filename] = future;
    return future;
  }

  Future<File?> _downloadFile(String filename) async {
    final client = _createClient();
    final targetUrl = '$_baseUrl/$filename';

    try {
      final req = await client.getUrl(Uri.parse(targetUrl));
      final resp = await req.close().timeout(const Duration(seconds: 90));
      if (resp.statusCode != HttpStatus.ok) return null;

      final filePath = '$_cacheDir${Platform.pathSeparator}$filename';
      final tempPath = '$filePath.part';
      final tempFile = File(tempPath);
      final file = File(filePath);
      await tempFile.parent.create(recursive: true);

      final sink = tempFile.openWrite();
      await resp.pipe(sink);
      if (file.existsSync()) file.deleteSync();
      tempFile.renameSync(filePath);

      _diskCache[filename] = filePath;
      debugPrint('[HlsProxy] Cached $filename (${file.lengthSync()} bytes)');
      return file;
    } catch (e) {
      debugPrint('[HlsProxy] Download failed $filename: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _localName(String uriText) {
    final uri = Uri.tryParse(uriText.trim());
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return uriText.split('?').first.split('/').last.trim();
  }

  ContentType _contentTypeFor(String filename) {
    if (filename.endsWith('.mp4') || filename.endsWith('.m4s')) {
      return ContentType('video', 'mp4');
    }
    if (filename.endsWith('.ts')) return ContentType('video', 'mp2t');
    return ContentType.binary;
  }

  void _addCommonHeaders(HttpHeaders headers) {
    headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    headers.set(
        HttpHeaders.accessControlAllowMethodsHeader, 'GET, HEAD, OPTIONS');
    headers.set(
        HttpHeaders.accessControlAllowHeadersHeader, 'Range, Content-Type');
    headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  }

  static HttpClient _createClient() {
    final client = HttpClient();
    if (Platform.isWindows || Platform.isAndroid) {
      client.findProxy = (uri) => 'PROXY 127.0.0.1:1080; DIRECT';
    }
    client.badCertificateCallback = (_, __, ___) => true;
    client.connectionTimeout = const Duration(seconds: 20);
    return client;
  }
}
