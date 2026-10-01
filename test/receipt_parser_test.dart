import 'package:flutter_test/flutter_test.dart';
import 'package:juno/features/smart/receipt_parser.dart';

void main() {
  test('supermarket receipt: TOTAL beats subtotal, VAT and cash', () {
    final r = parseReceipt(
      '''
SPINNEYS ACHRAFIEH
Tel 01 123 456
Date: 28/09/2026 18:42
Milk 2L            3.20
Bread              1.50
Eggs x12           4.90
SUBTOTAL          19.60
VAT 11%            2.16
TOTAL             21.76
CASH              30.00
CHANGE             8.24
'''
          .split('\n'),
    );
    expect(r.totalCents, 2176);
    expect(r.confident, isTrue);
    expect(r.day, '2026-09-28');
    expect(r.merchant, 'Spinneys Achrafieh');
  });

  test('LBP receipt with thousands separators', () {
    final r = parseReceipt(
      '''
Fahed Supermarket
12-09-2026
Labneh        450,000
Tomatoes      180,000
Total L.L.    630,000
'''
          .split('\n'),
    );
    expect(r.totalCents, 63000000);
    expect(r.currency, 'LBP');
    expect(r.day, '2026-09-12');
  });

  test('total on the next line, dollar receipt', () {
    final r = parseReceipt(
      r'''
Kalei Coffee Co.
Flat white   $4.50
Croissant    $3.00
Amount due
$7.50
'''
          .split('\n'),
    );
    expect(r.totalCents, 750);
    expect(r.currency, 'USD');
    expect(r.merchant, 'Kalei Coffee Co.');
  });

  test('no total label: largest lower-half amount, not confident', () {
    final r = parseReceipt(
      '''
Pharmacy Mazen
Panadol 12.00
Vitamins 25.00
37.00
'''
          .split('\n'),
    );
    expect(r.totalCents, 3700);
    expect(r.confident, isFalse);
  });

  test('month-first only when day-first is impossible', () {
    expect(parseReceipt(['Shop', '09/28/2026', 'TOTAL 5.00']).day, '2026-09-28');
    expect(parseReceipt(['Shop', '03/04/2026', 'TOTAL 5.00']).day, '2026-04-03');
  });

  test('empty or garbage text reads nothing', () {
    expect(parseReceipt([]).totalCents, isNull);
    expect(parseReceipt(['~~~', '...']).totalCents, isNull);
  });
}
