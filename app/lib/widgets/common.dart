import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../models.dart';

/// True when the app itself runs on a computer. Drag-and-drop and folder pickers
/// exist only there, and the cable advice differs between a computer and a phone.
bool get isDesktopHost => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

IconData cableIcon(CableKind k) => switch (k) {
      CableKind.network => Icons.settings_ethernet,
      CableKind.android => Icons.android,
      CableKind.ios => Icons.cable,
      CableKind.usbHost => Icons.usb,
    };

IconData platformIcon(String platform) => switch (platform) {
      'android' => Icons.smartphone,
      'ios' => Icons.phone_iphone,
      'macos' => Icons.laptop_mac,
      _ => Icons.computer,
    };

/// Platform names the core can report, including 'desktop' for a computer reached
/// over USB whose exact OS the phone cannot know.

String platformName(String p) => switch (p) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      'desktop' => 'Компьютер',
      _ => p,
    };

/// Numbered card: "1. Выберите файлы".
class StepCard extends StatelessWidget {
  const StepCard({super.key, required this.number, required this.title, required this.child, this.trailing, this.done = false});

  final int number;
  final String title;
  final Widget child;
  final Widget? trailing;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: done ? cs.primary : cs.secondaryContainer,
                  foregroundColor: done ? cs.onPrimary : cs.onSecondaryContainer,
                  child: done ? const Icon(Icons.check, size: 16) : Text('$number', style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.kind});
  final String label;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (kind) {
      StatusKind.ok => (cs.primaryContainer, cs.onPrimaryContainer, Icons.check_circle),
      StatusKind.warn => (cs.tertiaryContainer, cs.onTertiaryContainer, Icons.info),
      StatusKind.none => (cs.surfaceContainerHighest, cs.onSurfaceVariant, Icons.radio_button_unchecked),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

enum StatusKind { ok, warn, none }

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(children: [
        Icon(icon, size: 40, color: cs.outline),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.titleSmall, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(text, style: TextStyle(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 8), action!],
      ]),
    );
  }
}

/// Centers page content and caps its width so it stays readable on big screens.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, i) => children[i],
          ),
        ),
      );
}
