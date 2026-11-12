import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_town_guide.dart';
import '../models/app_settings.dart';
import '../models/town_model.dart';
import '../models/trip_models.dart';
import '../services/ai_explorer_service.dart';
import '../services/background_trip_service.dart';
import '../services/offline_geocoder_service.dart';
import '../services/permission_service.dart';
import '../services/photo_fetcher_service.dart';

/// Se sobreescribe en `main()` con el controlador ya inicializado.
final tripProvider = ChangeNotifierProvider<TripController>(
  (ref) => throw UnimplementedError('tripProvider se sobreescribe en main()'),
);

/// Estado reactivo central: permisos, configuración del viaje, lecturas del
/// servicio en segundo plano, ajustes y fichas IA por pueblo.
class TripController extends ChangeNotifier with WidgetsBindingObserver {
  TripController({
    required this.prefs,
    required this.geocoder,
    required this.settingsRepo,
    required this.ai,
  });

  final SharedPreferences prefs;
  final OfflineGeocoderService geocoder;
  final SettingsRepository settingsRepo;
  final AiExplorerService ai;

  AppSettings settings = const AppSettings();
  TripConfig config = TripConfig.limaToArequipa;
  PermissionSnapshot? permissions;
  bool permissionsBusy = false;
  bool starting = false;

  bool _disposed = false;
  final Map<String, TownGuideState> _guides = {};
  final Map<String, StreamSubscription<TownGuideState>> _subs = {};

  // ── Construcción ───────────────────────────────────────────────────────

  static Future<TripController> create() async {
    final prefs = await SharedPreferences.getInstance();
    final geocoder = await OfflineGeocoderService.loadFromAssets();
    final controller = TripController(
      prefs: prefs,
      geocoder: geocoder,
      settingsRepo: SettingsRepository(prefs),
      ai: AiExplorerService(prefs: prefs, photoFetcher: PhotoFetcherService()),
    );
    await controller.init();
    return controller;
  }

