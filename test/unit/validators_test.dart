import 'package:flutter_test/flutter_test.dart';
import 'package:mailchat/core/utils/validators.dart';

void main() {
  group('Validators.email', () {
    test('accepts a normal address', () {
      expect(Validators.email('jane.doe@example.com'), isNull);
    });

    test('accepts addresses with plus tags and subdomains', () {
      expect(Validators.email('jane+mailchat@mail.example.co.uk'), isNull);
    });

    test('rejects empty input', () {
      expect(Validators.email(''), isNotNull);
      expect(Validators.email(null), isNotNull);
    });

    test('rejects missing @ or domain', () {
      expect(Validators.email('jane.example.com'), isNotNull);
      expect(Validators.email('jane@'), isNotNull);
      expect(Validators.email('@example.com'), isNotNull);
    });

    test('rejects whitespace inside the address', () {
      expect(Validators.email('jane doe@example.com'), isNotNull);
    });
  });

  group('Validators.password', () {
    test('accepts a strong password', () {
      expect(Validators.password('Str0ngPassw0rd!'), isNull);
    });

    test('rejects short passwords', () {
      expect(Validators.password('Ab1!'), isNotNull);
    });

    test('rejects empty input', () {
      expect(Validators.password(''), isNotNull);
      expect(Validators.password(null), isNotNull);
    });
  });

  group('Validators.username', () {
    test('accepts lowercase, digits, dots and underscores', () {
      expect(Validators.username('jane.doe'), isNull);
      expect(Validators.username('jane_doe99'), isNull);
      expect(Validators.username('abc'), isNull);
    });

    test('rejects uppercase (usernames are lowercased by the server)', () {
      expect(Validators.username('JaneDoe'), isNotNull);
    });

    test('rejects leading separators', () {
      expect(Validators.username('.jane'), isNotNull);
      expect(Validators.username('_jane'), isNotNull);
    });

    test('rejects spaces and symbols', () {
      expect(Validators.username('jane doe'), isNotNull);
      expect(Validators.username('jane@doe'), isNotNull);
    });

    test('rejects too short and too long', () {
      expect(Validators.username('ab'), isNotNull);
      expect(Validators.username('a' * 31), isNotNull);
      expect(Validators.username('a' * 30), isNull);
    });
  });

  group('Validators.required', () {
    test('rejects null, empty and whitespace', () {
      expect(Validators.required(null, 'Field'), isNotNull);
      expect(Validators.required('', 'Field'), isNotNull);
      expect(Validators.required('   ', 'Field'), isNotNull);
    });

    test('accepts non-empty text', () {
      expect(Validators.required('value', 'Field'), isNull);
    });
  });
}
