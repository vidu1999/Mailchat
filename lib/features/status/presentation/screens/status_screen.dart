import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/features/status/domain/status_service.dart';
import 'package:mailchat/features/status/domain/user_status.dart';
import 'package:mailchat/features/status/presentation/screens/status_composer_screen.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/offline_banner.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  final StatusService _service = StatusService();
  List<StatusParticipant> _participants = const [];
  Profile? _me;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = SupabaseClient.instance.userId;
    if (userId == null) {
      setState(() {
        _loading = false;
        _error = 'Sign in to view Updates.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final participants = await _service.list(viewerId: userId);
      final profileRows = await SupabaseClient.instance.select(
        'profiles',
        select:
            'id,username,display_name,avatar_path,bio,created_at,updated_at',
        filter: {'eq': 'id,$userId'},
        limit: 1,
      );
      if (!mounted) return;
      setState(() {
        _participants = participants;
        _me = profileRows.isEmpty ? null : Profile.fromJson(profileRows.first);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _compose() async {
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const StatusComposerScreen()),
    );
    if (published == true && mounted) await _load();
  }

  StatusParticipant? get _myStatuses {
    final id = SupabaseClient.instance.userId;
    for (final participant in _participants) {
      if (participant.userId == id) return participant;
    }
    return null;
  }

  Future<void> _view(StatusParticipant participant) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            StatusViewerScreen(participant: participant, service: _service),
      ),
    );
    if (mounted) await _load();
  }

  Profile? _profileFor(StatusParticipant participant) => Profile(
    id: participant.userId,
    username: participant.username,
    displayName: participant.displayName,
    avatarPath: participant.avatarPath,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  @override
  Widget build(BuildContext context) {
    final mine = _myStatuses;
    final others = _participants
        .where((item) => item.userId != SupabaseClient.instance.userId)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Updates'),
        actions: [
          IconButton(
            tooltip: 'Refresh updates',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Text status',
            onPressed: _compose,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
                children: [
                  Text(
                    'Status',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      leading: _MyStatusAvatar(
                        profile: _me,
                        hasStatus: mine != null,
                      ),
                      title: const Text(
                        'My status',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        mine == null
                            ? 'Tap + to share a photo or text'
                            : '${mine.statuses.length} active update${mine.statuses.length == 1 ? '' : 's'} · tap to view',
                      ),
                      trailing: IconButton.filled(
                        tooltip: 'Add status',
                        onPressed: _compose,
                        icon: const Icon(Icons.add),
                      ),
                      onTap: mine == null ? _compose : () => _view(mine),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Recent updates',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_off_outlined),
                        title: const Text('Could not load updates'),
                        subtitle: Text(
                          _error!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                    )
                  else if (others.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          children: [
                            Icon(
                              Icons.auto_stories_outlined,
                              size: 34,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'No updates yet',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 5),
                            const Text(
                              'Updates from people you have a direct MailChat conversation with will show here.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final participant in others)
                      Card(
                        child: ListTile(
                          leading: _StatusAvatar(
                            profile: _profileFor(participant),
                            unseen: participant.statuses.any(
                              (s) => !s.viewedByMe,
                            ),
                          ),
                          title: Text(
                            participant.title,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${participant.statuses.length} update${participant.statuses.length == 1 ? '' : 's'} · ${_timeLabel(participant.statuses.first.createdAt)}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _view(participant),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _compose,
        icon: const Icon(Icons.camera_alt_outlined),
        label: const Text('Add update'),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 1,
        onDestinationSelected: (index) {
          if (index == 0) {
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil(AppRoutes.chatList, (_) => false);
          }
          if (index == 2) {
            Navigator.of(context).pushReplacementNamed(AppRoutes.callHistory);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.circle_outlined),
            selectedIcon: Icon(Icons.circle),
            label: 'Updates',
          ),
          NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call),
            label: 'Calls',
          ),
        ],
      ),
    );
  }

  String _timeLabel(DateTime time) {
    final delta = DateTime.now().difference(time);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes} min ago';
    if (delta.inDays < 1) return '${delta.inHours} hr ago';
    return 'yesterday';
  }
}

class _MyStatusAvatar extends StatelessWidget {
  const _MyStatusAvatar({required this.profile, required this.hasStatus});
  final Profile? profile;
  final bool hasStatus;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      _StatusAvatar(profile: profile, unseen: hasStatus),
      Positioned(
        right: -1,
        bottom: -1,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.surface,
              width: 2,
            ),
          ),
          child: Icon(
            Icons.add,
            size: 18,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
      ),
    ],
  );
}

class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({required this.profile, required this.unseen});
  final Profile? profile;
  final bool unseen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: unseen
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outlineVariant,
        width: 2.5,
      ),
    ),
    child: AppAvatar(profile: profile, radius: 24),
  );
}

