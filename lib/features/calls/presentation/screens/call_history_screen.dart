import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/features/calls/domain/call_model.dart';
import 'package:mailchat/features/calls/domain/call_service.dart';
import 'package:mailchat/features/calls/presentation/screens/active_call_screen.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';
import 'package:mailchat/shared/widgets/offline_banner.dart';

/// Recent voice/video calls for the signed-in email account.
///
/// This is deliberately an account-based call log: it never reads the device
/// call database, phone number, SIM or contacts. Call records are fetched from
/// the participant-protected `calls` table.
class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  final CallService _calls = CallService();
  final TextEditingController _searchController = TextEditingController();

  List<_CallHistoryEntry> _entries = const [];
  bool _loading = true;
  bool _showSearch = false;
  bool _missedOnly = false;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _calls.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final userId = SupabaseClient.instance.userId;
    if (userId == null) {
      setState(() {
        _loading = false;
        _error = AuthorizationException('Sign in to view call history.');
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final calls = await _calls.history(userId);
      final peerIds = calls
          .map((call) => call.callerId == userId ? call.calleeId : call.callerId)
          .toSet();
      final profilesById = <String, Profile>{};
      if (peerIds.isNotEmpty) {
        final profileRows = await SupabaseClient.instance.select(
          'profiles',
          select: 'id,username,display_name,avatar_path,bio,created_at,updated_at',
          filter: {'id': 'in.(${peerIds.join(',')})'},
        );
        for (final row in profileRows) {
          final profile = Profile.fromJson(row);
          profilesById[profile.id] = profile;
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = calls
            .map((call) => _CallHistoryEntry(
                  call: call,
                  peer: profilesById[
                      call.callerId == userId ? call.calleeId : call.callerId],
                  isOutgoing: call.callerId == userId,
                ))
            .toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error : AppException(error.toString());
      });
    }
  }

  List<_CallHistoryEntry> get _visibleEntries {
    final query = _searchController.text.trim().toLowerCase();
    return _entries.where((entry) {
      if (_missedOnly && entry.call.state != CallState.missed) return false;
      final name = entry.peer?.displayNameOrUsername ?? 'MailChat member';
      return query.isEmpty || name.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _startCall(_CallHistoryEntry entry) async {
    final peer = entry.peer;
    final selfId = SupabaseClient.instance.userId;
    if (peer == null || selfId == null) {
      _showMessage('This person is not available for a call right now.');
      return;
    }
    await Navigator.of(context).pushNamed(
      AppRoutes.activeCall,
      arguments: {
        'conversationId': entry.call.conversationId,
        'peerId': peer.id,
        'peerName': peer.displayNameOrUsername,
        'selfId': selfId,
        'isVideo': entry.call.isVideo,
        'isCaller': true,
      },
    );
    if (mounted) await _load();
  }

  Future<void> _openCallPicker({required bool video}) async {
    await Navigator.of(context).pushNamed(
      AppRoutes.searchUsers,
      arguments: {'callMode': true, 'isVideoCall': video},
    );
    if (mounted) await _load();
  }

  void _openChat(_CallHistoryEntry entry) {
    final peer = entry.peer;
    if (peer == null) return;
    Navigator.of(context).pushNamed(
      AppRoutes.directChat,
      arguments: {
        'conversationId': entry.call.conversationId,
        'title': peer.displayNameOrUsername,
        'otherUserId': peer.id,
        'isGroup': false,
      },
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: _showSearch
            ? TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search call history',
                  border: InputBorder.none,
                ),
              )
            : const Text('Calls'),
        actions: [
          IconButton(
            tooltip: _showSearch ? 'Close search' : 'Search call history',
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) _searchController.clear();
            }),
          ),
          IconButton(
            tooltip: 'Refresh calls',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(child: _buildBody(colors)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 1,
        onDestinationSelected: (index) {
          if (index == 0) {
            Navigator.of(context).pushNamedAndRemoveUntil(
              AppRoutes.chatList,
              (_) => false,
            );
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
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

  Widget _buildBody(ColorScheme colors) {
    if (_loading) return const AppLoading(message: 'Loading call history...');
    if (_error != null) return AppError(exception: _error!, onRetry: _load);

    final entries = _visibleEntries;
    final missedCount = _entries
        .where((entry) => entry.call.state == CallState.missed)
        .length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Row(
              children: [
                Expanded(
                  child: _QuickCallAction(
                    icon: Icons.call_outlined,
                    label: 'Voice call',
                    onTap: () => _openCallPicker(video: false),
                  ),
                ),
                Expanded(
                  child: _QuickCallAction(
                    icon: Icons.videocam_outlined,
                    label: 'Video call',
                    onTap: () => _openCallPicker(video: true),
                  ),
                ),
                Expanded(
                  child: _QuickCallAction(
                    icon: Icons.people_outline,
                    label: 'Find people',
                    onTap: () => Navigator.of(context)
                        .pushNamed(AppRoutes.searchUsers),
                  ),
                ),
                Expanded(
                  child: _QuickCallAction(
                    icon: Icons.call_missed_outgoing,
                    label: 'Missed',
                    selected: _missedOnly,
                    badge: missedCount == 0 ? null : missedCount,
                    onTap: () => setState(() => _missedOnly = !_missedOnly),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _missedOnly ? 'Missed calls' : 'Recent',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Text('${entries.length}', style: TextStyle(color: colors.onSurfaceVariant)),
              ],
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 42),
              child: AppEmptyState(
                icon: _missedOnly ? Icons.call_missed_outgoing : Icons.call_outlined,
                title: _entries.isEmpty ? 'No calls yet' : 'No matching calls',
                subtitle: _entries.isEmpty
                    ? 'Voice and video calls you make in MailChat will appear here.'
                    : 'Try another name or view all recent calls.',
                action: _entries.isEmpty
                    ? FilledButton.icon(
                        onPressed: () => _openCallPicker(video: false),
                        icon: const Icon(Icons.call),
                        label: const Text('Start a call'),
                      )
                    : null,
              ),
            )
          else
            for (final entry in entries)
              _CallHistoryTile(
                entry: entry,
                onTap: () => _openChat(entry),
                onCall: () => _startCall(entry),
              ),
        ],
      ),
    );
  }
}

class _CallHistoryEntry {
  const _CallHistoryEntry({
    required this.call,
    required this.peer,
    required this.isOutgoing,
  });

  final Call call;
  final Profile? peer;
  final bool isOutgoing;
}

class _CallHistoryTile extends StatelessWidget {
  const _CallHistoryTile({
    required this.entry,
    required this.onTap,
    required this.onCall,
  });

  final _CallHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final call = entry.call;
    final colors = Theme.of(context).colorScheme;
    final isMissed = call.state == CallState.missed ||
        call.state == CallState.declined ||
        call.state == CallState.failed;
    final name = entry.peer?.displayNameOrUsername ?? 'MailChat member';
    final arrowIcon = entry.isOutgoing ? Icons.call_made : Icons.call_received;
    final arrowColor = isMissed
        ? colors.error
        : (entry.isOutgoing ? const Color(0xFF22C55E) : colors.primary);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      leading: AppAvatar(profile: entry.peer, radius: 26),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isMissed ? colors.error : colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(arrowIcon, size: 17, color: arrowColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _description(call, entry.isOutgoing),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            AppFormatters.callTimestamp(call.createdAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
      trailing: IconButton(
        tooltip: call.isVideo ? 'Video call back' : 'Call back',
        icon: Icon(
          call.isVideo ? Icons.videocam_outlined : Icons.call_outlined,
          size: 25,
        ),
        onPressed: onCall,
      ),
      onTap: onTap,
    );
  }

  String _description(Call call, bool outgoing) {
    final kind = call.isVideo ? 'video' : 'voice';
    return switch (call.state) {
      CallState.missed => outgoing ? 'No answer · $kind call' : 'Missed $kind call',
      CallState.declined => outgoing ? 'Call declined · $kind' : 'You declined · $kind',
      CallState.failed => 'Failed $kind call',
      CallState.ringing => outgoing ? 'Outgoing $kind call' : 'Incoming $kind call',
      CallState.ongoing => '${outgoing ? 'Outgoing' : 'Incoming'} $kind call · In progress',
      CallState.ended => '${outgoing ? 'Outgoing' : 'Incoming'} $kind call${_durationLabel(call)}',
    };
  }

  String _durationLabel(Call call) {
    final duration = call.duration;
    if (duration == null || duration == Duration.zero) return '';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? ' · $hours:$minutes:$seconds' : ' · ${duration.inMinutes}:$seconds';
  }
}

class _QuickCallAction extends StatelessWidget {
  const _QuickCallAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: selected
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  child: Icon(
                    icon,
                    color: selected ? colors.primary : colors.onSurface,
                    size: 25,
                  ),
                ),
                if (badge != null)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: colors.error,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        badge! > 99 ? '99+' : '$badge',
                        style: TextStyle(
                          color: colors.onError,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