  Future<void> init() async {
    settings = settingsRepo.load();
    final isRunning = await BackgroundTripService.refreshRunningState();
    final active = isRunning ? await BackgroundTripService.loadActiveConfig() : null;
    var cfg = active ?? settingsRepo.loadTripDefaults();
    if (geocoder.byId(cfg.originId) == null ||
        geocoder.byId(cfg.destinationId) == null ||
        !cfg.isValid) {
      cfg = TripConfig.limaToArequipa;
    }
    config = cfg;
    try {
      permissions = await PermissionService.check();
    } catch (_) {}

    BackgroundTripService.latestSnapshot.addListener(_onBackground);
    BackgroundTripService.lastError.addListener(_onBackground);
    BackgroundTripService.isRunning.addListener(_onBackground);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onBackground() => notifyListeners();

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_resync());
    }
  }

  Future<void> _resync() async {
    await BackgroundTripService.refreshRunningState();
    final saved = await BackgroundTripService.loadSavedSnapshot();
    final cur = BackgroundTripService.latestSnapshot.value;
    if (saved != null && (cur == null || saved.readAt.isAfter(cur.readAt))) {
      BackgroundTripService.latestSnapshot.value = saved;
    }
    await refreshPermissions();
  }

  // ── Lecturas derivadas ─────────────────────────────────────────────────

  bool get running => BackgroundTripService.isRunning.value;
  String? get serviceError => BackgroundTripService.lastError.value;
  bool get isForward => config.originId == TripConfig.limaToArequipa.originId;

  TownModel get originTown => geocoder.requireById(config.originId);
  TownModel get destinationTown => geocoder.requireById(config.destinationId);
  String get routeLabel =>
      '${originTown.nombreLugar} ➔ ${destinationTown.nombreLugar}';

  /// Última lectura, solo si pertenece a la ruta/sentido actualmente elegidos.
  TripSnapshot? get snapshot {
    final s = BackgroundTripService.latestSnapshot.value;
    if (s == null) return null;
    final o = geocoder.byId(config.originId);
    final d = geocoder.byId(config.destinationId);
    if (o == null || d == null) return null;
    if (s.progress.originName != o.nombreLugar ||
        s.progress.destinationName != d.nombreLugar) {
      return null;
    }
    return s;
  }

  TownModel get currentTown {
    final id = snapshot?.progress.currentTownId;
    return (id != null ? geocoder.byId(id) : null) ?? originTown;
  }

  TownModel? get nextTown {
    final id = snapshot?.progress.nextTownId;
    if (id != null) return geocoder.byId(id);
    for (final stop in timeline) {
      if (stop.status == TownStatus.upcoming && stop.town.enRutaPrincipal) {
        return stop.town;
      }
    }
    return null;
  }

  List<RouteStop> get timeline =>
      geocoder.buildTimeline(config, progress: snapshot?.progress);

  String _tripContext() {
    final p = snapshot?.progress;
    final base = 'Viaje en bus $routeLabel';
    return p == null ? base : '$base; voy aproximadamente en el km ${p.routeKm.round()}';
  }

  // ── Viaje ──────────────────────────────────────────────────────────────

  /// Inicia o detiene el seguimiento. Devuelve un mensaje si falló.
  Future<String?> toggleTrip() async {
    if (starting) return null;
    starting = true;
    notifyListeners();
    try {
      if (running) {
        await BackgroundTripService.stopTrip();
        return null;
      }
      await settingsRepo.saveTripDefaults(config);
      final result = await BackgroundTripService.startTrip(config);
      return result.success ? null : result.message;
    } finally {
      starting = false;
      await refreshPermissions();
    }
  }

  /// Cambia sentido/intervalo/señal; si hay viaje activo lo reinicia.
  Future<String?> updateConfig(TripConfig next) async {
    if (!next.isValid) return 'Configuración de viaje inválida.';
    config = next;
    await settingsRepo.saveTripDefaults(next);
    notifyListeners();
    if (running) {
      final result = await BackgroundTripService.startTrip(next);
      notifyListeners();
      return result.success ? null : result.message;
    }
    return null;
  }

  Future<String?> refreshNow() async {
    final ok = await BackgroundTripService.requestImmediateUpdate();
    return ok ? null : 'Inicia el seguimiento para actualizar tu ubicación.';
  }

  // ── Permisos ───────────────────────────────────────────────────────────

  Future<void> refreshPermissions() async {
    try {
      permissions = await PermissionService.check();
    } catch (_) {}
    notifyListeners();
  }

  /// Pide en cadena todo lo necesario con un solo toque.
  Future<void> grantAllPermissions() async {
    if (permissionsBusy) return;
    permissionsBusy = true;
    notifyListeners();
    try {
      await PermissionService.requestAllForTrip();
      var p = await PermissionService.check();
      if (!p.gpsEnabled) {
        await PermissionService.openLocationSettings();
      } else if (!p.locationWhileInUse || !p.notifications) {
        final locBlocked = await PermissionService.isLocationPermanentlyDenied();
        final notiBlocked =
            await PermissionService.isNotificationPermanentlyDenied();
        if (locBlocked || notiBlocked) await PermissionService.openAppSettings();
      } else {
        if (!p.locationAlways) await PermissionService.requestLocationAlways();
        p = await PermissionService.check();
        if (!p.batteryOptimizationIgnored) {
          await PermissionService.requestIgnoreBatteryOptimizations();
        }
      }
    } finally {
      permissionsBusy = false;
      await refreshPermissions();
    }
  }

  Future<void> grantLocationAlways() async {
    final ok = await PermissionService.requestLocationAlways();
    if (!ok) await PermissionService.openAppSettings();
    await refreshPermissions();
  }

  Future<void> grantNotifications() async {
    final ok = await PermissionService.requestNotifications();
    if (!ok && await PermissionService.isNotificationPermanentlyDenied()) {
      await PermissionService.openAppSettings();
    }
    await refreshPermissions();
  }

  Future<void> grantBatteryIgnore() async {
    await PermissionService.requestIgnoreBatteryOptimizations();
    await refreshPermissions();
  }

  Future<void> openGpsSettings() async {
    await PermissionService.openLocationSettings();
    await refreshPermissions();
  }

  Future<void> openAppPermissionSettings() => PermissionService.openAppSettings();

  // ── Ajustes y caché ────────────────────────────────────────────────────

  Future<void> saveSettings(AppSettings next) async {
    settings = next;
    await settingsRepo.save(next);
    notifyListeners();
  }

  Future<LlmTestResult> testLlm(AppSettings candidate) =>
      ai.testLlmConnection(candidate);

  Future<LlmTestResult> testPlaces(String key) => ai.testPlacesKey(key);

  int get cachedTownCount => ai.cachedTownCount;

  Future<void> clearGuideCache() async {
    for (final s in _subs.values) {
      await s.cancel();
    }
    _subs.clear();
    await ai.clearCache();
    _guides.clear();
    notifyListeners();
  }

  // ── Fichas IA por pueblo ───────────────────────────────────────────────

  TownGuideState guideFor(String townId) =>
      _guides[townId] ?? TownGuideState.initial(townId);

  /// Lee la caché local; solo llama a la IA/red si no hay ficha o se fuerza.
  void loadGuide(TownModel town, {bool forceRefresh = false}) {
    final prev = _guides[town.id];
    if (prev != null && prev.isBusy) return;
    if (!forceRefresh && prev != null && prev.hasGuide && !prev.hasError) return;

    _subs.remove(town.id)?.cancel();
    _guides[town.id] = (prev ?? TownGuideState.initial(town.id))
        .copyWith(loadingGuide: true, clearError: true);
    notifyListeners();

    _subs[town.id] = ai
        .loadTownGuide(
          town,
          settings: settings,
          tripContext: _tripContext(),
          forceRefresh: forceRefresh,
        )
        .listen(
      (s) {
        _guides[town.id] = _merge(_guides[town.id], s);
        notifyListeners();
      },
      onDone: () => _subs.remove(town.id),
    );
  }

  /// Si un refresco falla, conserva la ficha anterior en pantalla.
  TownGuideState _merge(TownGuideState? prev, TownGuideState s) {
    if (s.guide != null || prev == null || prev.guide == null) return s;
    return prev.copyWith(
      photos: s.photos.isNotEmpty ? s.photos : prev.photos,
      places: s.places.isNotEmpty ? s.places : prev.places,
      loadingGuide: s.loadingGuide,
      loadingPhotos: s.loadingPhotos,
      loadingPlaces: s.loadingPlaces,
      fromCache: s.fromCache,
      errorKind: s.errorKind,
      errorMessage: s.errorMessage,
      placesError: s.placesError,
      clearError: !s.hasError,
      clearPlacesError: s.placesError == null,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    BackgroundTripService.latestSnapshot.removeListener(_onBackground);
    BackgroundTripService.lastError.removeListener(_onBackground);
    BackgroundTripService.isRunning.removeListener(_onBackground);
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    ai.dispose();
    super.dispose();
  }
}