class StatusViewerScreen extends StatefulWidget {
  const StatusViewerScreen({
    super.key,
    required this.participant,
    required this.service,
  });
  final StatusParticipant participant;
  final StatusService service;

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen> {
  int _index = 0;
  String? _imageUrl;
  String? _imageError;
  Timer? _refreshTimer;

  UserStatus get _status => widget.participant.statuses[_index];

  @override
  void initState() {
    super.initState();
    _loadImageAndView();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_status.expiresAt.isAfter(DateTime.now())) _nextOrClose();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadImageAndView() async {
    final status = _status;
    setState(() {
      _imageUrl = null;
      _imageError = null;
    });
    try {
      if (status.isImage && status.mediaPath != null) {
        final url = await widget.service.signedImageUrl(status.mediaPath!);
        if (mounted && status.id == _status.id) setState(() => _imageUrl = url);
      }
      final viewerId = SupabaseClient.instance.userId;
      if (viewerId != null && status.userId != viewerId) {
        await widget.service.markViewed(
          statusId: status.id,
          viewerId: viewerId,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _imageError = error.toString());
    }
  }

  void _nextOrClose() {
    if (_index + 1 >= widget.participant.statuses.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index++);
    _loadImageAndView();
  }

  void _previous() {
    if (_index == 0) return;
    setState(() => _index--);
    _loadImageAndView();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final own = status.userId == SupabaseClient.instance.userId;
    final background = Color(status.backgroundColor);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: status.isImage
                ? (_imageUrl == null
                      ? Center(
                          child: _imageError == null
                              ? const CircularProgressIndicator()
                              : Text(
                                  'Could not load photo\n$_imageError',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white),
                                ),
                        )
                      : Image.network(
                          _imageUrl!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Text(
                              'Photo unavailable',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ))
                : ColoredBox(
                    color: background,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(36),
                        child: Text(
                          status.text ?? '',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(
                    children: [
                      Row(
                        children: List.generate(
                          widget.participant.statuses.length,
                          (index) => Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: LinearProgressIndicator(
                                value: index < _index
                                    ? 1
                                    : index == _index
                                    ? null
                                    : 0,
                                minHeight: 3,
                                backgroundColor: Colors.white30,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          AppAvatar(
                            profile: Profile(
                              id: widget.participant.userId,
                              username: widget.participant.username,
                              displayName: widget.participant.displayName,
                              avatarPath: widget.participant.avatarPath,
                              createdAt: status.createdAt,
                              updatedAt: status.createdAt,
                            ),
                            radius: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${widget.participant.title} · ${_ago(status.createdAt)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (own)
                            Text(
                              '${status.viewerCount} views',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            color: Colors.white,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _previous,
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: 72,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _nextOrClose,
                        ),
                      ),
                    ],
                  ),
                ),
                if (status.text != null && status.isImage)
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      status.text!,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ago(DateTime time) {
    final minutes = DateTime.now().difference(time).inMinutes;
    if (minutes < 1) return 'now';
    if (minutes < 60) return '${minutes}m';
    return '${DateTime.now().difference(time).inHours}h';
  }
}
