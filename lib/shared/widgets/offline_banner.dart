import 'package:flutter/material.dart';

import 'package:mailchat/core/network/connection_status.dart';

/// A thin strip that appears at the top of a screen while the app cannot reach
/// the server.
///
/// Without it, an outage is invisible: the list keeps its last contents, nothing
/// arrives, and sending appears to do nothing. The banner is deliberately quiet
/// — it says what is wrong and what to check, and disappears the moment a
/// request succeeds.
///
/// It never offers a "retry" button: the app is already retrying (the realtime
/// socket with backoff, HTTP calls on the user's next action), so a button would
/// be a decoration that implies a control it does not have.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ConnectionStatus.instance,
      builder: (context, _) {
        final status = ConnectionStatus.instance;
        if (!status.isOffline) return const SizedBox.shrink();

        final colors = Theme.of(context).colorScheme;
        return Container(
          width: double.infinity,
          color: colors.errorContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 18,
                color: colors.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status.advice,
                  style: TextStyle(fontSize: 12, color: colors.onErrorContainer),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
