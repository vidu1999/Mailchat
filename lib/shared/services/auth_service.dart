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
  /// Creates an account.
  ///
  /// There are two successful outcomes, and only the second returns a profile:
  ///
  ///  * [RegistrationOutcome.signedIn] — the project has email confirmation
  ///    disabled, so GoTrue returns a session and the caller can go straight to
  ///    the app.
  ///  * [RegistrationOutcome.confirmationRequired] — the project requires email
  ///    confirmation, so GoTrue returns the user with `session: null`. The
  ///    caller must show "check your inbox" instead of treating this as a
  ///    failure. This is the default configuration, so it is the common path.
  ///
  /// The profile row itself is created by the `handle_new_user` database
  /// trigger from the `username` / `display_name` metadata sent here. The client
  /// deliberately does not insert it: before confirmation there is no session,
  /// so any insert would be rejected by RLS.
  Future<RegistrationResult> register({
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

    final user = response.user;
    if (user == null) {
      throw AppException(
        'Registration could not be completed. Please try again.',
      );
    }

    // GoTrue answers an existing address with a placeholder user that has no
    // identities, rather than an error, so callers cannot enumerate accounts.
    // Surface it so the UI can offer sign-in instead of a dead end.
    if (user.isPlaceholderForExistingAccount) {
      AppLogger.info('auth_registration_existing_account');
      throw EmailAlreadyRegisteredException(
        'This email is already registered. Sign in instead, or check your '
        'inbox for the confirmation link.',
      );
    }

    // No session: confirmation email sent, account not yet active.
    if (!response.isAuthenticated) {
      AppLogger.info('auth_registration_awaiting_confirmation', details: {
        'userId': user.id,
        // Non-null means GoTrue dispatched the email. Null with no session
        // usually means the project has no SMTP configured, which is worth
        // knowing before the user waits for a message that never arrives.
        'confirmationSentAt': user.confirmationSentAt?.toIso8601String(),
      });
      return RegistrationResult(
        user: user,
        outcome: RegistrationOutcome.confirmationRequired,
        email: email,
      );
    }

    final session = response.session!;
    await _store.saveAccessToken(session.accessToken);
    await _store.saveRefreshToken(session.refreshToken);

    AppLogger.info('auth_registered', details: {
      'userId': user.id,
      'emailConfirmed': user.emailConfirmed,
    });

    // The trigger has already inserted the profile. Read it back, and if the
    // trigger had to fall back to a derived username, align it with the one the
    // user chose. A failure here must not block an already-created account.
    Profile? profile;
    try {
      profile = await ProfileService().getProfile(user.id);
      if (profile != null && profile.username != username) {
        profile = await ProfileService().updateProfile(
          userId: user.id,
          displayName: displayName.trim(),
        );
        AppLogger.warning('profile_username_differs', details: {
          'requested': username,
          'actual': profile.username,
        });
      }
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'register_profile_read', 'userId': user.id});
    }

    return RegistrationResult(
      user: user,
      outcome: RegistrationOutcome.signedIn,
      profile: profile,
      email: email,
    );
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

/// How a registration call finished.
enum RegistrationOutcome {
  /// A session was returned; the user is signed in.
  signedIn,

  /// Confirmation is required; a verification email was sent and the user must
  /// follow the link before signing in.
  confirmationRequired,
}

/// Result of [AuthService.register].
class RegistrationResult {
  final AuthUser user;
  final RegistrationOutcome outcome;

  /// Present only for [RegistrationOutcome.signedIn].
  final Profile? profile;

  /// Address the confirmation email was sent to.
  final String email;

  const RegistrationResult({
    required this.user,
    required this.outcome,
    required this.email,
    this.profile,
  });

  bool get requiresConfirmation =>
      outcome == RegistrationOutcome.confirmationRequired;
}
