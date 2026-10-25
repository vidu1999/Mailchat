import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_input.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';

/// Edit profile screen: change display name, bio and avatar path.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _loading = false;
  AppException? _error;

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ProfileService().updateProfile(
        userId: SupabaseClient.instance.userId ?? '' ,
        displayName: _displayNameController.text.trim(),
        bio: _bioController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e, st) {
      AppLogger.error(e, st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AppException ? e : AppException(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        centerTitle: true,
      ),
      body: _loading
          ? const AppLoading(message: 'Saving...')
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const AppAvatar(radius: 48),
                  const SizedBox(height: 16),
                  AppButton(
                    text: 'Change Photo',
                    onPressed: () {},
                    variant: AppButtonVariant.outlined,
                  ),
                  const SizedBox(height: 28),
                  AppInput(
                    controller: _displayNameController,
                    label: 'Display Name',
                    hint: 'Enter your display name',
                  ),
                  const SizedBox(height: 20),
                  AppInput(
                    controller: _bioController,
                    label: 'Bio',
                    hint: 'Tell us about yourself',
                    maxLines: 3,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    AppError(exception: _error!),
                  ],
                  const Spacer(),
                  AppButton(text: 'Save Changes', onPressed: _save),
                  const SizedBox(height: 20),
                ],
              ),
            ),
    );
  }
}

