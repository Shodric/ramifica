import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/core/creator.dart';

void main() {
  test('only the verified author email can create', () {
    expect(
      isStoryCreator(
        email: '  Author@Example.com ',
        emailVerified: true,
        creatorEmail: 'author@example.com',
      ),
      isTrue,
    );
    expect(
      isStoryCreator(
        email: 'author@example.com',
        emailVerified: false,
        creatorEmail: 'author@example.com',
      ),
      isFalse,
    );
    expect(
      isStoryCreator(
        email: 'other@example.com',
        emailVerified: true,
        creatorEmail: 'author@example.com',
      ),
      isFalse,
    );
    expect(
      isStoryCreator(email: 'author@example.com', emailVerified: true),
      isFalse,
    );
  });
}
