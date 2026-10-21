import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../format.dart';
import '../widgets/common.dart';

class ReceivePage extends StatelessWidget {
  const ReceivePage({super.key, required this.controller});
  final AppController controller;

  AppController get c => controller;

  Future<void> _rename(BuildContext context) async {
    final tc = TextEditingController(text: c.deviceName);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Имя устройства'),
          content: TextField(
            controller: tc,
            autofocus: true,
            decoration: const InputDecoration(helperText: 'Так вас увидят другие устройства'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, tc.text), child: const Text('Сохранить')),
          ],
        ),
      );
      if (name != null) await c.rename(name);
    } finally {
      tc.dispose(); // one leaked controller per rename otherwise
    }
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Куда сохранять файлы');
    if (dir != null) await c.setSaveDir(dir);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canPickDir = isDesktopHost;
    final ip = c.incomingProgress;

    return PageBody(children: [
      Card(
        elevation: 0,
        color: c.receiving ? cs.primaryContainer : cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: c.receiving ? cs.primary : cs.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text('Принимать файлы', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text(c.receiving
                  ? 'Включено. Устройство видно как «${c.deviceName}».'
                  : 'Выключено. Включите, чтобы другие устройства могли вам отправлять.'),
              value: c.receiving,
              onChanged: c.receivingBusy ? null : (v) => unawaited(c.setReceiving(v)),
            ),
            if (c.receiving)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 18, color: cs.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'На втором устройстве откройте «Отправить» и выберите это имя. '
                      'Каждую передачу вы подтверждаете вручную.',
                      style: TextStyle(color: cs.onPrimaryContainer),
                    ),
                  ),
                ]),
              ),
          ]),
        ),
      ),
      if (c.receiveError != null)
        Card(
          elevation: 0,
          color: cs.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(Icons.error_outline, color: cs.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(child: Text(c.receiveError!, style: TextStyle(color: cs.onErrorContainer))),
            ]),
          ),
        ),
      if (ip != null)
        Card(
          elevation: 0,
          color: cs.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Получаем: ${ip.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: ip.total == 0 ? null : ip.done / ip.total,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
              ),
              const SizedBox(height: 6),
              Text('${formatSize(ip.done)} из ${formatSize(ip.total)}'),
            ]),
          ),
        ),
      Card(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: cs.outlineVariant)),
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Имя устройства'),
            subtitle: Text(c.deviceName),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => unawaited(_rename(context)),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Папка для сохранения'),
            subtitle: Text(c.saveDir),
            trailing: canPickDir ? const Icon(Icons.edit_outlined) : null,
            onTap: canPickDir ? () => unawaited(_pickDir()) : null,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 4, top: 6),
        child: Text('Недавние передачи', style: Theme.of(context).textTheme.titleSmall),
      ),
      if (c.history.isEmpty)
        const EmptyHint(
          icon: Icons.history,
          title: 'Пока пусто',
          text: 'Здесь появятся отправленные и полученные файлы.',
        )
      else
        for (final h in c.history.take(30))
          Card(
            elevation: 0,
            color: cs.surfaceContainerLow,
            child: ListTile(
              leading: Icon(
                h.ok ? (h.incoming ? Icons.download_done : Icons.upload_rounded) : Icons.error_outline,
                color: h.ok ? cs.primary : cs.error,
              ),
              title: Text(h.title),
              subtitle: h.subtitle.isEmpty ? null : Text(h.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: Text(
                '${h.time.hour.toString().padLeft(2, '0')}:${h.time.minute.toString().padLeft(2, '0')}',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          ),
    ]);
  }
}
