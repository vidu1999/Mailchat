/// A public TURN relay so two people on different networks can hear each other.
///
/// Direct paths only work when both phones can reach each other, which is
/// usually the same Wi-Fi. Mobile data, another country, or a second network
/// needs a relay. This list is the Open Relay Project published by Metered
/// for that case: username and password are the public demo pair, not a
/// secret from this repository.
///
/// A `TURN_URL` in the env file is still added first, so a project can run
/// its own relay. This one stays in the list either way. If the private
/// password is wrong, the public relay can still carry the call.
class PublicRelay {
  const PublicRelay._();

  static const String username = 'openrelayproject';
  static const String credential = 'openrelayproject';

  /// UDP 80, UDP 443, and TCP 443. TCP 443 is what gets through mobile
  /// networks that drop UDP.
  static const List<String> urls = <String>[
    'turn:openrelay.metered.ca:80',
    'turn:openrelay.metered.ca:443',
    'turn:openrelay.metered.ca:443?transport=tcp',
  ];

  static bool get hasTcp =>
      urls.any((url) => url.startsWith('turns:') || url.contains('transport=tcp'));
}
