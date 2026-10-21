import 'dart:async';
import 'dart:io' show FileStat, FileSystemEntityType;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../format.dart';
import '../models.dart';
import '../widgets/common.dart';

class SendPage extends StatefulWidget {
  const SendPage({super.key, required this.controller, required this.onOpenCables});
  final AppController controller;
  final VoidCallback onOpenCables;

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> {
  bool _dragging = false;

  AppController get c => widget.controller;

  void _warnSkipped(int n) {
    if (!mounted || n <= 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(n == 1 ? 'Папки передавать нельзя - пропущена 1 позиция' : 'Папки передавать нельзя - пропущено $n')),
    );
  }

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null) return;
    c.addFiles([
      for (final f in r.files)
        if (f.path != null) PickedFile(path: f.path!, name: f.name, size: f.size),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final sending = c.phase == SendPhase.sending;
    return PageBody(children: [
      StepCard(
        number: 1,
        title: 'Выберите файлы',
        done: c.files.isNotEmpty,
        trailing: c.files.isEmpty || sending
            ? null
            : TextButton(onPressed: c.clearFiles, child: const Text('Очистить')),
        child: _filesBody(context, sending),
      ),
      StepCard(
        number: 2,
        title: 'Выберите устройство',
        done: c.selected != null,
        trailing: c.scanning
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                tooltip: 'Обновить список',
                onPressed: sending ? null : () => unawaited(c.scan()),
                icon: const Icon(Icons.refresh),
              ),
        child: _devicesBody(context, sending),
      ),
      _sendArea(context),
    ]);
  }

  Widget _filesBody(BuildContext context, bool sending) {
    final cs = Theme.of(context).colorScheme;
    final zone = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: _dragging ? cs.primaryContainer : cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _dragging ? cs.primary : cs.outlineVariant, width: _dragging ? 2 : 1),
      ),
      child: Column(children: [
        Icon(Icons.file_upload_outlined, size: 36, color: cs.primary),
        const SizedBox(height: 8),
        Text(
          isDesktopHost ? 'Перетащите файлы сюда' : 'Файлы для отправки',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: sending ? null : () => unawaited(_pick()),
          icon: const Icon(Icons.attach_file),
          label: Text(c.files.isEmpty ? 'Выбрать файлы' : 'Добавить ещё'),
        ),
      ]),
    );

    final dropZone = isDesktopHost && !sending
        ? DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (d) {
              setState(() => _dragging = false);
              final picked = <PickedFile>[];
              for (final f in d.files) {
                // XFile has no synchronous size, and a dropped folder has no size
                // at all - both would otherwise show up as 0 B and skew the total.
                final stat = FileStat.statSync(f.path);
                if (stat.type != FileSystemEntityType.file) continue;
                picked.add(PickedFile(path: f.path, name: f.name, size: stat.size));
              }
              if (picked.isNotEmpty) c.addFiles(picked);
              if (picked.length != d.files.length) _warnSkipped(d.files.length - picked.length);
            },
            child: zone,
          )
        : zone;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      dropZone,
      if (c.files.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final f in c.files)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(formatSize(f.size)),
            trailing: sending
                ? null
                : IconButton(tooltip: 'Убрать', icon: const Icon(Icons.close), onPressed: () => c.removeFile(f)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${pluralFiles(c.files.length)} · ${formatSize(c.totalSize)}',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    ]);
  }

  Widget _devicesBody(BuildContext context, bool sending) {
    final cs = Theme.of(context).colorScheme;
    if (c.peers.isEmpty) {
      return EmptyHint(
        icon: Icons.usb_off,
        title: c.scanning ? 'Ищем устройства…' : 'Устройства не найдены',
        text: 'Соедините устройства кабелем и откройте CableSend на втором. '
            'На нём должен быть включён приём.',
        action: TextButton.icon(
          onPressed: widget.onOpenCables,
          icon: const Icon(Icons.help_outline),
          label: const Text('Как подключить кабель'),
        ),
      );
    }
    return Column(children: [
      for (final p in c.peers)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            enabled: !sending,
            selected: c.selected?.id == p.id,
            selectedTileColor: cs.primaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: c.selected?.id == p.id ? cs.primary : cs.outlineVariant),
            ),
            leading: Icon(platformIcon(p.platform)),
            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${platformName(p.platform)} · ${cableShort(p.kind)}'),
            trailing: c.selected?.id == p.id ? Icon(Icons.check_circle, color: cs.primary) : null,
            onTap: () => c.select(p),
          ),
        ),
    ]);
  }

  Widget _sendArea(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (c.phase) {
      case SendPhase.sending:
        final frac = c.fileTotal == 0 ? null : c.fileDone / c.fileTotal;
        return Card(
          elevation: 0,
          color: cs.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Отправляем на ${c.selected?.name ?? 'устройство'}…', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 14),
              LinearProgressIndicator(value: frac, minHeight: 8, borderRadius: BorderRadius.circular(8)),
              const SizedBox(height: 10),
              Text(
                c.currentFile.isEmpty
                    ? 'Ждём подтверждения на втором устройстве…'
                    : 'Файл ${c.files.isEmpty ? 1 : c.fileIndex.clamp(1, c.files.length)} из ${c.files.length}: ${c.currentFile}'
                        '${frac == null ? '' : ' · ${(frac * 100).round()}%'}',
              ),
            ]),
          ),
        );
      case SendPhase.done:
        return Card(
          elevation: 0,
          color: cs.primaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Icon(Icons.check_circle, size: 44, color: cs.primary),
              const SizedBox(height: 8),
              Text('Готово: отправлено ${pluralFiles(c.sentCount)}', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              FilledButton(onPressed: c.resetSend, child: const Text('Отправить ещё')),
            ]),
          ),
        );
      case SendPhase.failed:
        return Card(
          elevation: 0,
          color: cs.errorContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.error_outline, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Text('Не удалось отправить', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onErrorContainer)),
              ]),
              const SizedBox(height: 8),
              Text(c.sendError ?? '', style: TextStyle(color: cs.onErrorContainer)),
              const SizedBox(height: 12),
              FilledButton(onPressed: c.canSend ? () => unawaited(c.send()) : null, child: const Text('Повторить')),
            ]),
          ),
        );
      case SendPhase.idle:
        final missing = c.files.isEmpty
            ? 'Сначала выберите файлы'
            : c.selected == null
                ? 'Теперь выберите устройство'
                : null;
        return Column(children: [
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: c.canSend ? () => unawaited(c.send()) : null,
              icon: const Icon(Icons.send_rounded),
              label: Text(
                c.canSend ? 'Отправить на ${c.selected!.name}' : 'Отправить',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          if (missing != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(missing, style: TextStyle(color: cs.onSurfaceVariant)),
            ),
        ]);
    }
  }
}
