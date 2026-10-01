import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/features/insights/review.dart';

var _n = 0;
Transaction tx(
  String day,
  int cents, {
  TxType type = TxType.expense,
  String? cat,
  Scope scope = Scope.personal,
  String note = '',
}) => Transaction(
  id: 't${_n++}',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: scope,
  amountCents: cents,
  accountId: 'a',
  categoryId: cat,
  occurredOn: day,
  note: note,
  merchant: '',
  currency: 'USD',
  tags: '',
);

void main() {
  test('month review: deltas, budgets, goals, biggest, and the text summary', () {
    final r = buildReview(
      label: 'September 2026',
      previousLabel: 'August',
      current: [
        tx('2026-09-01', 500000, type: TxType.income),
        tx('2026-09-02', 145000, cat: 'rent', scope: Scope.household, note: 'Rent'),
        tx('2026-09-10', 40000, cat: 'dining'),
      ],
      previous: [
        tx('2026-08-02', 145000, cat: 'rent', scope: Scope.household),
        tx('2026-08-10', 20000, cat: 'dining'),
      ],
      budgets: [
        Budget(
          id: 'b1',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          dirty: false,
          categoryId: 'dining',
          limitCents: 30000,
        ),
        Budget(
          id: 'b2',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          dirty: false,
          categoryId: 'rent',
          limitCents: 150000,
        ),
      ],
      contributions: [
        GoalContribution(
          id: 'g',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          dirty: false,
          goalId: 'x',
          amountCents: 50000,
          occurredOn: '2026-09-15',
          note: '',
        ),
      ],
      months: [DateTime(2026, 9)],
    );
    expect(r.now.expense, 185000);
    expect(r.spentDelta, 20000);
    expect(r.categoryMoves.single, ('dining', 40000, 20000)); // rent unchanged → not a move
    expect(r.budgetsMet, 1);
    expect(r.budgetsMissed, 1);
    expect(r.goalCents, 50000);
    expect(r.biggest!.note, 'Rent');
    final text = r.toText({'dining': 'Dining', 'rent': 'Rent'});
    expect(text, contains(r'Spent $1,850 (+$200 vs August)'));
    expect(text, contains('Kept'.toLowerCase()));
    expect(text, contains(r'Dining $400 (+$200)'));
    expect(text, contains('Budgets: 1 kept, 1 over'));
    expect(text, contains(r'Biggest: $1,450 on Rent'));
  });
}
