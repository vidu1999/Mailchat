/// Typography helpers so screens use consistent text styles.
import 'package:flutter/material.dart';

class AppText {
  AppText._();

  static Widget heading1(String text, BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium,
    );
  }

  static Widget heading2(String text, BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleLarge,
    );
  }

  static Widget body(String text, BuildContext context,
      {bool muted = false}) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: muted
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : null,
          ),
    );
  }

  /// Small muted timestamp/label text (e.g. chat list timestamps).
  static Widget caption(String text, {BuildContext? context}) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        color: context == null
            ? null
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
