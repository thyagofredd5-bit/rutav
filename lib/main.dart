import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_constants.dart';
import 'core/app_theme.dart';
import 'providers/trip_provider.dart';
import 'screens/home_trip_screen.dart';
import 'services/background_trip_service.dart';
import 'services/trip_media_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  try {
    // Reproductor multimedia (MediaSession) = único servicio en primer plano.
    final media = await initTripMediaHandler();
    await BackgroundTripService.initialize();
    final controller = await TripController.create(media: media);
    runApp(ProviderScope(
      overrides: [tripProvider.overrideWith((ref) => controller)],
      child: const RutaVivaApp(),
    ));
  } catch (e, st) {
    debugPrint('RutaViva: error de arranque: $e\n$st');
    runApp(_StartupError(message: e.toString()));
  }
}

class RutaVivaApp extends StatelessWidget {
  const RutaVivaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const HomeTripScreen(),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.danger, size: 48),
                const SizedBox(height: 16),
                const Text('No se pudo iniciar RutaViva AI',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
