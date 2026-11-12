import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
// `NotificationVisibility` existe en ambos paquetes: se oculta el de foreground_task.
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import '../core/app_constants.dart';
import '../models/trip_models.dart';
import 'offline_geocoder_service.dart';
import 'permission_service.dart';

// ═════════════════════════════════════════════════════════════════════════
//  ARQUITECTURA
//  ─ Isolate principal (UI): BackgroundTripService  → inicia/detiene el
//    servicio, recibe snapshots y peticiones "¿Qué hay aquí?".
//  ─ Isolate del servicio:   TripTaskHandler        → temporizador, lectura
//    GPS única, listener de señal y notificación con barra de progreso.
//  La notificación con progreso usa el MISMO id que el servicio foreground,
//  así reemplaza a la notificación base y solo hay una en pantalla.
// ═════════════════════════════════════════════════════════════════════════

/// Petición de abrir la exploración IA desde el botón "¿Qué hay aquí?".
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

/// Callback de botones de la notificación cuando la app NO está en primer plano.
/// Corre en un isolate aparte: reenvía la orden al isolate del servicio.
@pragma('vm:entry-point')
void rutaVivaNotificationBackground(NotificationResponse response) {
  final SendPort? port =
      IsolateNameServer.lookupPortByName(AppConstants.taskPortName);
  port?.send(jsonEncode({
    'cmd': response.actionId ?? 'tap',
    'payload': response.payload,
  }));
}

/// Punto de entrada del isolate del servicio.
@pragma('vm:entry-point')
void startTripCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(TripTaskHandler());
}

// ═════════════════════════════════════════════════════════════════════════
//  API PARA LA UI (isolate principal)
// ═════════════════════════════════════════════════════════════════════════

class BackgroundTripService {
  BackgroundTripService._();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  /// Última lectura recibida del servicio.
  static final ValueNotifier<TripSnapshot?> latestSnapshot = ValueNotifier(null);

  /// Último error del servicio (GPS apagado, sin permisos, etc.).
  static final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// ¿Hay un viaje en curso?
  static final ValueNotifier<bool> isRunning = ValueNotifier(false);

  /// La UI escucha esto para abrir la ficha IA del pueblo indicado.
  static final ValueNotifier<ExploreRequest?> exploreRequests =
      ValueNotifier(null);

  static bool _initialized = false;

