import 'package:mailchat/core/deeplink/auth_deep_link.dart';
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
  ///
  /// Restoring is two steps because that is what the platform actually needs:
  /// the stored access token is used when it is still valid, and otherwise the
  /// stored refresh token is exchanged for a new one. Without the second step
  /// every launch an hour after signing in would land on the login screen,
  /// because the access token's lifetime is one hour.
  Future<void> init() async {
    // Keep the persisted copy in step with silent refreshes.
    _supabase.onSessionRefreshed = (session) async {
      await _store.saveAccessToken(session.accessToken);
      await _store.saveRefreshToken(session.refreshToken);
    };

    final accessToken = await _store.getAccessToken();
    final refreshToken = await _store.getRefreshToken();

    if (accessToken != null && accessToken.isNotEmpty) {
      await _supabase.setSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
      // setSession verifies the token against /auth/v1/user; a null user means
      // it was rejected (expired, revoked, secret rotated). Try the refresh
      // token before giving up on the session.
      if (!isAuthenticated && refreshToken != null && refreshToken.isNotEmpty) {
        AppLogger.info('auth_restore_attempting_refresh');
        if (!await _supabase.refreshSession()) {
          // Unrecoverable: clear the dead tokens so the next launch does not
          // repeat a doomed request.
          await _store.clear();
        }
      }
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
      // Reached only if the client handed back a session-less response, which
      // it now refuses to do — this used to report a successful 200 sign-in as
      // "Invalid email or password."
      throw AppException(
        'Signed in, but the session could not be read. Please try again.',
        code: 'signin_no_session',
      );
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

  /// Turns an incoming auth link into a session.
  ///
  /// Two shapes reach this point:
  ///  * Supabase verified the email token server-side and redirected with the
  ///    session in the fragment, so the tokens are already usable.
  ///  * The template passed `token_hash`, which has to be exchanged here.
  ///
  /// Both end with the tokens persisted, so a cold start after the link opens
  /// the signed-in app rather than asking for the password again.
  Future<AuthLinkResult> handleAuthLink(AuthDeepLink link) async {
    if (link.kind == AuthLinkKind.error) {
      AppLogger.warning('auth_link_error', details: {
        'code': link.errorCode,
        'description': link.errorDescription,
      });
      return AuthLinkResult.failure(link.errorMessage, kind: link.kind);
    }

    try {
      if (link.tokenHash != null) {
        final response = await _supabase.verifyTokenHash(
          tokenHash: link.tokenHash!,
          type: link.type ?? 'signup',
        );
        final session = response.session;
        if (session == null) {
          return AuthLinkResult.failure(
            'The link was accepted but no session came back. Try signing in, '
            'and request a new email if the account is not active yet.',
            kind: link.kind,
          );
        }
        await _persist(session);
      } else if (link.accessToken != null) {
        await _supabase.setSession(
          accessToken: link.accessToken!,
          refreshToken: link.refreshToken,
        );
        // `setSession` loads the user from /auth/v1/user. A token that is
        // expired or already revoked leaves no current user, which is the
        // difference between "confirmed" and "stored a dead token".
        final token = _supabase.accessToken;
        if (token == null || _supabase.currentUser == null) {
          return AuthLinkResult.failure(
            'This link has expired or was already used. Request a new email, '
            'or sign in if the account is already active.',
            kind: link.kind,
          );
        }
        await _store.saveAccessToken(token);
        await _store.saveRefreshToken(link.refreshToken);
      } else {
        return AuthLinkResult.failure(
          'This link did not contain a token. Request a new email.',
          kind: link.kind,
        );
      }
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'handle_auth_link'});
      final message = e is AppException
          ? e.message
          : 'Could not complete the link. Please try again.';
      return AuthLinkResult.failure(message, kind: link.kind);
    }

    final email = currentUser?.email;
    AppLogger.info('auth_link_handled', details: {
      'kind': link.kind.name,
      'signedIn': isAuthenticated,
    });

    return switch (link.kind) {
      AuthLinkKind.confirmation => AuthLinkResult.success(
          email == null || email.isEmpty
              ? 'Email confirmed. Welcome to MailChat.'
              : 'Email confirmed for $email. Welcome to MailChat.',
          kind: link.kind,
        ),
      AuthLinkKind.recovery => AuthLinkResult.success(
          'Set a new password for your account.',
          kind: link.kind,
        ),
      AuthLinkKind.error => AuthLinkResult.failure(link.errorMessage,
          kind: link.kind),
    };
  }

  /// Sets a new password using the session a recovery link established.
  Future<void> updatePassword(String newPassword) async {
    final error = Validators.password(newPassword);
    if (error != null) throw ValidationException(error);
    await _supabase.updatePassword(newPassword);
    AppLogger.info('auth_password_updated');
  }

  Future<void> _persist(Session session) async {
    await _store.saveAccessToken(session.accessToken);
    await _store.saveRefreshToken(session.refreshToken);
  }
}

/// Outcome of [AuthService.handleAuthLink].
class AuthLinkResult {
  final bool succeeded;
  final String message;
  final AuthLinkKind kind;

  const AuthLinkResult({
    required this.succeeded,
    required this.message,
    required this.kind,
  });

  factory AuthLinkResult.success(String message,
          {required AuthLinkKind kind}) =>
      AuthLinkResult(succeeded: true, message: message, kind: kind);

  factory AuthLinkResult.failure(String message,
          {required AuthLinkKind kind}) =>
      AuthLinkResult(succeeded: false, message: message, kind: kind);
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
