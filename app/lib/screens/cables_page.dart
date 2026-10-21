import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import '../widgets/common.dart';

/// Shows what is plugged in and how to plug it in. The advice differs by the device
/// the app is running on: a phone cannot install adb, and a computer is never the
/// one that needs "Разрешите отладку", so the two cases get their own cards.
class CablesPage extends StatelessWidget {
  const CablesPage({super.key, required this.controller});
  final AppController controller;

  AppController get c => controller;

  /// The complement of [isDesktopHost], so an unexpected platform falls into one
  /// branch rather than silently showing the desktop advice.
  static bool get _onPhone => !isDesktopHost;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PageBody(children: [
      Text(
        'Выберите, чем соединены устройства. Статус обновляется сам, '
        'но можно проверить вручную.',
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
      ...(_onPhone ? _phoneCards(context) : _desktopCards(context)),
      _note(context),
    ]);
  }

  // ------------------------------------------------------------- this is a computer

  List<Widget> _desktopCards(BuildContext context) {
    final r = c.scanResult;
    final net = r.count(CableKind.network);
    final and = r.count(CableKind.android);
    final ios = r.count(CableKind.ios);

    return [
      _CableCard(
        kind: CableKind.network,
        status: net > 0
            ? (StatusKind.ok, 'Найдено устройств: $net')
            : (StatusKind.none, 'Устройства не найдены'),
        scanning: c.scanning,
        onCheck: () => unawaited(c.scan()),
        intro: 'Для двух компьютеров: Windows, macOS, Linux. Нужен обычный сетевой кабель '
            'или кабель Thunderbolt / USB4. Роутер и интернет не нужны.',
        sections: const [
          ('Сетевой кабель (Ethernet)', 'Соедините сетевые порты двух компьютеров. Адреса назначаются '
              'сами. На Linux в настройках проводного подключения выберите метод IPv4 «Только локальная связь» (Link-Local).'),
          ('Thunderbolt или USB4', 'macOS: включится «Thunderbolt Bridge» автоматически. '
              'Linux: загрузите модуль thunderbolt-net. Windows 11: сеть через USB4 работает не на всех компьютерах.'),
          ('На обоих компьютерах', 'Откройте CableSend. На принимающем включите «Принимать файлы», '
              'на отправляющем нажмите «Обновить».'),
        ],
      ),
      _CableCard(
        kind: CableKind.android,
        status: and > 0
            ? (StatusKind.ok, 'Подключено: $and')
            : r.androidUnauthorized
                ? (StatusKind.warn, 'Разрешите отладку на телефоне')
                : r.adbMissing
                    ? (StatusKind.warn, 'Нужна программа adb')
                    : r.androidError != null
                        ? (StatusKind.warn, 'Android недоступен')
                        : (StatusKind.none, 'Телефон не найден'),
        detail: and > 0 ? null : r.androidError,
        scanning: c.scanning,
        onCheck: () => unawaited(c.scan()),
        intro: 'Телефон соединяется с компьютером USB-кабелем. На телефоне должно быть '
            'открыто приложение CableSend.',
        sections: const [
          ('1. Установите adb', 'Скачайте Android platform-tools с developer.android.com и добавьте '
              'папку в PATH (или положите рядом с CableSend).'),
          ('2. Включите отладку по USB', 'Настройки → О телефоне → 7 раз нажмите «Номер сборки». '
              'Затем Настройки → Для разработчиков → «Отладка по USB».'),
          ('3. Подключите кабель', 'На экране телефона нажмите «Разрешить отладку по USB» '
              '(лучше с галочкой «Всегда разрешать»).'),
        ],
      ),
      _CableCard(
        kind: CableKind.ios,
        status: ios > 0
            ? (StatusKind.ok, 'Подключено: $ios')
            : r.iosServiceMissing
                ? (StatusKind.warn, 'Служба Apple не установлена')
                : r.iosError != null
                    ? (StatusKind.warn, 'iPhone недоступен')
                    : (StatusKind.none, 'iPhone не найден'),
        detail: ios > 0 ? null : r.iosError,
        scanning: c.scanning,
        onCheck: () => unawaited(c.scan()),
        intro: 'iPhone или iPad соединяется с компьютером кабелем Lightning или USB-C. '
            'Приложение CableSend на нём должно быть открыто на экране.',
        sections: const [
          ('Windows', 'Установите iTunes или приложение «Apple Devices» из Microsoft Store — '
              'оно ставит нужную службу.'),
          ('macOS', 'Ничего ставить не нужно.'),
          ('Linux', 'Установите пакет usbmuxd (например: sudo apt install usbmuxd).'),
          ('На самом iPhone', 'Разблокируйте экран и нажмите «Доверять этому компьютеру».'),
        ],
      ),
    ];
  }

