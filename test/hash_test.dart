import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

void main() {
  test('SAPISID Hash', () {
    final token = 'CONSENT=YES; SAPISID=dummy; __Secure=123';
    final match = RegExp(r'SAPISID=([^;]+)').firstMatch(token);
    expect(match, isNotNull);
    final sapisid = match!.group(1)!;
    expect(sapisid, 'dummy');
    
    final time = 1234567890;
    final input = '\ \ https://www.youtube.com';
    final hash = sha1.convert(utf8.encode(input)).toString();
    expect(hash, 'a74f4f0aff4d4a1523c5ecebf70ea7429a14c243');
    print('SAPISIDHASH \_\');
  });
}
