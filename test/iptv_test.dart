import 'package:flutter_test/flutter_test.dart';
import 'package:vakhtovik_player/services/iptv_service.dart';

void main() {
  test('IPTV resolve test', () async {
    final channels = await IptvService.loadChannels();
    print('Total channels: ${channels.length}');
    for (final ch in channels) {
      if (ch.name == 'Первый канал' || ch.name == 'Россия 1') {
        print('Name: ${ch.name}, URL: ${ch.url}');
      }
    }
  });
}
