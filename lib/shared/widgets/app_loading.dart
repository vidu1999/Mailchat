import 'package:flutter/material.dart';

/// Centered loading indicator with an optional message.
class AppLoading extends StatelessWidget {
  final String? message;

  const AppLoading({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              message!,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Page-level loading overlay.
class AppPageLoading extends StatelessWidget {
  final Widget child;
  final bool loading;

  const AppPageLoading({super.key, required this.child, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (loading)
          Container(
            color: Colors.black.withOpacity(0.35),
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
