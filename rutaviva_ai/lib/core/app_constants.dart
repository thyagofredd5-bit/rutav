/// Constantes globales de RutaViva AI.
class AppConstants {
  AppConstants._();

  static const String appName = 'RutaViva AI';
  static const String routeAsset = 'assets/data/rutas_peru.json';

  // ── Servicio / notificación ────────────────────────────────────────────
  /// El mismo ID se usa para el servicio foreground y para la notificación con
  /// barra de progreso, de modo que solo exista UNA notificación en pantalla.
  static const int serviceId = 7001;
  static const int arrivalNotificationId = 7002;
  static const String notificationChannelId = 'rutaviva_trip_channel';
  static const String notificationChannelName = 'RutaViva · Viaje en curso';
  static const String notificationChannelDescription =
      'Progreso silencioso de tu ruta: pueblo actual, porcentaje y próxima parada.';
  static const String arrivalChannelId = 'rutaviva_arrival_channel';
  static const String arrivalChannelName = 'RutaViva · Llegada';
  static const String notificationIcon = 'ic_stat_route';

  /// Nombre del puerto (IsolateNameServer) que recibe los botones de la notificación.
  static const String taskPortName = 'rutaviva_task_command_port';

  // Identificadores de botones de la notificación
  static const String actionExplore = 'rv_action_explore';
  static const String actionRefresh = 'rv_action_refresh';
  static const String actionStop = 'rv_action_stop';

  // ── Persistencia ───────────────────────────────────────────────────────
  // Claves de FlutterForegroundTask.saveData (compartidas entre isolates).
  static const String keyTripConfig = 'rv_trip_config';
  static const String keyTripSnapshot = 'rv_trip_snapshot';
  // Claves de SharedPreferences (solo isolate principal).
  static const String prefsSettings = 'rv_app_settings_v1';
  static const String prefsTripDefaults = 'rv_trip_defaults_v1';
  static const String prefsGuideCachePrefix = 'rv_guide_cache_v1_';

  // ── Lógica de viaje ────────────────────────────────────────────────────
  static const List<int> intervalOptionsMinutes = [15, 30, 45, 60];
  static const int defaultIntervalMinutes = 30;
  static const double defaultDetectionRadiusKm = 15.0;
  /// Mínimo entre lecturas para que "recuperar señal" dispare una actualización.
  static const Duration minSignalGap = Duration(minutes: 5);
  /// Evita doble lectura si el temporizador dispara justo después del inicio.
  static const Duration minTimerGap = Duration(seconds: 90);
  static const Duration gpsTimeLimit = Duration(seconds: 40);

  // ── IA y caché ─────────────────────────────────────────────────────────
  static const Duration guideCacheTtl = Duration(days: 90);
  static const Duration httpTimeout = Duration(seconds: 20);
  static const Duration llmTimeout = Duration(seconds: 60);

  /// Wikimedia exige un User-Agent identificable con contacto. Cámbialo por el tuyo.
  static const String httpUserAgent =
      'RutaVivaAI/1.0 (Android; app de viaje; contacto: rutaviva-app@example.com)';
}
