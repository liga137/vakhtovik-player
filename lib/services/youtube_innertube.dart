import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/youtube_video.dart';
import 'log_service.dart';

class YouTubeInnerTube {
  static const String _homeUrl = 'https://www.youtube.com/';
  static const String _subsUrl = 'https://www.youtube.com/feed/subscriptions';
  static const String _searchUrl = 'https://www.youtube.com/results';

  static Future<List<YouTubeVideo>> fetchHome({required String token}) async {
    return _fetchHtml(token, _homeUrl);
  }

  static Future<List<YouTubeVideo>> fetchSubscriptions(
      {required String token}) async {
    return _fetchHtml(token, _subsUrl);
  }

  static Future<List<YouTubeVideo>> fetchShorts({required String token}) async {
    return searchVideos(token: token, query: 'Shorts');
  }

  static Future<List<YouTubeVideo>> searchVideos(
      {required String token, required String query}) async {
    final uri =
        Uri.parse(_searchUrl).replace(queryParameters: {'search_query': query});
    return _fetchHtml(token, uri.toString());
  }

  static Future<List<YouTubeVideo>> _fetchHtml(String token, String url) async {
    final headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
    };

    if (token.isNotEmpty) {
      if (token.contains('SAPISID=')) {
        headers['Cookie'] = token;
      }
    }

    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: headers,
          )
          .timeout(const Duration(seconds: 35));

      if (response.statusCode != 200) {
        throw Exception('HTTP error: ${response.statusCode}');
      }

      final match = RegExp(r'var ytInitialData = (\{.*?\});</script>')
          .firstMatch(response.body);
      if (match == null) {
        throw Exception(
            'ytInitialData не найден. Возможно, изменилась верстка YouTube.');
      }

      final data = jsonDecode(match.group(1)!);
      return _extractVideos(data);
    } catch (e) {
      LogService.error(LogService.youtube, 'HTML parse error for $url', e);
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

        final renderer = map['gridVideoRenderer'] ??
            map['videoRenderer'] ??
            map['compactVideoRenderer'] ??
            map['reelItemRenderer'];

        if (renderer != null && renderer is Map<String, dynamic>) {
          final videoId = renderer['videoId']?.toString();
          if (videoId != null &&
              videoId.isNotEmpty &&
              !seenIds.contains(videoId)) {
            seenIds.add(videoId);

            String title = '';
            final titleRuns = renderer['title']?['runs'] as List?;
            if (titleRuns != null && titleRuns.isNotEmpty) {
              title = titleRuns.first['text']?.toString() ?? '';
            } else if (renderer['title']?['simpleText'] != null) {
              title = renderer['title']['simpleText'].toString();
            } else if (renderer['headline']?['simpleText'] != null) {
              title = renderer['headline']['simpleText'].toString();
            }

            String channel = '';
            final ownerRuns = (renderer['ownerText'] ??
                renderer['shortBylineText'])?['runs'] as List?;
            if (ownerRuns != null && ownerRuns.isNotEmpty) {
              channel = ownerRuns.first['text']?.toString() ?? '';
            }

            String views = '';
            final viewCountText = renderer['viewCountText']?['simpleText']
                    ?.toString() ??
                renderer['viewCountText']?['runs']?.first?['text']?.toString();
            if (viewCountText != null) {
              views = viewCountText;
            }

            String published = '';
            final publishedTimeText =
                renderer['publishedTimeText']?['simpleText']?.toString() ??
                    renderer['publishedTimeText']?['runs']
                        ?.first?['text']
                        ?.toString();
            if (publishedTimeText != null) {
              published = publishedTimeText;
            }

            String thumbnail = '';
            final thumbnails = renderer['thumbnail']?['thumbnails'] as List?;
            if (thumbnails != null && thumbnails.isNotEmpty) {
              thumbnail = thumbnails.last['url']?.toString() ?? '';
            }

            int duration = 0;
            final lengthText =
                renderer['lengthText']?['simpleText']?.toString() ??
                    renderer['lengthText']?['accessibility']
                            ?['accessibilityData']?['label']
                        ?.toString();
            if (lengthText != null) {
              final parts = lengthText
                  .split(':')
                  .map((e) => int.tryParse(e.trim()) ?? 0)
                  .toList();
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
              thumbnail: thumbnail.isNotEmpty
                  ? thumbnail
                  : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
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
