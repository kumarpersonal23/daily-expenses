import 'package:drift/drift.dart';
import '../database/app_database.dart';
import '../models/money.dart';
import '../services/bill_files.dart';

class Ledger {
  final AppDatabase db;
  Ledger(this.db);
  Future<Month> month(int year, int month) => db.transaction(() async {
    if (year < 1900 || year > 2200 || month < 1 || month > 12) {
      throw const FormatException('Invalid month.');
    }
    var row =
        await (db.select(db.months)
              ..where((t) => t.year.equals(year) & t.month.equals(month)))
            .getSingleOrNull();
    if (row != null) return row;
    final id = await db
        .into(db.months)
        .insert(MonthsCompanion.insert(year: year, month: month));
    await db
        .into(db.days)
        .insert(
          DaysCompanion.insert(
            monthId: id,
            expenseDate: dateKey(DateTime(year, month, 1)),
          ),
        );
    row = await (db.select(
      db.months,
    )..where((t) => t.id.equals(id))).getSingle();
    return row;
  });
  Future<List<Day>> days(int monthId) =>
      (db.select(db.days)
            ..where((t) => t.monthId.equals(monthId))
            ..orderBy([(t) => OrderingTerm.asc(t.expenseDate)]))
          .get();
  Future<List<Expense>> expenses(int dayId) =>
      (db.select(db.expenses)
            ..where((t) => t.dayId.equals(dayId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sortOrder),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();
  Future<List<ExpenseAttachment>> attachments(int expenseId) => (db.select(
    db.expenseAttachments,
  )..where((t) => t.expenseId.equals(expenseId))).get();
  Future<int> total({int? dayId, int? monthId}) async {
    final result = await db
        .customSelect(
          'SELECT COALESCE(SUM(e.amount_paise),0) AS total FROM expenses e JOIN days d ON d.id=e.day_id WHERE ${dayId != null ? 'd.id' : 'd.month_id'} = ?',
          variables: [Variable.withInt(dayId ?? monthId!)],
        )
        .getSingle();
    return result.read<int>('total');
  }

  Future<int> save({
    int? id,
    required int dayId,
    required String name,
    required int paise,
    List<StagedBill> bills = const [],
  }) => db.transaction(() async {
    if (name.trim().isEmpty ||
        name.trim().length > 200 ||
        paise <= 0 ||
        paise > maxMoneyPaise) {
      throw const FormatException(
        'Enter particulars (1–200 characters) and a valid amount.',
      );
    }
    int expenseId;
    if (id == null) {
      final day = await (db.select(
        db.days,
      )..where((t) => t.id.equals(dayId))).getSingle();
      if (day.status != 'open') {
        throw StateError(
          'This day is closed. Edit an existing expense or reopen it first.',
        );
      }
      final max = await db
          .customSelect(
            'SELECT COALESCE(MAX(sort_order),0) AS n FROM expenses WHERE day_id=?',
            variables: [Variable.withInt(dayId)],
          )
          .getSingle();
      expenseId = await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              dayId: dayId,
              particulars: name.trim(),
              amountPaise: paise,
              sortOrder: max.read<int>('n') + 1,
            ),
          );
    } else {
      final changed =
          await (db.update(
            db.expenses,
          )..where((t) => t.id.equals(id) & t.dayId.equals(dayId))).write(
            ExpensesCompanion(
              particulars: Value(name.trim()),
              amountPaise: Value(paise),
              updatedAt: Value(DateTime.now()),
            ),
          );
      if (changed != 1) throw StateError('Expense no longer exists.');
      expenseId = id;
    }
    for (final bill in bills) {
      await attach(expenseId, bill);
    }
    return expenseId;
  });
  Future<void> attach(int expenseId, StagedBill bill) async {
    await db
        .into(db.expenseAttachments)
        .insert(
          ExpenseAttachmentsCompanion.insert(
            expenseId: expenseId,
            storedFilename: bill.relative.split('/').last,
            originalFilename: bill.original,
            relativeFilePath: bill.relative,
            mimeType: bill.mime,
            fileSize: bill.size,
          ),
        );
  }

  Future<List<String>> deleteExpense(int id) => db.transaction(() async {
    final paths = (await attachments(
      id,
    )).map((a) => a.relativeFilePath).toList();
    await (db.delete(db.expenses)..where((t) => t.id.equals(id))).go();
    // UI serial numbers are row positions, never persistent identifiers.
    return paths;
  });
  Future<void> closeDay(Day day) => db.transaction(() async {
    final current = await (db.select(
      db.days,
    )..where((t) => t.id.equals(day.id))).getSingle();
    if (current.status != 'open') throw StateError('Day is already closed.');
    await (db.update(db.days)..where((t) => t.id.equals(day.id))).write(
      DaysCompanion(
        status: const Value('closed'),
        closedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
    // Reopened dates return to the next existing date, or create the next calendar day.
    final next = nextInMonth(DateTime.parse(day.expenseDate));
    if (next == null) return;
    final existing = await (db.select(
      db.days,
    )..where((t) => t.expenseDate.equals(dateKey(next)))).getSingleOrNull();
    if (existing == null) {
      await db
          .into(db.days)
          .insert(
            DaysCompanion.insert(
              monthId: day.monthId,
              expenseDate: dateKey(next),
            ),
          );
    } else {
      await (db.update(db.days)..where((t) => t.id.equals(existing.id))).write(
        DaysCompanion(
          status: const Value('open'),
          closedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );
    }
  });
  Future<void> reopen(Day day) => db.transaction(() async {
    await (db.update(db.days)..where(
          (t) => t.monthId.equals(day.monthId) & t.status.equals('open'),
        ))
        .write(
          DaysCompanion(
            status: const Value('closed'),
            closedAt: Value(DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
    await (db.update(db.days)..where((t) => t.id.equals(day.id))).write(
      DaysCompanion(
        status: const Value('open'),
        closedAt: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });
  Future<void> opening(int monthId, int paise) async {
    if (paise < 0 || paise > maxMoneyPaise) {
      throw const FormatException('Invalid opening amount.');
    }
    await (db.update(db.months)..where((t) => t.id.equals(monthId))).write(
      MonthsCompanion(
        openingAmountPaise: Value(paise),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<String?> setting(String key) async => (await (db.select(
    db.settings,
  )..where((t) => t.key.equals(key))).getSingleOrNull())?.value;
  Future<void> setSetting(String key, String value) async {
    await db
        .into(db.settings)
        .insert(
          SettingsCompanion.insert(
            key: key,
            value: value,
            updatedAt: Value(DateTime.now()),
          ),
          onConflict: DoUpdate(
            (_) => SettingsCompanion(
              value: Value(value),
              updatedAt: Value(DateTime.now()),
            ),
            target: [db.settings.key],
          ),
        );
  }
}
