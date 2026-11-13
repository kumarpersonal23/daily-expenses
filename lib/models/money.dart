import 'package:intl/intl.dart';

const maxMoneyPaise = 999999999999;
int parseMoney(String input, {bool allowZero = false}) {
  final value = input.trim();
  if (!RegExp(r'^\d{1,10}(\.\d{1,2})?$').hasMatch(value)) {
    throw const FormatException('Enter rupees with up to 2 decimal places.');
  }
  final parts = value.split('.');
  final result =
      int.parse(parts[0]) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  if (result > maxMoneyPaise || result < (allowZero ? 0 : 1)) {
    throw const FormatException('Enter a valid positive amount.');
  }
  return result;
}

String money(int paise) {
  final sign = paise < 0 ? '−' : '';
  final n = paise.abs();
  return '$sign₹${NumberFormat('#,##,##0', 'en_IN').format(n ~/ 100)}.${(n % 100).toString().padLeft(2, '0')}';
}

String moneyInput(int paise) =>
    '${paise ~/ 100}.${(paise % 100).toString().padLeft(2, '0')}';
String dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
DateTime? nextInMonth(DateTime date) {
  final next = DateTime(date.year, date.month, date.day + 1);
  return next.month == date.month ? next : null;
}
