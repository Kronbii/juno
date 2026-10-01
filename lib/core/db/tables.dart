import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Time-ordered ids, so rows created on different devices still sort.
String newId() => _uuid.v7();

enum TxType { expense, income, transfer }

/// Whose money it is. Every transaction belongs to exactly one scope.
enum Scope { personal, household }

enum AccountKind { cash, checking, savings, credit }

enum CategoryKind { expense, income }

enum Frequency { weekly, monthly, yearly }

/// Columns every synced table carries.
///
/// Dates that are calendar days (when money moved) are stored as
/// `YYYY-MM-DD` text: they have no timezone, compare lexically, and map to a
/// Postgres `date`. Timestamps are UTC.
mixin SyncColumns on Table {
  TextColumn get id => text().clientDefault(newId)();
  TextColumn get userId => text().nullable()();
  DateTimeColumn get createdAt => dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt => dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// Local only: changed since the last successful push.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

class Accounts extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get kind => textEnum<AccountKind>()();
  IntColumn get openingBalanceCents => integer().withDefault(const Constant(0))();
  TextColumn get currency => text().withDefault(const Constant('USD'))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
}

class Categories extends Table with SyncColumns {
  TextColumn get name => text()();

  /// Key into the app's icon map (see `category_style.dart`).
  TextColumn get icon => text()();

  /// Index into the categorical palette, resolved per theme.
  IntColumn get colorIndex => integer()();
  TextColumn get kind => textEnum<CategoryKind>()();

  /// Scope new entries in this category start in (Groceries → household).
  TextColumn get defaultScope => textEnum<Scope>().withDefault(const Constant('personal'))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
}

@TableIndex(name: 'tx_day', columns: {#occurredOn})
@TableIndex(name: 'tx_recurring_day', columns: {#recurringId, #occurredOn}, unique: true)
class Transactions extends Table with SyncColumns {
  TextColumn get type => textEnum<TxType>()();
  TextColumn get scope => textEnum<Scope>()();

  /// Always positive; [type] carries the sign.
  IntColumn get amountCents => integer()();
  TextColumn get accountId => text()();

  /// Destination account for transfers.
  TextColumn get toAccountId => text().nullable()();
  TextColumn get categoryId => text().nullable()();

  /// `YYYY-MM-DD`.
  TextColumn get occurredOn => text()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get merchant => text().withDefault(const Constant(''))();
  TextColumn get recurringId => text().nullable()();
  TextColumn get importBatchId => text().nullable()();

  /// For imported rows: hash of (day, amount, description) to flag repeats.
  TextColumn get dedupeHash => text().nullable()();
}

/// A monthly limit. Null [categoryId] means an overall cap for the scope;
/// null [scope] means it applies across both scopes.
class Budgets extends Table with SyncColumns {
  TextColumn get categoryId => text().nullable()();
  TextColumn get scope => textEnum<Scope>().nullable()();
  IntColumn get limitCents => integer()();
}

class Goals extends Table with SyncColumns {
  TextColumn get name => text()();
  IntColumn get targetCents => integer()();

  /// `YYYY-MM-DD`, optional.
  TextColumn get targetDate => text().nullable()();
  IntColumn get colorIndex => integer().withDefault(const Constant(0))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
}

class GoalContributions extends Table with SyncColumns {
  TextColumn get goalId => text()();

  /// Negative for a withdrawal.
  IntColumn get amountCents => integer()();
  TextColumn get occurredOn => text()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// A template that materialises into transactions as each due date passes.
class RecurringRules extends Table with SyncColumns {
  TextColumn get type => textEnum<TxType>()();
  TextColumn get scope => textEnum<Scope>()();
  IntColumn get amountCents => integer()();
  TextColumn get accountId => text()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get frequency => textEnum<Frequency>()();
  IntColumn get interval => integer().withDefault(const Constant(1))();

  /// First occurrence, `YYYY-MM-DD`. Monthly rules keep this day-of-month.
  TextColumn get anchorDate => text()();

  /// Next occurrence not yet materialised.
  TextColumn get nextDue => text()();
  TextColumn get endDate => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
}

class ImportBatches extends Table with SyncColumns {
  TextColumn get filename => text()();
  IntColumn get rowCount => integer()();
}

/// Local key/value state that never syncs (last pull time, seed flags).
class LocalMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
