import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../models/youtube_video.dart';
import 'log_service.dart';

class YouTubeInnerTube {
  static const String _baseUrl = 'https://www.youtube.com/youtubei/v1/browse?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

  static const String _searchUrl = 'https://www.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

  static Future<List<YouTubeVideo>> fetchVideos({
    required String token,
    required String browseId,
  }) async {
    final payload = {
      "context": {
        "client": {
          "clientName": "WEB",
          "clientVersion": "2.20230728.00.00",
          "hl": "ru",
          "gl": "RU"
        }
      },
      "browseId": browseId
    };

    return _sendRequest(token, payload, _baseUrl);
  }

  static Future<List<YouTubeVideo>> searchVideos({
    required String token,
    required String query,
  }) async {
    final payload = {
      "context": {
        "client": {
          "clientName": "WEB",
          "clientVersion": "2.20230728.00.00",
          "hl": "ru",
          "gl": "RU"
        }
      },
      "query": query
    };

    return _sendRequest(token, payload, _searchUrl);
  }

  static Future<List<YouTubeVideo>> _sendRequest(String token, Map<String, dynamic> payload, String url) async {
    final headers = {
      'Content-Type': 'application/json',
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/',
    };

    if (token.isNotEmpty) {
      if (token.contains('SAPISID=')) {
        // Это Cookie
        headers['Cookie'] = token;
        final match = RegExp(r'SAPISID=([^;]+)').firstMatch(token);
        if (match != null) {
          final sapisid = match.group(1)!;
          final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final input = '$time $sapisid https://www.youtube.com';
          final hash = sha1.convert(utf8.encode(input)).toString();
          headers['Authorization'] = 'SAPISIDHASH ${time}_$hash';
        }
      } else {
        // Это Bearer токен
        headers['Authorization'] = 'Bearer $token';
      }
    }

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        throw Exception('InnerTube error: ${response.statusCode} - ${response.body}');
      }

      final data = jsonDecode(response.body);
      return _extractVideos(data);
    } catch (e) {
      LogService.error(LogService.youtube, 'InnerTube error for payload $payload', e);
      rethrow;
    }
  }

  static List<YouTubeVideo> _extractVideos(Map<String, dynamic> data) {
    final List<YouTubeVideo> videos = [];
    final Set<String> seenIds = {};

    void searchTree(dynamic node) {
      if (node == null) return;
      if (node is List) {
        for (var item in node) {
          searchTree(item);
        }
        return;
      }
      if (node is Map) {
        final map = node as Map<String, dynamic>;
        
        // Поиск элементов видео в разных структурах (gridVideoRenderer, videoRenderer, reelItemRenderer - для Shorts)
        final renderer = map['gridVideoRenderer'] ?? map['videoRenderer'] ?? map['compactVideoRenderer'] ?? map['reelItemRenderer'];
        
        if (renderer != null && renderer is Map<String, dynamic>) {
          final videoId = renderer['videoId']?.toString();
          if (videoId != null && videoId.isNotEmpty && !seenIds.contains(videoId)) {
            seenIds.add(videoId);
            
            // Заголовок
            String title = '';
            final titleRuns = renderer['title']?['runs'] as List?;
            if (titleRuns != null && titleRuns.isNotEmpty) {
              title = titleRuns.first['text']?.toString() ?? '';
            } else if (renderer['title']?['simpleText'] != null) {
              title = renderer['title']['simpleText'].toString();
            } else if (renderer['headline']?['simpleText'] != null) {
              title = renderer['headline']['simpleText'].toString();
            }

            // Канал
            String channel = '';
            final ownerRuns = (renderer['ownerText'] ?? renderer['shortBylineText'])?['runs'] as List?;
            if (ownerRuns != null && ownerRuns.isNotEmpty) {
              channel = ownerRuns.first['text']?.toString() ?? '';
            }

            // Просмотры
            String views = '';
            final viewCountText = renderer['viewCountText']?['simpleText']?.toString() ?? renderer['viewCountText']?['runs']?.first?['text']?.toString();
            if (viewCountText != null) {
              views = viewCountText;
            }

            // Время публикации
            String published = '';
            final publishedTimeText = renderer['publishedTimeText']?['simpleText']?.toString() ?? renderer['publishedTimeText']?['runs']?.first?['text']?.toString();
            if (publishedTimeText != null) {
              published = publishedTimeText;
            }

            // Превью
            String thumbnail = '';
            final thumbnails = renderer['thumbnail']?['thumbnails'] as List?;
            if (thumbnails != null && thumbnails.isNotEmpty) {
              thumbnail = thumbnails.last['url']?.toString() ?? '';
            }

            // Длительность
            int duration = 0;
            final lengthText = renderer['lengthText']?['simpleText']?.toString() ?? renderer['lengthText']?['accessibility']?['accessibilityData']?['label']?.toString();
            if (lengthText != null) {
              // Пытаемся распарсить "MM:SS" или "HH:MM:SS"
              final parts = lengthText.split(':').map((e) => int.tryParse(e) ?? 0).toList();
              if (parts.length == 2) {
                duration = parts[0] * 60 + parts[1];
              } else if (parts.length == 3) {
                duration = parts[0] * 3600 + parts[1] * 60 + parts[2];
              }
            }

            videos.add(YouTubeVideo(
              id: videoId,
              title: title.isNotEmpty ? title : 'YouTube Video',
              channel: channel,
              viewsText: views,
              publishedText: published,
              duration: duration,
              thumbnail: thumbnail,
              url: 'https://www.youtube.com/watch?v=$videoId',
            ));
          }
        }
        
        map.values.forEach(searchTree);
      }
    }

    searchTree(data);
    return videos;
  }
}
