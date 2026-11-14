import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_constants.dart';
import '../models/geo_models.dart';
import '../models/trip_models.dart';
import 'offline_geocoder_service.dart';
import 'permission_service.dart';
import 'routing_service.dart';

// ═════════════════════════════════════════════════════════════════════════
//  ARQUITECTURA V3 (una sola notificación)
//  Todo corre en el isolate principal, que permanece vivo mientras el
//  reproductor multimedia (audio_service, tipo mediaPlayback|location) esté
//  activo. Este "motor" lee el GPS (lectura única por ciclo), analiza el
//  progreso y publica snapshots; TripController los convierte en MediaItem.
//  Ya no existe flutter_foreground_task ni una segunda notificación.
// ═════════════════════════════════════════════════════════════════════════

/// Petición de abrir la exploración IA del lugar indicado.
class ExploreRequest {
  const ExploreRequest({required this.townId, required this.at});
  final String? townId;
  final DateTime at;
}

/// Resultado de intentar iniciar el viaje.
class TripStartResult {
  const TripStartResult.ok()
      : success = true,
        message = null;
  const TripStartResult.failure(this.message) : success = false;
  final bool success;
  final String? message;
}

class _Fix {
  const _Fix(this.position, {required this.stale});
  final Position position;
  final bool stale;
}

class BackgroundTripService {
  BackgroundTripService._();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  /// Última lectura publicada.
  static final ValueNotifier<TripSnapshot?> latestSnapshot = ValueNotifier(null);

  /// Último error (GPS apagado, sin permisos, etc.).
  static final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// ¿Hay un viaje en curso?
  static final ValueNotifier<bool> isRunning = ValueNotifier(false);

  /// ¿Lecturas pausadas?
  static final ValueNotifier<bool> isPaused = ValueNotifier(false);

  /// La UI escucha esto para abrir la ficha IA del lugar indicado.
  static final ValueNotifier<ExploreRequest?> exploreRequests =
      ValueNotifier(null);

  static bool _initialized = false;
  static OfflineGeocoderService? _geocoder;
  static PlaceResolver? _resolver;
  static TripConfig? _config;
  static RouteTracker? _tracker;
  static Timer? _timer;
  static StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  static bool _wasOffline = false;
  static bool _busy = false;
  static DateTime? _lastReadAt;
  static int _lastSegment = 0;

