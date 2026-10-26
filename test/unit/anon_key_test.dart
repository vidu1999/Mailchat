import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/core/config/anon_key.dart';

/// Key inspection is the last line of defence against shipping the
/// service-role key inside an APK, so it is pinned down here with real-shaped
/// keys: a legacy JWT pair, and the opaque new-style names.
void main() {
  // Payload: {"iss":"supabase","ref":"abcdefghijklmnopqrst","role":"anon",...}
  const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
      'eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFiY2RlZmdoaWprbG1ub3BxcnN0Iiwicm9sZSI6ImFub24ifQ.'
      'signature';
  // Payload: {"iss":"supabase","ref":"abcdefghijklmnopqrst","role":"service_role"}
  const serviceKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
      'eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFiY2RlZmdoaWprbG1ub3BxcnN0Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSJ9.'
      'signature';

  group('jwtPayload', () {
    test('decodes a three-part key', () {
      final claims = AnonKey.jwtPayload(anonKey);

      expect(claims, isNotNull);
      expect(claims!['ref'], 'abcdefghijklmnopqrst');
      expect(claims['role'], 'anon');
    });

    test('returns null for anything that is not a JWT', () {
      expect(AnonKey.jwtPayload('sb_publishable_abc123'), isNull);
      expect(AnonKey.jwtPayload('not-a-key'), isNull);
      expect(AnonKey.jwtPayload('a.b'), isNull);
      expect(AnonKey.jwtPayload('a.b.c'), isNull); // payload is not JSON
      expect(AnonKey.jwtPayload(''), isNull);
      expect(AnonKey.jwtPayload(null), isNull);
    });
  });

  group('isServiceRole', () {
    test('detects the role claim', () {
      expect(AnonKey.isServiceRole(serviceKey), isTrue);
    });

    test('a normal anon key is not flagged', () {
      expect(AnonKey.isServiceRole(anonKey), isFalse);
    });

    test('detects new-style secret keys by name', () {
      expect(AnonKey.isServiceRole('sb_secret_abcdef123456'), isTrue);
      expect(AnonKey.isServiceRole('sb_publishable_abcdef123456'), isFalse);
    });

    test('falls back to a substring check for unreadable keys', () {
      expect(AnonKey.isServiceRole('pasted_SERVICE_ROLE_key'), isTrue);
    });

    test('empty and null are not flagged', () {
      expect(AnonKey.isServiceRole(''), isFalse);
      expect(AnonKey.isServiceRole(null), isFalse);
    });
  });

  group('suggestedUrl', () {
    test('builds the project URL from the ref claim', () {
      expect(
        AnonKey.suggestedUrl(anonKey),
        'https://abcdefghijklmnopqrst.supabase.co',
      );
    });

    test('is null when the ref cannot be read', () {
      expect(AnonKey.suggestedUrl('sb_publishable_abc'), isNull);
      expect(AnonKey.suggestedUrl(null), isNull);
    });
  });
}