  /// Llamar en `main()` antes de `runApp`.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _configureForeground(
      AppConstants.defaultIntervalMinutes,
      keepCpuAwake: false,
    );

    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings(AppConstants.notificationIcon),
      ),
      onDidReceiveNotificationResponse: _handleResponse,
      onDidReceiveBackgroundNotificationResponse: rutaVivaNotificationBackground,
    );

    // App abierta desde un botón/toque de la notificación estando cerrada.
    final launch = await _notifications.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if ((launch?.didNotificationLaunchApp ?? false) && response != null) {
      _handleResponse(response);
    }

    await refreshRunningState();
    final saved = await FlutterForegroundTask.getData<String>(
        key: AppConstants.keyTripSnapshot);
    latestSnapshot.value = TripSnapshot.tryDecode(saved);
  }

  static Future<bool> refreshRunningState() async {
    final running = await FlutterForegroundTask.isRunningService;
    isRunning.value = running;
    return running;
  }

  /// Último snapshot persistido por el servicio (útil al reabrir la app).
  static Future<TripSnapshot?> loadSavedSnapshot() async {
    final raw = await FlutterForegroundTask.getData<String>(
        key: AppConstants.keyTripSnapshot);
    return TripSnapshot.tryDecode(raw);
  }

  /// Configuración guardada del último viaje (si existe).
  static Future<TripConfig?> loadActiveConfig() async {
    final raw = await FlutterForegroundTask.getData<String>(
        key: AppConstants.keyTripConfig);
    if (raw == null) return null;
    try {
      return TripConfig.decode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Inicia (o reinicia con nueva configuración) el servicio de viaje.
  static Future<TripStartResult> startTrip(TripConfig config) async {
    if (!config.isValid) {
      return const TripStartResult.failure(
          'Origen y destino deben ser distintos.');
    }
    await initialize();

    final perms = await PermissionService.check();
    if (!perms.canRunTrip) {
      return TripStartResult.failure(
          'Faltan requisitos: ${perms.missingForTrip.join(', ')}.');
    }

    try {
      await FlutterForegroundTask.saveData(
          key: AppConstants.keyTripConfig, value: config.encode());
      await FlutterForegroundTask.removeData(
          key: AppConstants.keyTripSnapshot);
      latestSnapshot.value = null;
      lastError.value = null;

      // El intervalo se fija en init(): se reconfigura antes de cada inicio.
      _configureForeground(config.intervalMinutes,
          keepCpuAwake: config.keepCpuAwake);

      final running = await FlutterForegroundTask.isRunningService;
      final ServiceRequestResult result = running
          ? await FlutterForegroundTask.restartService()
          : await FlutterForegroundTask.startService(
              serviceId: AppConstants.serviceId,
              serviceTypes: [ForegroundServiceTypes.location],
              notificationTitle: '📍 RutaViva AI',
              notificationText: 'Obteniendo tu primera ubicación…',
              notificationInitialRoute: '/',
              callback: startTripCallback,
            );

      if (result is ServiceRequestFailure) {
        return TripStartResult.failure(
            'No se pudo iniciar el servicio: ${result.error}');
      }
      isRunning.value = true;
      return const TripStartResult.ok();
    } catch (e) {
      return TripStartResult.failure('Error al iniciar el viaje: $e');
    }
  }

  /// Detiene el servicio y limpia la notificación.
  static Future<void> stopTrip() async {
    try {
      await FlutterForegroundTask.stopService();
      await _notifications.cancel(AppConstants.serviceId);
    } finally {
      isRunning.value = false;
    }
  }

  /// Fuerza una lectura GPS inmediata en el servicio.
  static Future<bool> requestImmediateUpdate() async {
    if (!await FlutterForegroundTask.isRunningService) return false;
    FlutterForegroundTask.sendDataToTask(jsonEncode({'cmd': 'refresh'}));
    return true;
  }

  /// La UI llama a esto tras consumir una [ExploreRequest].
  static void consumeExploreRequest() => exploreRequests.value = null;

  // ── Internos ───────────────────────────────────────────────────────────

  static void _configureForeground(int intervalMinutes,
      {required bool keepCpuAwake}) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notificationChannelId,
        channelName: AppConstants.notificationChannelName,
        channelDescription: AppConstants.notificationChannelDescription,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction:
            ForegroundTaskEventAction.repeat(intervalMinutes * 60 * 1000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: keepCpuAwake,
        allowWifiLock: false,
      ),
    );
  }

  static void _onTaskData(Object data) {
    if (data is! String) return;
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      switch (map['type']) {
        case 'snapshot':
          latestSnapshot.value =
              TripSnapshot.fromJson(map['data'] as Map<String, dynamic>);
          lastError.value = null;
          isRunning.value = true;
        case 'error':
          lastError.value = map['message'] as String?;
        case 'stopped':
          isRunning.value = false;
      }
    } catch (e) {
      debugPrint('RutaViva: mensaje del servicio inválido: $e');
    }
  }

  /// Respuestas de la notificación con la app viva (o abierta por un botón).
  static void _handleResponse(NotificationResponse r) {
    switch (r.actionId) {
      case AppConstants.actionExplore:
        exploreRequests.value =
            ExploreRequest(townId: r.payload, at: DateTime.now());
      case AppConstants.actionRefresh:
        unawaited(requestImmediateUpdate());
      case AppConstants.actionStop:
        unawaited(stopTrip());
      default:
        break; // Toque en el cuerpo: simplemente abre la app.
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  HANDLER DEL SERVICIO (isolate en segundo plano)
// ═════════════════════════════════════════════════════════════════════════

class _Fix {
  const _Fix(this.position, {required this.stale});
  final Position position;
  final bool stale;
}

class TripTaskHandler extends TaskHandler {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  OfflineGeocoderService? _geocoder;
  TripConfig? _config;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  ReceivePort? _commandPort;

  bool _wasOffline = false;
  bool _busy = false;
  DateTime? _lastReadAt;
  TripSnapshot? _lastSnapshot;

  // ── Ciclo de vida ──────────────────────────────────────────────────────

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final raw = await FlutterForegroundTask.getData<String>(
          key: AppConstants.keyTripConfig);
      if (raw == null) {
        await FlutterForegroundTask.stopService();
        return;
      }
      _config = TripConfig.decode(raw);
      _geocoder = await OfflineGeocoderService.loadFromAssets();

      await _initNotifications();
      _registerCommandPort();
      await _listenConnectivity();
      await _readAndPublish(UpdateReason.start);
    } catch (e) {
      await _reportError('No se pudo iniciar el viaje: $e');
    }
  }

  /// Disparador temporal (intervalo elegido por el usuario).
  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_readAndPublish(UpdateReason.timer));
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    IsolateNameServer.removePortNameMapping(AppConstants.taskPortName);
    _commandPort?.close();
    _commandPort = null;
    try {
      await _notifications.cancel(AppConstants.serviceId);
    } catch (_) {}
    FlutterForegroundTask.sendDataToMain(jsonEncode({'type': 'stopped'}));
  }

  /// Mensajes desde la UI ("refresh").
  @override
  void onReceiveData(Object data) {
    if (data is! String) return;
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      unawaited(_handleCommand(map['cmd'] as String? ?? ''));
    } catch (_) {}
  }

  @override
  void onNotificationButtonPressed(String id) {
    unawaited(_handleCommand(id));
  }

  // ── Comandos ───────────────────────────────────────────────────────────

  Future<void> _handleCommand(String cmd) async {
    switch (cmd) {
      case 'refresh':
      case AppConstants.actionRefresh:
        await _readAndPublish(UpdateReason.manual);
      case 'stop':
      case AppConstants.actionStop:
        await FlutterForegroundTask.stopService();
    }
  }

  void _registerCommandPort() {
    IsolateNameServer.removePortNameMapping(AppConstants.taskPortName);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(
        port.sendPort, AppConstants.taskPortName);
    port.listen((message) {
      if (message is! String) return;
      try {
        final map = jsonDecode(message) as Map<String, dynamic>;
        unawaited(_handleCommand(map['cmd'] as String? ?? ''));
      } catch (_) {}
    });
    _commandPort = port;
  }

  // ── Disparador por retorno de señal ────────────────────────────────────

  Future<void> _listenConnectivity() async {
    final cfg = _config;
    if (cfg == null || !cfg.updateOnSignalReturn) return;

    final connectivity = Connectivity();
    try {
      final initial = await connectivity.checkConnectivity();
      _wasOffline = _isOffline(initial);
    } catch (_) {}

    _connectivitySub = connectivity.onConnectivityChanged.listen((results) {
      if (_isOffline(results)) {
        _wasOffline = true;
        return;
      }
      final regainedMobile = _wasOffline && results.contains(ConnectivityResult.mobile);
      _wasOffline = false;
      if (!regainedMobile) return;

      // Recuperar señal en carretera casi siempre = llegaste a un pueblo/caleta.
      final last = _lastReadAt;
      final enoughGap =
          last == null || DateTime.now().difference(last) >= AppConstants.minSignalGap;
      if (enoughGap) unawaited(_readAndPublish(UpdateReason.signalRegained));
    });
  }

  bool _isOffline(List<ConnectivityResult> r) =>
      r.isEmpty || r.every((e) => e == ConnectivityResult.none);

  // ── Lectura + análisis + publicación ───────────────────────────────────

  Future<void> _readAndPublish(UpdateReason reason) async {
    if (_busy) return;
    final cfg = _config;
    final geo = _geocoder;
    if (cfg == null || geo == null) return;

    if (reason == UpdateReason.timer &&
        _lastReadAt != null &&
        DateTime.now().difference(_lastReadAt!) < AppConstants.minTimerGap) {
      return;
    }

    _busy = true;
    try {
      final fix = await _acquireFix();
      if (fix == null) return; // el error ya fue reportado

      final progress = geo.analyze(
        latitude: fix.position.latitude,
        longitude: fix.position.longitude,
        config: cfg,
      );
      final snapshot = TripSnapshot(
        progress: progress,
        readAt: DateTime.now(),
        reason: reason,
        accuracyMeters: fix.position.accuracy,
        isStale: fix.stale,
      );
      _lastSnapshot = snapshot;
      _lastReadAt = snapshot.readAt;

      await FlutterForegroundTask.saveData(
          key: AppConstants.keyTripSnapshot, value: snapshot.encode());
      FlutterForegroundTask.sendDataToMain(
          jsonEncode({'type': 'snapshot', 'data': snapshot.toJson()}));

      await _showProgressNotification(snapshot);

      if (progress.arrived && reason != UpdateReason.start) {
        await _showArrivalNotification(progress);
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      await _reportError('Error al actualizar la ubicación: $e');
    } finally {
      _busy = false;
    }
  }

  /// Lectura ÚNICA de ubicación con precisión equilibrada (fused: torres + Wi-Fi
  /// + pulso corto de GPS). El sensor se apaga al devolver la coordenada.
  Future<_Fix?> _acquireFix() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await _reportError('GPS desactivado. Actívalo para seguir tu ruta.');
      return null;
    }
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      await _reportError('Sin permiso de ubicación. Revísalo en Ajustes.');
      return null;
    }

    try {
      // En geolocator, `medium` = PRIORITY_BALANCED_POWER_ACCURACY en Android.
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
      await _reportError('Sin señal GPS. Reintentaremos en el próximo ciclo.');
      return null;
    } on LocationServiceDisabledException {
      await _reportError('GPS desactivado. Actívalo para seguir tu ruta.');
      return null;
    }
  }

  // ── Notificaciones ─────────────────────────────────────────────────────

  Future<void> _initNotifications() async {
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings(AppConstants.notificationIcon),
      ),
      onDidReceiveBackgroundNotificationResponse: rutaVivaNotificationBackground,
    );
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      AppConstants.notificationChannelId,
      AppConstants.notificationChannelName,
      description: AppConstants.notificationChannelDescription,
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      AppConstants.arrivalChannelId,
      AppConstants.arrivalChannelName,
      importance: Importance.defaultImportance,
    ));
  }

  String _fmtKm(double? km) {
    if (km == null) return '–';
    return km >= 10 ? km.round().toString() : km.toStringAsFixed(1);
  }

  Future<void> _showProgressNotification(TripSnapshot s,
      {String? warning}) async {
    final p = s.progress;
    final title = '📍 Pasando por: ${p.currentTownName}, ${p.currentDepartment}';
    final next = p.nextTownName != null
        ? ' • Próx: ${p.nextTownName} (${_fmtKm(p.nextTownDistanceKm)} km)'
        : ' • Destino a la vista';
    final base =
        'Ruta ${p.originName} ➔ ${p.destinationName} • ${p.percent}% completado$next';
    final body = warning != null ? '⚠ $warning\n$base' : base;

    final hh = s.readAt.hour.toString().padLeft(2, '0');
    final mm = s.readAt.minute.toString().padLeft(2, '0');
    final summary =
        'Lectura $hh:$mm · ${s.reason.label}${s.isStale ? ' · última posición conocida' : ''}';

    final details = AndroidNotificationDetails(
      AppConstants.notificationChannelId,
      AppConstants.notificationChannelName,
      channelDescription: AppConstants.notificationChannelDescription,
      icon: AppConstants.notificationIcon,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      playSound: false,
      enableVibration: false,
      channelShowBadge: false,
      showWhen: false,
      category: AndroidNotificationCategory.service,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF00E5A0),
      // Barra de progreso nativa: avanza como la línea de tiempo de una canción.
      showProgress: true,
      maxProgress: 100,
      progress: p.percent,
      indeterminate: false,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: summary,
      ),
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          AppConstants.actionExplore,
          '🔍 ¿Qué hay aquí?',
          showsUserInterface: true,
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          AppConstants.actionRefresh,
          '🔄 Actualizar ahora',
          showsUserInterface: false,
          cancelNotification: false,
        ),
        AndroidNotificationAction(
          AppConstants.actionStop,
          '⏹️ Finalizar ruta',
          showsUserInterface: false,
          cancelNotification: false,
        ),
      ],
    );

    try {
      // Mismo id que el servicio foreground → reemplaza su notificación base.
      await _notifications.show(
        AppConstants.serviceId,
        title,
        body,
        NotificationDetails(android: details),
        payload: p.currentTownId,
      );
    } catch (_) {
      // Respaldo: actualizar la notificación del propio servicio (sin barra nativa).
      final bar = _textBar(p.percent);
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: '$bar ${p.percent}% · $base',
      );
    }
  }

  String _textBar(int percent) {
    const total = 10;
    final filled = (percent / 100 * total).round().clamp(0, total);
    return '▓' * filled + '░' * (total - filled);
  }

  Future<void> _showArrivalNotification(TripProgress p) async {
    await _notifications.show(
      AppConstants.arrivalNotificationId,
      '🏁 ¡Llegaste a ${p.destinationName}!',
      'Ruta ${p.originName} ➔ ${p.destinationName} completada (${p.kmTotal.round()} km).',
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
  }

  Future<void> _reportError(String message) async {
    FlutterForegroundTask.sendDataToMain(
        jsonEncode({'type': 'error', 'message': message}));
    try {
      final last = _lastSnapshot;
      if (last != null) {
        await _showProgressNotification(last, warning: message);
      } else {
        await FlutterForegroundTask.updateService(
          notificationTitle: '📍 RutaViva AI',
          notificationText: '⚠ $message',
        );
      }
    } catch (_) {}
  }
}