  /// Llamar en `main()` antes de `runApp`.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _notifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings(AppConstants.notificationIcon),
        ),
      );
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        AppConstants.arrivalChannelId,
        AppConstants.arrivalChannelName,
        importance: Importance.defaultImportance,
      ));
    } catch (e) {
      debugPrint('RutaViva: notificaciones no disponibles: $e');
    }
    latestSnapshot.value = await loadSavedSnapshot();
  }

  static Future<bool> refreshRunningState() async => isRunning.value;

  static Future<TripSnapshot?> loadSavedSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    return TripSnapshot.tryDecode(prefs.getString(AppConstants.keyTripSnapshot));
  }

  static Future<TripConfig?> loadActiveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppConstants.keyTripConfig);
    if (raw == null) return null;
    try {
      return TripConfig.decode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Inicia (o reinicia) el seguimiento. En modo `custom` exige [plan].
  static Future<TripStartResult> startTrip(TripConfig config,
      {RoutePlan? plan}) async {
    if (!config.isValid) {
      return const TripStartResult.failure('Configuración de viaje inválida.');
    }
    if (config.mode == TripMode.custom && plan == null) {
      return const TripStartResult.failure('Falta calcular la ruta al destino.');
    }
    await initialize();

    final perms = await PermissionService.check();
    if (!perms.canRunTrip) {
      return TripStartResult.failure(
          'Faltan requisitos: ${perms.missingForTrip.join(', ')}.');
    }

    try {
      _stopEngine();
      _geocoder ??= await OfflineGeocoderService.loadFromAssets();
      _resolver ??= PlaceResolver(geocoder: _geocoder!);
      _config = config;
      _tracker = plan != null ? RouteTracker(plan) : null;
      _lastSegment = 0;
      _lastReadAt = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyTripConfig, config.encode());
      await prefs.remove(AppConstants.keyTripSnapshot);
      if (plan != null) {
        await prefs.setString(AppConstants.keyActiveRoute, plan.encode());
      } else {
        await prefs.remove(AppConstants.keyActiveRoute);
      }

      latestSnapshot.value = null;
      lastError.value = null;
      isPaused.value = false;
      isRunning.value = true;

      _timer = Timer.periodic(Duration(minutes: config.intervalMinutes),
          (_) => unawaited(_readAndPublish(UpdateReason.timer)));
      await _listenConnectivity(config);
      unawaited(_readAndPublish(UpdateReason.start));
      return const TripStartResult.ok();
    } catch (e) {
      _stopEngine();
      isRunning.value = false;
      return TripStartResult.failure('Error al iniciar el viaje: $e');
    }
  }

  static Future<void> stopTrip() async {
    _stopEngine();
    isPaused.value = false;
    isRunning.value = false;
  }

  /// Suspende las lecturas automáticas.
  static void pauseTracking() {
    if (!isRunning.value) return;
    isPaused.value = true;
  }

  /// Reanuda y lee la ubicación al instante.
  static void resumeTracking() {
    if (!isRunning.value) return;
    isPaused.value = false;
    unawaited(_readAndPublish(UpdateReason.manual));
  }

  /// Lectura inmediata (botón de sincronización / "Actualizar ahora").
  static Future<bool> requestImmediateUpdate() async {
    if (!isRunning.value) return false;
    unawaited(_readAndPublish(UpdateReason.manual));
    return true;
  }

  static void consumeExploreRequest() => exploreRequests.value = null;

  // ── Internos ───────────────────────────────────────────────────────────

  static void _stopEngine() {
    _timer?.cancel();
    _timer = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  static bool _isOffline(List<ConnectivityResult> r) =>
      r.isEmpty || r.every((e) => e == ConnectivityResult.none);

  static Future<void> _listenConnectivity(TripConfig cfg) async {
    if (!cfg.updateOnSignalReturn) return;
    final connectivity = Connectivity();
    try {
      _wasOffline = _isOffline(await connectivity.checkConnectivity());
    } catch (_) {}
    _connectivitySub = connectivity.onConnectivityChanged.listen((results) {
      if (_isOffline(results)) {
        _wasOffline = true;
        return;
      }
      final regainedMobile =
          _wasOffline && results.contains(ConnectivityResult.mobile);
      _wasOffline = false;
      if (!regainedMobile) return;
      final last = _lastReadAt;
      final enoughGap = last == null ||
          DateTime.now().difference(last) >= AppConstants.minSignalGap;
      if (enoughGap) unawaited(_readAndPublish(UpdateReason.signalRegained));
    });
  }

  static Future<void> _readAndPublish(UpdateReason reason) async {
    if (_busy || !isRunning.value) return;
    final cfg = _config;
    final geo = _geocoder;
    final resolver = _resolver;
    if (cfg == null || geo == null || resolver == null) return;

    final automatic =
        reason == UpdateReason.timer || reason == UpdateReason.signalRegained;
    if (automatic && isPaused.value) return;
    if (reason == UpdateReason.timer &&
        _lastReadAt != null &&
        DateTime.now().difference(_lastReadAt!) < AppConstants.minTimerGap) {
      return;
    }

    _busy = true;
    try {
      final fix = await _acquireFix();
      if (fix == null) return;
      final pos = fix.position;

      final TripProgress progress;
      switch (cfg.mode) {
        case TripMode.corridor:
          progress = geo.analyze(
              latitude: pos.latitude, longitude: pos.longitude, config: cfg);
        case TripMode.custom:
          progress = await _analyzeCustom(pos, resolver);
        case TripMode.free:
          progress = await _analyzeFree(pos, resolver);
      }

      final snapshot = TripSnapshot(
        progress: progress,
        readAt: DateTime.now(),
        reason: reason,
        accuracyMeters: pos.accuracy,
        isStale: fix.stale,
      );
      _lastReadAt = snapshot.readAt;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyTripSnapshot, snapshot.encode());
      if (!isRunning.value) return; // se detuvo mientras se leía
      lastError.value = null;
      latestSnapshot.value = snapshot;

      if (progress.arrived && reason != UpdateReason.start) {
        await _showArrivalNotification(progress);
        await stopTrip();
      }
    } catch (e) {
      lastError.value = 'Error al actualizar la ubicación: $e';
    } finally {
      _busy = false;
    }
  }

  static Future<TripProgress> _analyzeCustom(
      Position pos, PlaceResolver resolver) async {
    final tracker = _tracker!;
    final plan = tracker.plan;
    final m = tracker.match(pos.latitude, pos.longitude,
        fromSegment: math.max(0, _lastSegment - 3));
    _lastSegment = m.segment;
    final total = plan.totalKm;
    final along = m.alongKm.clamp(0.0, total).toDouble();
    final fraction = total <= 0 ? 0.0 : (along / total).clamp(0.0, 1.0).toDouble();
    final arrived = total - along <= 2.0 && fraction > 0.5;

    final place = await resolver.resolve(pos.latitude, pos.longitude,
        altitudeM: pos.altitude > 0 ? pos.altitude : null);
    AheadPlace? ahead;
    if (!arrived) {
      ahead = await resolver.placeAhead(tracker, along, currentName: place.name);
    }
    return TripProgress(
      latitude: pos.latitude,
      longitude: pos.longitude,
      originName: plan.origin.name,
      destinationName: plan.destination.name,
      currentTownId: place.id,
      currentTownName: place.name,
      currentDepartment: place.department,
      atTown: true,
      distanceToCurrentTownKm: 0,
      progress: fraction,
      kmTraveled: along,
      kmTotal: total,
      routeKm: along,
      offRouteKm: m.offRouteKm,
      arrived: arrived,
      direction: 1,
      computeMicros: 0,
      nextTownId: ahead?.place.id,
      nextTownName: ahead?.place.name,
      nextTownDistanceKm: ahead?.distanceKm,
      mode: TripMode.custom,
      place: place,
      nextPlace: ahead?.place,
    );
  }

  static Future<TripProgress> _analyzeFree(
      Position pos, PlaceResolver resolver) async {
    final place = await resolver.resolve(pos.latitude, pos.longitude,
        altitudeM: pos.altitude > 0 ? pos.altitude : null);
    return TripProgress(
      latitude: pos.latitude,
      longitude: pos.longitude,
      originName: place.name,
      destinationName: '',
      currentTownId: place.id,
      currentTownName: place.name,
      currentDepartment: place.department,
      atTown: true,
      distanceToCurrentTownKm: 0,
      progress: 0,
      kmTraveled: 0,
      kmTotal: 0,
      routeKm: 0,
      offRouteKm: 0,
      arrived: false,
      direction: 1,
      computeMicros: 0,
      mode: TripMode.free,
      place: place,
    );
  }

  /// Lectura ÚNICA de ubicación con precisión equilibrada.
  static Future<_Fix?> _acquireFix() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      lastError.value = 'GPS desactivado. Actívalo para seguir tu ruta.';
      return null;
    }
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      lastError.value = 'Sin permiso de ubicación. Revísalo en Ajustes.';
      return null;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 0,
          forceLocationManager: false,
          timeLimit: AppConstants.gpsTimeLimit,
        ),
      );
      return _Fix(pos, stale: false);
    } on TimeoutException {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return _Fix(last, stale: true);
      lastError.value = 'Sin señal GPS. Reintentaremos en el próximo ciclo.';
      return null;
    } on LocationServiceDisabledException {
      lastError.value = 'GPS desactivado. Actívalo para seguir tu ruta.';
      return null;
    }
  }

  static Future<void> _showArrivalNotification(TripProgress p) async {
    try {
      final dest = p.destinationName.isEmpty ? 'tu destino' : p.destinationName;
      await _notifications.show(
        AppConstants.arrivalNotificationId,
        'Llegaste a $dest',
        'Ruta a $dest completada (${p.kmTotal.round()} km).',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            AppConstants.arrivalChannelId,
            AppConstants.arrivalChannelName,
            icon: AppConstants.notificationIcon,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
    } catch (_) {}
  }
}
