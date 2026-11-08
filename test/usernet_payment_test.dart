import 'package:fl_clash/usernet/services/usernet_payment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts secure YooKassa confirmation URLs', () {
    expect(
      isValidUserNetPaymentUrl('https://yookassa.ru/checkout/123'),
      isTrue,
    );
    expect(
      isValidUserNetPaymentUrl('https://test.yookassa.ru/checkout/123'),
      isTrue,
    );
  });

  test('rejects insecure and lookalike payment hosts', () {
    expect(
      isValidUserNetPaymentUrl('http://yookassa.ru/checkout/123'),
      isFalse,
    );
    expect(
      isValidUserNetPaymentUrl('https://yookassa.ru.example.com/checkout/123'),
      isFalse,
    );
    expect(
      isValidUserNetPaymentUrl('https://example.com/checkout/123'),
      isFalse,
    );
  });
}
