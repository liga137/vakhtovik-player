import 'dart:convert';
import 'package:crypto/crypto.dart';

void main() {
  final token = 'CONSENT=YES+ru.ru+V14+BX; SAPISID=dummy_sapisid_value; ';
  final match = RegExp(r'SAPISID=([^;]+)').firstMatch(token);
  if (match != null) {
    final sapisid = match.group(1)!;
    final time = 1234567890;
    final input = '$time $sapisid https://www.youtube.com';
    final hash = sha1.convert(utf8.encode(input)).toString();
    print('Cookie: $token');
    print('SAPISID: $sapisid');
    print('Auth: SAPISIDHASH ${time}_$hash');
  }
}
