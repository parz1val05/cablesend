import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../format.dart';
import '../widgets/common.dart';
import 'cables_page.dart';
import 'receive_page.dart';
import 'send_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _dialogOpen = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_maybeShowOffer);
  }

  @override
  void dispose() {
    c.removeListener(_maybeShowOffer);
    super.dispose();
  }

  void _maybeShowOffer() {
    final offer = c.offer;
    if (offer == null || _dialogOpen) return;
    _dialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Every path below must answer and clear the flag. An unanswered offer
      // leaves the sender waiting and blocks every later offer in this session.
      bool? accepted;
      try {
        if (mounted) {
          accepted = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _OfferDialog(controller: c, offer: offer),
          );
        }
      } catch (_) {
        // No navigator, or the route was locked: fall through and decline.
      } finally {
        _dialogOpen = false;
      }
      // This exact offer must still be the pending one. It is not if the sender
      // gave up or receiving was switched off, in which case the controller has
      // already declined it and answering again would hit the next offer.
      if (!identical(c.offer, offer)) return;
      c.answerOffer(accepted ?? false);
    });
  }

  static const _titles = ['Отправить', 'Получить', 'Кабели'];
  static const _icons = [Icons.upload_rounded, Icons.download_rounded, Icons.cable_rounded];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final pages = [
          SendPage(controller: c, onOpenCables: () => setState(() => _index = 2)),
          ReceivePage(controller: c),
          CablesPage(controller: c),
        ];
        final body = Column(children: [
          if (c.backend.isDemo) const _DemoBanner(),
          Expanded(child: pages[_index]),
        ]);

        return LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 720;
          final destinations = [
            for (var i = 0; i < 3; i++)
              (icon: Icon(_icons[i]), badge: i == 1 && c.receiving, label: _titles[i]),
          ];
          if (wide) {
            return Scaffold(
              body: SafeArea(
                child: Row(children: [
                  NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    labelType: NavigationRailLabelType.all,
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Icon(Icons.cable_rounded, size: 32),
                    ),
                    destinations: [
                      for (final d in destinations)
                        NavigationRailDestination(
                          icon: Badge(isLabelVisible: d.badge, smallSize: 8, child: d.icon),
                          label: Text(d.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ]),
              ),
            );
          }
          return Scaffold(
            appBar: AppBar(title: Text(_titles[_index]), centerTitle: false),
            body: SafeArea(child: body),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    icon: Badge(isLabelVisible: d.badge, smallSize: 8, child: d.icon),
                    label: d.label,
                  ),
              ],
            ),
          );
        });
      },
    );
  }
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Icon(Icons.science_outlined, size: 18, color: cs.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Демо-режим: устройства и передача выдуманы. Ядро cablesend не найдено.',
              style: TextStyle(color: cs.onTertiaryContainer, fontSize: 13),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Closes itself when the offer it was opened for is no longer pending — the
/// sender gave up, or receiving was switched off. Without this the person would
/// be left with a dialog they must answer for a transfer that no longer exists,
/// and that answer would block the next real offer.
class _OfferDialog extends StatefulWidget {
  const _OfferDialog({required this.controller, required this.offer});
  final AppController controller;
  final PendingOffer offer;

  @override
  State<_OfferDialog> createState() => _OfferDialogState();
}

class _OfferDialogState extends State<_OfferDialog> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_closeIfWithdrawn);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_closeIfWithdrawn);
    super.dispose();
  }

  void _closeIfWithdrawn() {
    if (!mounted || identical(widget.controller.offer, widget.offer)) return;
    unawaited(Navigator.of(context).maybePop());
  }

  PendingOffer get offer => widget.offer;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(platformIcon(offer.platform), size: 32),
      title: Text('${offer.peer} хочет отправить вам ${pluralFiles(offer.files.length)}'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Общий размер: ${formatSize(offer.totalSize)}'),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final f in offer.files)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(formatSize(f.size)),
                  ),
              ],
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отклонить')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Принять')),
      ],
    );
  }
}
