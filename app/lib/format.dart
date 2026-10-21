String formatSize(int bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1).replaceAll('.', ',');
  return '$s ${units[i]}';
}

String pluralFiles(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return '$n файл';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$n файла';
  return '$n файлов';
}

/// Turns a technical error from the core into a sentence a person can act on.
///
/// The phrases matched here are the core's own wording (src/transport.rs,
/// src/transfer.rs, src/proto.rs). Keep the two in step: an unmatched message is
/// shown to the person as-is, in English.
String friendlyError(String raw) {
  final m = raw.toLowerCase();
  if (m.contains('rejected')) return 'Получатель отклонил передачу.';
  if (m.contains('protocol version mismatch')) {
    return 'На устройствах разные версии CableSend. Обновите приложение на обоих.';
  }
  if (m.contains('no ios device')) {
    return 'iPhone не найден. Разблокируйте его и нажмите «Доверять».';
  }
  if (m.contains('usbmuxd connect refused')) {
    return 'На iPhone не открыто приложение CableSend. Откройте его и повторите.';
  }
  if (m.contains('usbmuxd not reachable')) {
    return 'Нет службы для работы с iPhone. На Windows установите iTunes или «Apple Devices», '
        'на Linux — пакет usbmuxd.';
  }
  if (m.contains('cannot run `adb`')) {
    return 'Не найден adb. Установите Android platform-tools (см. вкладку «Кабели»).';
  }
  if (m.contains('app not listening')) {
    return 'Телефон подключён, но приложение на нём не принимает файлы. '
        'Откройте CableSend на телефоне и включите приём.';
  }
  if (m.contains('unauthorized')) {
    return 'Разрешите отладку по USB на экране телефона и повторите.';
  }
  if (m.contains('cannot use save folder') || m.contains('filesystemexception')) {
    return 'Не удалось записать в папку для сохранения. Выберите другую папку.';
  }
  if (m.contains('refused') || m.contains('timed out') || m.contains('unreachable')) {
    return 'Устройство не отвечает. Проверьте кабель и что на втором устройстве открыт приём.';
  }
  if (m.contains('checksum')) {
    return 'Файл повредился при передаче. Попробуйте ещё раз.';
  }
  if (m.contains('address already in use')) {
    return 'Порт уже занят: приём, видимо, уже запущен в другом окне.';
  }
  if (m.contains('receiver already running')) {
    return 'Приём уже запущен.';
  }
  if (m.contains('not a file')) {
    return 'Папки передавать нельзя — выберите файлы.';
  }
  if (m.contains('file shrank while sending')) {
    return 'Файл изменился во время отправки. Отправьте его заново.';
  }
  if (m.contains('too many files')) {
    return 'Слишком много файлов за один раз. Отправьте их частями.';
  }
  if (m.contains('cannot resolve address') || m.contains('no peers found')) {
    return 'Устройство не найдено. Проверьте кабель и нажмите «Обновить».';
  }
  return raw;
}
