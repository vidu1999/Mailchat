import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/services/session_store.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/core/utils/validators.dart';

/// Authentication business logic.
///
/// Wraps Supabase Auth (GoTrue) and the profiles table. All email-based:
/// registration, email confirmation, login, logout, password reset.
class AuthService {
  AuthService({SessionStore? store}) : _store = store ?? _defaultStore;

  /// Shared persistent store. NOTE: [FileSessionStore] writes to the current
  /// working directory, which is acceptable for desktop/CI but NOT for
  /// production mobile. Swap in a keychain/keystore-backed SessionStore
  /// (e.g. flutter_secure_storage) before shipping — see docs/security.md.
  static final SessionStore _defaultStore = FileSessionStore();

  final SessionStore _store;

  final SupabaseClient _supabase = SupabaseClient.instance;

  /// Stream of the current authenticated user.
  Stream<AuthUser?> get userStream => _supabase.authStateChanges;

  /// Current cached user, or null.
  AuthUser? get currentUser => _supabase.currentUser;

  /// Whether a session is currently active.
  bool get isAuthenticated => currentUser != null;

  /// Initializes the service, restoring any persisted session.
  Future<void> init() async {
    final accessToken = await _store.getAccessToken();
    final refreshToken = await _store.getRefreshToken();
    if (accessToken != null && accessToken.isNotEmpty) {
      await _supabase.setSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
    }
    AppLogger.info('auth_initialized', details: {
      'authenticated': isAuthenticated,
      'emailConfirmed': currentUser?.emailConfirmed,
    });
  }

  // ------------------------------------------------------------------
  // Registration
  // ------------------------------------------------------------------

  /// Creates an account with email, password, display name and username.
  ///
  /// The profile row is created in the same transaction-like flow; if profile
  /// creation fails the auth account is left intact (the user can log in and
  /// complete their profile later).
  Future<Profile> register({
    required String email,
    required String password,
    required String displayName,
    required String username,
  }) async {
    email = email.trim().toLowerCase();
    username = username.trim().toLowerCase();

    // Validate locally first to fail fast on constraint violations.
    final usernameError = Validators.username(username);
    if (usernameError != null) {
      throw ValidationException(usernameError);
    }

    final response = await _supabase.signUp(
      email: email,
      password: password,
      metadata: {
        'display_name': displayName.trim(),
        'username': username,
      },
    );

    if (!response.isAuthenticated) {
      throw AppException('Registration failed: no session returned');
    }

    AppLogger.info('auth_registered', details: {
      'userId': response.user!.id,
      'emailConfirmed': response.user!.emailConfirmed,
    });

    // Create/complete the profile. A duplicate username raises a unique
    // violation from the database; translate into a friendly error.
    try {
      final profile = await ProfileService().createProfile(
        userId: response.user!.id,
        username: username,
        displayName: displayName.trim(),
      );
      await _store.saveAccessToken(response.session!.accessToken);
      await _store.saveRefreshToken(response.session!.refreshToken);
      return profile;
    } on AppException {
      rethrow;
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'register_profile', 'userId': response.user!.id});
      throw AppException('Account created but profile could not be completed. '
          'Please log in and finish your profile.');
    }
  }

  // ------------------------------------------------------------------
  // Login / logout / session
  // ------------------------------------------------------------------

  /// Signs in with email and password.
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    email = email.trim().toLowerCase();
    final response = await _supabase.signInWithPassword(
      email: email,
      password: password,
    );
    if (!response.isAuthenticated) {
      throw AuthorizationException('Invalid email or password.');
    }
    await _store.saveAccessToken(response.session!.accessToken);
    await _store.saveRefreshToken(response.session!.refreshToken);
    AppLogger.info('auth_signed_in', details: {'userId': response.user!.id});
  }

  /// Signs out and clears the persisted session.
  Future<void> signOut() async {
    await _supabase.signOut();
    await _store.clear();
    AppLogger.info('auth_signed_out');
  }

  /// Sends a password-reset email to [email].
  Future<void> resetPassword(String email) async {
    email = email.trim().toLowerCase();
    await _supabase.resetPasswordForEmail(email);
    AppLogger.info('auth_reset_sent', details: {'email': email});
  }

  /// Returns true when the current user has confirmed their email address.
  bool get isEmailConfirmed => currentUser?.emailConfirmed ?? false;
}
