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
  // Claves de SharedPreferences del viaje activo.
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

  /// Modelo Gemini por defecto y cascada de respaldo (se usa si hay HTTP 404/400).
  static const String defaultGeminiModel = 'gemini-3.8-flash';
  static const List<String> geminiFallbackModels = [
    'gemini-3.8-flash',
    'gemini-3.0-flash',
    'gemini-3-flash-preview',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
  ];

  // ── V3: reproductor multimedia, ruteo y precarga ───────────────────────
  static const String mediaChannelId = 'rutaviva_media_channel';
  static const String mediaChannelName = 'RutaViva · Reproductor de viaje';
  static const String keyActiveRoute = 'rv_active_route';
  static const String nominatimHost = 'nominatim.openstreetmap.org';
  static const String osrmHost = 'router.project-osrm.org';
  /// Distancia por delante de la posición para anticipar el próximo pueblo.
  static const double placeAheadKm = 20.0;
  /// Radio para resolver el lugar actual con el JSON offline antes de Nominatim.
  static const double offlinePlaceRadiusKm = 4.0;
  /// Tiempo máximo de cada fuente de fotos (Wikipedia es/en y Commons en paralelo).
  static const Duration photoSourceTimeout = Duration(milliseconds: 2500);

  /// Wikimedia exige un User-Agent identificable con contacto. Cámbialo por el tuyo.
  static const String httpUserAgent =
      'RutaVivaAI/1.0 (Android; app de viaje; contacto: rutaviva-app@example.com)';
}
