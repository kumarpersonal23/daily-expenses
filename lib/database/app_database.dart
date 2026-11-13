// Drift column checks reference generated getters, not these DSL getters.
// ignore_for_file: recursive_getters
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
part 'app_database.g.dart';

class Settings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get key => text().unique()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

class Months extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get year => integer().check(year.isBetweenValues(1900, 2200))();
  IntColumn get month => integer().check(month.isBetweenValues(1, 12))();
  IntColumn get openingAmountPaise => integer()
      .withDefault(const Constant(0))
      .check(openingAmountPaise.isBiggerOrEqualValue(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  @override
  List<Set<Column>> get uniqueKeys => [
    {year, month},
  ];
}

class Days extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get monthId =>
      integer().references(Months, #id, onDelete: KeyAction.cascade)();
  TextColumn get expenseDate => text().unique()();
  TextColumn get status => text()
      .withDefault(const Constant('open'))
      .check(status.isIn(['open', 'closed']))();
  DateTimeColumn get closedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

class Expenses extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get dayId =>
      integer().references(Days, #id, onDelete: KeyAction.cascade)();
  TextColumn get particulars => text().withLength(min: 1, max: 200)();
  IntColumn get amountPaise =>
      integer().check(amountPaise.isBiggerThanValue(0))();
  IntColumn get sortOrder => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  @override
  List<Set<Column>> get uniqueKeys => [
    {dayId, sortOrder},
  ];
}

class ExpenseAttachments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get expenseId =>
      integer().references(Expenses, #id, onDelete: KeyAction.cascade)();
  TextColumn get storedFilename => text()();
  TextColumn get originalFilename => text()();
  TextColumn get relativeFilePath => text().unique()();
  TextColumn get mimeType => text()();
  IntColumn get fileSize => integer().check(fileSize.isBiggerThanValue(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  IntColumn get colour => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(
  tables: [Settings, Months, Days, Expenses, ExpenseAttachments, Categories],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);
  factory AppDatabase.file(File file) => AppDatabase(NativeDatabase(file));
  @override
  int get schemaVersion => 2;
  // Version 2 adds indexes only. Version 1 fixtures remain readable without data loss.
  Future<void> indexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS expenses_day_idx ON expenses(day_id, sort_order)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS attachments_expense_idx ON expense_attachments(expense_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS days_month_idx ON days(month_id, expense_date)',
    );
    await customStatement(
      "CREATE UNIQUE INDEX IF NOT EXISTS one_open_day_per_month ON days(month_id) WHERE status = 'open'",
    );
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await indexes();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await indexes();
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );
}
