// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later

bool isValidUserNetPaymentUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      uri.scheme == 'https' &&
      (uri.host == 'yookassa.ru' || uri.host.endsWith('.yookassa.ru'));
}