  // ------------------------------------------------------------- this is a phone

  List<Widget> _phoneCards(BuildContext context) {
    final r = c.scanResult;
    final net = r.count(CableKind.network);
    final host = r.count(CableKind.usbHost);

    return [
      _CableCard(
        kind: CableKind.usbHost,
        status: host > 0
            ? (StatusKind.ok, 'Компьютер подключён')
            : (StatusKind.none, 'Компьютер не найден'),
        scanning: c.scanning,
        onCheck: () => unawaited(c.scan()),
        intro: Platform.isAndroid
            ? 'Соедините телефон с компьютером USB-кабелем. Настраивать нужно на стороне '
                'компьютера — на телефоне достаточно открыть это приложение.'
            : 'iPhone соединяется с компьютером кабелем. Отправлять файлы на компьютер '
                'по этому же кабелю iOS не разрешает, поэтому здесь работает только приём.',
        sections: Platform.isAndroid
            ? const [
                ('1. Включите отладку по USB', 'Настройки → О телефоне → 7 раз нажмите «Номер сборки». '
                    'Затем Настройки → Для разработчиков → «Отладка по USB». При подключении нажмите «Разрешить».'),
                ('2. Чтобы принимать файлы с компьютера', 'Включите «Принимать файлы» на этом экране приёма. '
                    'Дальше на компьютере выберите телефон в списке устройств.'),
                ('3. Чтобы отправлять на компьютер', 'На компьютере запустите приём с ключом '
                    '--adb-reverse. После этого компьютер появится в списке устройств здесь.'),
              ]
            : const [
                ('Приём файлов с компьютера', 'Включите «Принимать файлы» и держите приложение открытым: '
                    'в фоне iOS останавливает приём. На компьютере нужны iTunes или «Apple Devices» (Windows) '
                    'либо пакет usbmuxd (Linux).'),
                ('Отправка с iPhone на компьютер', 'По USB так нельзя: iOS не даёт приложению самому '
                    'подключиться к компьютеру. Включите «Режим модема» по USB — тогда это обычная '
                    'сеть, и компьютер найдётся как обычное устройство.'),
                ('Доверие к компьютеру', 'При первом подключении разблокируйте экран и нажмите '
                    '«Доверять этому компьютеру».'),
              ],
      ),
      _CableCard(
        kind: CableKind.network,
        status: net > 0
            ? (StatusKind.ok, 'Найдено устройств: $net')
            : (StatusKind.none, 'Устройства не найдены'),
        scanning: c.scanning,
        onCheck: () => unawaited(c.scan()),
        intro: 'Телефон можно подключить и сетевым кабелем — через USB-адаптер '
            'USB-Ethernet. Так работает даже связь двух телефонов между собой.',
        sections: const [
          ('Что нужно', 'USB-адаптер с разъёмом для сетевого кабеля на каждом устройстве '
              'и обычный патч-корд между ними.'),
          ('Как проверить', 'Подключите адаптеры, откройте CableSend на обоих устройствах, '
              'включите приём на одном и нажмите «Проверить».'),
        ],
      ),
    ];
  }

  Widget _note(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.tertiaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.warning_amber_rounded, color: cs.onTertiaryContainer),
            const SizedBox(width: 8),
            Text('Телефон с телефоном',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onTertiaryContainer)),
          ]),
          const SizedBox(height: 8),
          Text(
            'Два телефона одним USB-кабелем напрямую не соединить: iPhone и Android этого не позволяют. '
            'Варианты: подключите оба к компьютеру или используйте USB-Ethernet адаптеры и сетевой кабель.',
            style: TextStyle(color: cs.onTertiaryContainer),
          ),
        ]),
      ),
    );
  }
}

class _CableCard extends StatelessWidget {
  const _CableCard({
    required this.kind,
    required this.status,
    required this.scanning,
    required this.onCheck,
    required this.intro,
    required this.sections,
    this.detail,
  });

  final CableKind kind;
  final (StatusKind, String) status;
  final bool scanning;
  final VoidCallback onCheck;
  final String intro;
  final List<(String, String)> sections;

  /// The core's own words about what went wrong, shown under the status chip.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: cs.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(cableIcon(kind), size: 28, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(cableTitle(kind), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(label: status.$2, kind: status.$1),
              TextButton.icon(
                onPressed: scanning ? null : onCheck,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Проверить'),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ],
          const SizedBox(height: 4),
          Text(intro, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          for (final s in sections)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(s.$1, style: const TextStyle(fontWeight: FontWeight.w500)),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              expandedAlignment: Alignment.centerLeft,
              children: [Text(s.$2)],
            ),
        ]),
      ),
    );
  }
}
