import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import '../database/app_database.dart';
import '../models/money.dart';
import '../services/app_store.dart';
import '../services/bill_files.dart';
import 'common.dart';
import 'bills.dart';
import 'settings.dart';

class DayView {
  final Day day;
  final List<Expense> expenses;
  final int total;
  final Set<int> withBills;
  DayView(this.day, this.expenses, this.total, this.withBills);
}

class HomeScreen extends StatefulWidget {
  final AppStore store;
  const HomeScreen({super.key, required this.store});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime selected = DateTime(DateTime.now().year, DateTime.now().month);
  Month? month;
  List<DayView> rows = [];
  int spent = 0;
  bool hidden = true, busy = false, loading = true;
  String? loadError;
  final expanded = <int>{};
  final name = TextEditingController(), amount = TextEditingController();
  final nameFocus = FocusNode(), amountFocus = FocusNode();
  final pending = <StagedBill>[];
  Expense? editing;
  int revision = 0;
  Map<int, String> categoryNames = {};
  @override
  void initState() {
    super.initState();
    widget.store.addListener(refresh);
    initialise();
  }

  Future<void> initialise() async {
    try {
      final pref = await widget.store.ledger.setting('selected_month');
      if (pref != null) selected = DateTime.parse(pref);
      hidden = await widget.store.ledger.setting('hide_balance') != 'false';
      await refresh();
      final lost = await ImagePicker().retrieveLostData();
      if (lost.files != null) {
        for (final file in lost.files!) {
          pending.add(
            await widget.store.files.importFile(file.path, original: file.name),
          );
        }
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Recovered camera bills. Add them to an expense.'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) { showError(context, e); }
    }
  }

  Future<void> refresh() async {
    final ticket = ++revision;
    try {
      final m = await widget.store.ledger.month(selected.year, selected.month);
      categoryNames = {for (final c in await widget.store.ledger.categoryList()) c.id: c.name};
      final days = await widget.store.ledger.days(m.id);
      final result = <DayView>[];
      for (final day in days) {
        final expenses = await widget.store.ledger.expenses(day.id);
        final withBills = <int>{};
        for (final e in expenses) {
          if ((await widget.store.ledger.attachments(e.id)).isNotEmpty) {
            withBills.add(e.id);
          }
        }
        result.add(
          DayView(
            day,
            expenses,
            await widget.store.ledger.total(dayId: day.id),
            withBills,
          ),
        );
      }
      final total = await widget.store.ledger.total(monthId: m.id);
      if (mounted && ticket == revision) {
        setState(() {
          month = m;
          rows = result;
          spent = total;
          loading = false;
          loadError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          loadError = 'Could not load the ledger. Tap retry.';
        });
      }
    }
  }

  DayView? get active {
    for (final row in rows) {
      if (row.day.status == 'open') return row;
    }
    return null;
  }

  @override
  void dispose() {
    widget.store.removeListener(refresh);
    name.dispose();
    amount.dispose();
    nameFocus.dispose();
    amountFocus.dispose();
    super.dispose();
  }

  Future<void> act(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (e) {
      if (mounted) { showError(context, e); }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() => act(() async {
    final dayId = editing?.dayId ?? active?.day.id;
    if (dayId == null) {
      throw const FormatException(
        'This month is complete. Reopen a date to add expenses.',
      );
    }
    final value = parseMoney(amount.text);
    final savedId = await widget.store.mutate(
      () => widget.store.ledger.save(
        id: editing?.id,
        dayId: dayId,
        name: name.text,
        paise: value,
        bills: List.of(pending),
      ),
    );
    pending.clear();
    name.clear();
    amount.clear();
    editing = null;
    await refresh();
    nameFocus.requestFocus();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, margin: const EdgeInsets.fromLTRB(8, 0, 8, 132), content: const Text('Expense saved · Category optional'), action: SnackBarAction(label: 'Category', onPressed: () => chooseCategory(savedId))));
    }
  });
  Future<void> chooseCategory(int expenseId) async {
    try {
      final categories = await widget.store.ledger.categoryList();
      if (!mounted) { return; }
      FocusScope.of(context).unfocus();
      final selected = await showModalBottomSheet<int>(context: context, isScrollControlled: true, builder: (c) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(c).height * .65, child: Column(children: [
        ListTile(title: const Text('Category (optional)'), subtitle: const Text('You can set or change this later.'), trailing: IconButton(tooltip: 'Later', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(c))),
        Expanded(child: ListView(children: [ListTile(title: const Text('No category / clear category'), onTap: () => Navigator.pop(c, 0)), for (final category in categories) ListTile(dense: true, title: Text(category.name), onTap: () => Navigator.pop(c, category.id))]))
      ]))));
      if (selected == null) { return; }
      await widget.store.mutate(() => widget.store.ledger.assignCategory(expenseId, selected == 0 ? null : selected));
      await refresh();
    } catch (e) { if (mounted) { showError(context, e); } }
  }
  Future<void> clearDraft() async {
    for (final bill in pending) {
      await widget.store.files.remove(bill.relative);
    }
    pending.clear();
    name.clear();
    amount.clear();
    editing = null;
  }

  bool get dirty =>
      name.text.isNotEmpty || amount.text.isNotEmpty || pending.isNotEmpty;
  Future<bool> discard() async {
    if (dirty &&
        !await confirm(
          context,
          'Discard unsaved entry?',
          'Saved expenses remain. This unfinished entry will be cleared.',
        )) {
      return false;
    }
    await clearDraft();
    return true;
  }

  Future<void> edit(Expense expense) async {
    if (!await discard()) return;
    setState(() {
      editing = expense;
      name.text = expense.particulars;
      amount.text = moneyInput(expense.amountPaise);
    });
    nameFocus.requestFocus();
  }

  Future<void> chooseMonth() async {
    final date = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200, 12, 31),
      helpText: 'Choose any date in the month',
    );
    if (date == null || !mounted || !await discard()) return;
    setState(() {
      selected = DateTime(date.year, date.month);
      loading = true;
      expanded.clear();
    });
    await widget.store.ledger.setSetting('selected_month', dateKey(selected));
    await refresh();
  }

  Future<void> closeDay() => act(() async {
    if (active == null) return;
    if (editing != null) {
      throw const FormatException(
        'Save or cancel the edit before closing the day.',
      );
    }
    if (dirty) {
      final value = parseMoney(amount.text);
      await widget.store.mutate(
        () => widget.store.db.transaction(() async {
          await widget.store.ledger.save(
            dayId: active!.day.id,
            name: name.text,
            paise: value,
            bills: List.of(pending),
          );
          await widget.store.ledger.closeDay(active!.day);
        }),
      );
      pending.clear();
      name.clear();
      amount.clear();
    } else {
      await widget.store.mutate(
        () => widget.store.ledger.closeDay(active!.day),
      );
    }
    expanded.clear();
    await refresh();
  });
  Widget expenseRow(Expense e, int index, Day day) => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xffeee9f4), width: .6)),
    ),
    child: Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(
            '${index + 1}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        Expanded(
          child: InkWell(onTap: busy ? null : () => chooseCategory(e.id), child: Text(
            e.categoryId == null ? e.particulars : '${e.particulars} · ${categoryNames[e.categoryId] ?? ''}',
            style: const TextStyle(fontSize: 13),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          )),
        ),
        SizedBox(
          width: 91,
          child: Text(
            money(e.amountPaise),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        compactIcon(
          rows.firstWhere((r) => r.day.id == day.id).withBills.contains(e.id)
              ? Icons.attach_file
              : Icons.add_link,
          'View or attach bills',
          busy
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => BillsScreen(
                      store: widget.store,
                      expenseId: e.id,
                      initialMonth: selected,
                    ),
                  ),
                ),
          color: Colors.teal,
        ),
        compactIcon(
          Icons.edit_outlined,
          'Edit ${e.particulars}',
          busy ? null : () => edit(e),
          color: Colors.deepPurple,
        ),
      ],
    ),
  );
  Widget dayTable(DayView view) => Column(
    children: [
      if (view.expenses.isEmpty)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'No expenses yet. Add one below.',
            style: TextStyle(color: Colors.blueGrey),
          ),
        ),
      for (var i = 0; i < view.expenses.length; i++)
        expenseRow(view.expenses[i], i, view.day),
      Container(
        color: const Color(0xffedf8f3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Daily total',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
            Text(
              money(view.total),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xff13775d),
              ),
            ),
          ],
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty && !busy,
    onPopInvokedWithResult: (didPop, _) async {
      if (!didPop && !busy && await discard() && mounted) setState(() {});
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Daily Expenses'),
        actions: [
          TextButton(
            onPressed: busy ? null : chooseMonth,
            child: Text(DateFormat('MMM yy').format(selected)),
          ),
          compactIcon(
            Icons.settings_outlined,
            'Settings',
            busy || month == null
                ? null
                : () async {
                    if (!await discard() || !context.mounted) return;
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(
                          store: widget.store,
                          month: month!,
                          onMonth: (d) => selected = d,
                        ),
                      ),
                    );
                    hidden =
                        await widget.store.ledger.setting('hide_balance') !=
                        'false';
                    await refresh();
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xfff1ebff),
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Month ${money(spent)}\nDay ${money(active?.total ?? 0)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    hidden
                        ? 'Balance ••••'
                        : money((month?.openingAmountPaise ?? 0) - spent),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff3255a2),
                    ),
                  ),
                  compactIcon(
                    hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    hidden ? 'Show balance' : 'Hide balance',
                    () => setState(() => hidden = !hidden),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : loadError != null
                  ? Center(
                      child: TextButton(
                        onPressed: refresh,
                        child: Text(loadError!),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      children: [
                        for (final row in rows.where(
                          (r) => r.day.status == 'closed',
                        )) ...[
                          InkWell(
                            onTap: () => setState(() {
                              if (!expanded.add(row.day.id)) {
                                expanded.remove(row.day.id);
                              }
                            }),
                            child: Row(
                              children: [
                                compactIcon(
                                  expanded.contains(row.day.id)
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  'Expand or collapse date',
                                  () => setState(() {
                                    if (!expanded.add(row.day.id)) {
                                      expanded.remove(row.day.id);
                                    }
                                  }),
                                ),
                                Expanded(
                                  child: Text(
                                    DateFormat('dd MMM').format(
                                      DateTime.parse(row.day.expenseDate),
                                    ),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  money(row.total),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                compactIcon(
                                  Icons.history,
                                  'Reopen this day',
                                  busy
                                      ? null
                                      : () async {
                                          if (await confirm(
                                            context,
                                            'Reopen this date?',
                                            'Make ${row.day.expenseDate} active? Other dates and bills remain saved.',
                                          )) {
                                            if (!await discard()) return;
                                            await act(() async {
                                              await widget.store.mutate(
                                                () => widget.store.ledger
                                                    .reopen(row.day),
                                              );
                                              await refresh();
                                            });
                                          }
                                        },
                                ),
                              ],
                            ),
                          ),
                          if (expanded.contains(row.day.id)) dayTable(row),
                          const Divider(height: 1),
                        ],
                        if (active != null) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 6,
                            ),
                            child: Text(
                              '${DateFormat('EEEE, dd MMM').format(DateTime.parse(active!.day.expenseDate))} · Active day',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.deepPurple,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const Row(
                            children: [
                              SizedBox(
                                width: 30,
                                child: Text(
                                  'No.',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'Particulars',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              SizedBox(
                                width: 91,
                                child: Text(
                                  'Amount',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              SizedBox(
                                width: 96,
                                child: Text(
                                  'Bill     Edit',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                          dayTable(active!),
                        ] else
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Month completed. Expand dates to edit, or reopen a date to add an expense.',
                            ),
                          ),
                      ],
                    ),
            ),
            if (editing != null)
              Container(
                color: const Color(0xfffff0d5),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Text(
                          'Editing saved expense #${editing!.id}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    compactIcon(Icons.category_outlined, 'Set category (optional)', busy ? null : () => chooseCategory(editing!.id), color: Colors.teal),
                    compactIcon(
                      Icons.delete_outline,
                      'Delete expense',
                      busy
                          ? null
                          : () async {
                              if (!await confirm(
                                context,
                                'Delete expense?',
                                'Remove the expense and its attached bills?',
                              )) {
                                return;
                              }
                              await act(() async {
                                await widget.store.mutate(() async {
                                  final paths = await widget.store.ledger
                                      .deleteExpense(editing!.id);
                                  for (final path in paths) {
                                    try {
                                      await widget.store.files.remove(path);
                                    } catch (_) {}
                                  }
                                });
                                await clearDraft();
                                await refresh();
                              });
                            },
                    ),
                    compactIcon(
                      Icons.close,
                      'Cancel edit',
                      busy
                          ? null
                          : () async {
                              if (await discard()) setState(() {});
                            },
                    ),
                  ],
                ),
              ),
            if (pending.isNotEmpty)
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final bill in pending)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: InputChip(
                          label: Text(
                            bill.original,
                            style: const TextStyle(fontSize: 10),
                          ),
                          onDeleted: busy
                              ? null
                              : () async {
                                  await widget.store.files.remove(
                                    bill.relative,
                                  );
                                  setState(() => pending.remove(bill));
                                },
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: name,
                      focusNode: nameFocus,
                      enabled: !busy && (active != null || editing != null),
                      style: const TextStyle(fontSize: 13),
                      maxLength: 200,
                      decoration: const InputDecoration(
                        hintText: 'Expense particulars',
                        counterText: '',
                      ),
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => amountFocus.requestFocus(),
                    ),
                  ),
                  const SizedBox(width: 5),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: amount,
                      focusNode: amountFocus,
                      enabled: !busy && (active != null || editing != null),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [LengthLimitingTextInputFormatter(13)],
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(hintText: '₹ 0.00'),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => save(),
                    ),
                  ),
                  compactIcon(
                    Icons.attach_file,
                    'Attach bill',
                    busy
                        ? null
                        : () => act(() async {
                            final bills = await pickBills(
                              context,
                              widget.store,
                            );
                            setState(() => pending.addAll(bills));
                          }),
                    color: Colors.blue,
                  ),
                  compactIcon(
                    editing == null ? Icons.arrow_forward_rounded : Icons.check,
                    editing == null ? 'Add expense / Next row' : 'Save changes',
                    busy ? null : save,
                    color: Colors.deepPurple,
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => BillsScreen(
                                store: widget.store,
                                initialMonth: selected,
                              ),
                            ),
                          ),
                    icon: const Icon(Icons.receipt_long, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('View Bills'),
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: busy || active == null ? null : closeDay,
                    icon: const Icon(Icons.event_available, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Close Day / Next'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
