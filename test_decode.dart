void main() {
  final str = 'some_cookie_value_with_%_and_things';
  try {
    print(Uri.decodeComponent(str));
  } catch(e) {
    print('Error: $e');
  }
}
