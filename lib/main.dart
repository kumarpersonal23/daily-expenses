import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/app_store.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(DailyExpensesApp(store: await AppStore.open()));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Could not open Daily Expenses. Restart the app. Do not uninstall: your data may still be recoverable.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DailyExpensesApp extends StatefulWidget {
  final AppStore store;
  const DailyExpensesApp({super.key, required this.store});
  @override
  State<DailyExpensesApp> createState() => _DailyExpensesAppState();
}

class _DailyExpensesAppState extends State<DailyExpensesApp>
    with WidgetsBindingObserver {
  bool locked = true, checking = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    check();
  }

  Future<void> check() async {
    final enabled = await widget.store.pin.enabled;
    if (mounted) {
      setState(() {
        locked = enabled;
        checking = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      setState(() => locked = true);
      check();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Daily Expenses',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff7047c6)),
      scaffoldBackgroundColor: const Color(0xfffcfaff),
      visualDensity: VisualDensity.compact,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xffede5ff),
        toolbarHeight: 52,
        titleTextStyle: TextStyle(
          fontSize: 18,
          color: Color(0xff332052),
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 12,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    builder: (context, child) => Stack(
      children: [
        if (!checking) child!,
        if (checking || locked)
          Positioned.fill(
            child: checking
                ? const Material(
                    child: Center(child: CircularProgressIndicator()),
                  )
                : PinGate(
                    store: widget.store,
                    onUnlock: () => setState(() => locked = false),
                  ),
          ),
      ],
    ),
    home: HomeScreen(store: widget.store),
  );
}

class PinGate extends StatefulWidget {
  final AppStore store;
  final VoidCallback onUnlock;
  const PinGate({super.key, required this.store, required this.onUnlock});
  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  final input = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> unlock() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (await widget.store.pin.verify(input.text)) {
        widget.onUnlock();
      } else {
        setState(() => error = 'Incorrect PIN');
      }
    } catch (e) {
      setState(
        () => error = e is FormatException
            ? e.message
            : 'Unable to unlock. Try again.',
      );
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          input.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: SafeArea(
      child: Center(
        child: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lock_outline,
                size: 36,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 16),
              const Text(
                'Daily Expenses',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: input,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(12),
                ],
                decoration: InputDecoration(labelText: 'PIN', errorText: error),
                onSubmitted: (_) {
                  if (!busy) unlock();
                },
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : unlock,
                child: Text(busy ? 'Checking…' : 'Unlock'),
              ),
              const Text(
                'Your PIN stays on this device.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
