import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

final app = AppState();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: CS.negro,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const CsMixApp());
  app.init();
}

class CsMixApp extends StatelessWidget {
  const CsMixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CS Mix',
      debugShowCheckedModeBanner: false,
      theme: CS.theme(),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          if (!app.ready) return const _Splash();
          if (app.startupError != null) return _StartupError(app.startupError!);
          return const HomeScreen();
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Image.asset('assets/logo.png', width: 160, height: 160, semanticLabel: 'Logo CS Mix'),
          ),
          const SizedBox(height: 24),
          Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: CS.rojo, width: 4))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CS MIX', style: CS.cond(40)),
              Text('Catelotti Sport', style: CS.body(14, color: CS.humo)),
            ],
          ),
        ),
        ]),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError(this.error);
  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LA APP NO PUDO ARRANCAR', style: CS.cond(26)),
              const SizedBox(height: 12),
              SelectableText(error, style: CS.body(14, color: CS.humo)),
            ],
          ),
        ),
      ),
    );
  }
}
