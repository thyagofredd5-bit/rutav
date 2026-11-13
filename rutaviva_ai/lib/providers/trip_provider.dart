import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_town_guide.dart';
import '../models/app_settings.dart';
import '../models/geo_models.dart';
import '../models/town_model.dart';
import '../models/trip_models.dart';
import '../services/ai_explorer_service.dart';
import '../services/background_trip_service.dart';
import '../services/offline_geocoder_service.dart';
import '../services/permission_service.dart';
import '../services/photo_fetcher_service.dart';
import '../services/routing_service.dart';
import '../services/trip_media_handler.dart';

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
    required this.media,
  });

  final SharedPreferences prefs;
  final OfflineGeocoderService geocoder;
  final SettingsRepository settingsRepo;
  final AiExplorerService ai;
  final TripMediaHandler media;

  /// Búsqueda de destinos (Nominatim) y ruteo (OSRM).
  late final NominatimService nominatim = NominatimService();
  late final PlaceResolver _resolver =
      PlaceResolver(geocoder: geocoder, nominatim: nominatim);
  final OsrmService _osrm = OsrmService();

  /// Ruta por carretera del viaje a destino libre en curso.
  RoutePlan? plannedRoute;
  bool planning = false;
  final Set<String> _prefetched = {};

  AppSettings settings = const AppSettings();
  TripConfig config = TripConfig.limaToArequipa;
  PermissionSnapshot? permissions;
  bool permissionsBusy = false;
  bool starting = false;

  bool _disposed = false;
  final Map<String, TownGuideState> _guides = {};
  final Map<String, StreamSubscription<TownGuideState>> _subs = {};

  // ── Construcción ───────────────────────────────────────────────────────

  static Future<TripController> create({required TripMediaHandler media}) async {
    final prefs = await SharedPreferences.getInstance();
    final geocoder = await OfflineGeocoderService.loadFromAssets();
    final controller = TripController(
      prefs: prefs,
      geocoder: geocoder,
      settingsRepo: SettingsRepository(prefs),
      ai: AiExplorerService(prefs: prefs, photoFetcher: PhotoFetcherService()),
      media: media,
    );
    await controller.init();
    return controller;
  }

  Future<void> init() async {
    settings = settingsRepo.load();
    final isRunning = await BackgroundTripService.refreshRunningState();
    final active = isRunning ? await BackgroundTripService.loadActiveConfig() : null;
    var cfg = active ?? settingsRepo.loadTripDefaults();
    final corridorOk = geocoder.byId(cfg.originId) != null &&
        geocoder.byId(cfg.destinationId) != null;
    if (cfg.mode == TripMode.corridor && (!corridorOk || !cfg.isValid)) {
      cfg = TripConfig.limaToArequipa;
    } else if (cfg.mode == TripMode.free) {
      cfg = TripConfig.free.copyWith(
          intervalMinutes: cfg.intervalMinutes,
          updateOnSignalReturn: cfg.updateOnSignalReturn,
          detectionRadiusKm: cfg.detectionRadiusKm);
    }
    config = cfg;
    try {
      permissions = await PermissionService.check();
    } catch (_) {}

    // Botones del reproductor multimedia (notificación / pantalla de bloqueo).
    media.onRefreshRequested = () async {
      await BackgroundTripService.requestImmediateUpdate();
    };
    media.onPauseRequested = () async => BackgroundTripService.pauseTracking();
    media.onResumeRequested = () async => BackgroundTripService.resumeTracking();
    media.onStopRequested = () async {
      await BackgroundTripService.stopTrip();
    };
    media.onExploreRequested = () async {
      BackgroundTripService.exploreRequests.value =
          ExploreRequest(townId: currentTown.id, at: DateTime.now());
    };

    BackgroundTripService.latestSnapshot.addListener(_onSnapshotChanged);
    BackgroundTripService.lastError.addListener(_onBackground);
    BackgroundTripService.isRunning.addListener(_onRunningChanged);
    BackgroundTripService.isPaused.addListener(_onPausedChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onBackground() => notifyListeners();

  void _onRunningChanged() {
    notifyListeners();
    if (!running) unawaited(media.showStopped());
  }

  void _onPausedChanged() {
    notifyListeners();
    _syncMedia();
  }

  void _onSnapshotChanged() {
    notifyListeners();
    if (!running || snapshot == null) return;
    _syncMedia();
    final cur = currentTown;
    final nxt = nextTown;
    if (hasRealPlace) {
      ensureHero(cur);
      _prefetch(cur);
    }
    if (nxt != null) {
      ensureHero(nxt);
      _prefetch(nxt);
    }
  }

  /// Pre-carga de fotos + ficha IA del pueblo actual y del siguiente.
  void _prefetch(TownModel t) {
    if (!settings.hasLlmKey || _prefetched.contains(t.id)) return;
    _prefetched.add(t.id);
    unawaited(ai
        .prefetch(t, settings: settings, tripContext: _tripContext())
        .then((ok) {
      if (!ok) _prefetched.remove(t.id);
    }));
  }

  // ── Reproductor multimedia ─────────────────────────────────────────────

  String _thousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  /// Foto de respaldo inmediata mientras responden Wikipedia/Commons.
  String _fallbackArt(int? altitudeM) =>
      'https://picsum.photos/seed/rutaviva_${altitudeM ?? 0}/1000/600';

  Future<void> _publishStarting() {
    final plan = plannedRoute;
    return media.publish(
      placeId: 'rutaviva-start',
      title: '📍 Obteniendo ubicación…',
      artist: mode == TripMode.free
          ? 'Explorando alrededor tuyo'
          : 'Rumbo a $destinationLabel',
      kmTotal: plan?.totalKm ?? 0,
      kmTraveled: 0,
      artUrl: _fallbackArt(null),
      paused: false,
    );
  }

  void _syncMedia() {
    if (!running) return;
    final s = snapshot;
    if (s == null) return;
    final p = s.progress;
    final town = currentTown;
    final alt = p.place?.altitudeM ?? (town.msnm > 0 ? town.msnm : null);
    final title = (alt != null && alt > 0)
        ? '📍 ${town.nombreLugar} (${_thousands(alt)} msnm)'
        : '📍 ${town.nombreLugar}';

    String artist;
    if (mode == TripMode.free) {
      final parts = <String>[];
      for (final v in [town.provincia, town.departamento]) {
        final t = v.trim();
        if (t.isNotEmpty && !parts.contains(t)) parts.add(t);
      }
      artist = 'Explorando ${parts.isEmpty ? town.nombre : parts.join(', ')}';
    } else {
      final nxt = nextTown;
      final nextName = nxt == null ? 'destino' : nxt.nombreLugar;
      final km = p.nextTownDistanceKm;
      final kmTxt = km == null ? '' : ' (${km.round()} km)';
      artist = 'Rumbo a $destinationLabel • Próx: $nextName$kmTxt';
    }

    final art = heroFor(town)?.url ?? _fallbackArt(alt);
    unawaited(media.publish(
      placeId: town.id,
      title: title,
      artist: artist,
      kmTotal: p.kmTotal,
      kmTraveled: p.kmTraveled,
      artUrl: art,
      paused: BackgroundTripService.isPaused.value,
    ));
  }

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
  bool get paused => BackgroundTripService.isPaused.value;
  String? get serviceError => BackgroundTripService.lastError.value;
  TripMode get mode => config.mode;
  bool get isForward => config.originId == TripConfig.limaToArequipa.originId;

  TownModel get originTown => geocoder.byId(config.originId) ??
      geocoder.requireById(TripConfig.limaToArequipa.originId);
  TownModel get destinationTown => geocoder.byId(config.destinationId) ??
      geocoder.requireById(TripConfig.limaToArequipa.destinationId);

  String get originLabel {
    switch (mode) {
      case TripMode.corridor:
        return originTown.nombreLugar;
      case TripMode.custom:
        return plannedRoute?.origin.name ?? 'Mi ubicación';
      case TripMode.free:
        return 'Mi ubicación';
    }
  }

  String get destinationLabel {
    switch (mode) {
      case TripMode.corridor:
        return destinationTown.nombreLugar;
      case TripMode.custom:
        return config.customDestination?.name ?? '';
      case TripMode.free:
        return '';
    }
  }

  String get routeLabel {
    if (mode == TripMode.free) return 'Exploración libre';
    return '$originLabel a $destinationLabel';
  }

  /// Distancia total de la ruta en km (0 en modo libre).
  double get totalKm {
    switch (mode) {
      case TripMode.corridor:
        return (destinationTown.kmRuta - originTown.kmRuta).abs();
      case TripMode.custom:
        return snapshot?.progress.kmTotal ?? plannedRoute?.totalKm ?? 0;
      case TripMode.free:
        return 0;
    }
  }

  /// `false` mientras no hay lugar resuelto en modos dinámicos (evita buscar
  /// fotos de un lugar ficticio).
  bool get hasRealPlace =>
      mode == TripMode.corridor || snapshot?.progress.place != null;

  /// Última lectura, solo si pertenece a la ruta/modo actualmente elegidos.
  TripSnapshot? get snapshot {
    final s = BackgroundTripService.latestSnapshot.value;
    if (s == null) return null;
    if (s.progress.mode != config.mode) return null;
    switch (config.mode) {
      case TripMode.corridor:
        final o = geocoder.byId(config.originId);
        final d = geocoder.byId(config.destinationId);
        if (o == null || d == null) return null;
        if (s.progress.originName != o.nombreLugar ||
            s.progress.destinationName != d.nombreLugar) {
          return null;
        }
        return s;
      case TripMode.custom:
        final dest = config.customDestination;
        if (dest == null || s.progress.destinationName != dest.name) return null;
        return s;
      case TripMode.free:
        return s;
    }
  }

  static const TownModel _placeholderTown = TownModel(
    id: 'geo:ubicacion-actual',
    orden: 0,
    nombre: 'Mi ubicación',
    provincia: '',
    departamento: '',
    lat: -12.0464,
    lng: -77.0428,
    msnm: 0,
    kmRuta: 0,
    tipo: TownType.distrito,
    etiqueta: '',
    enRutaPrincipal: false,
    desvioKm: 0,
    wikipedia: null,
  );

  TownModel _townFromPlace(GeoPlace pl) {
    if (pl.townId != null) {
      final t = geocoder.byId(pl.townId!);
      if (t != null) return t;
    }
    return pl.toTownModel();
  }

  TownModel get currentTown {
    final p = snapshot?.progress;
    if (p != null) {
      final pl = p.place;
      if (pl != null) return _townFromPlace(pl);
      final t = geocoder.byId(p.currentTownId);
      if (t != null) return t;
    }
    return mode == TripMode.corridor ? originTown : _placeholderTown;
  }

  TownModel? get nextTown {
    final p = snapshot?.progress;
    final np = p?.nextPlace;
    if (np != null) return _townFromPlace(np);
    if (mode != TripMode.corridor) return null;
    final id = p?.nextTownId;
    if (id != null) return geocoder.byId(id);
    for (final stop in timeline) {
      if (stop.status == TownStatus.upcoming && stop.town.enRutaPrincipal) {
        return stop.town;
      }
    }
    return null;
  }

  /// Resuelve un id (localidad del JSON o lugar dinámico del viaje actual).
  TownModel? townForId(String? id) {
    if (id == null) return null;
    final cur = currentTown;
    if (cur.id == id) return cur;
    final nxt = nextTown;
    if (nxt != null && nxt.id == id) return nxt;
    return geocoder.byId(id);
  }

  List<RouteStop> get timeline => mode == TripMode.corridor
      ? geocoder.buildTimeline(config, progress: snapshot?.progress)
      : const <RouteStop>[];

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
      return await _startWith(config);
    } finally {
      starting = false;
      await refreshPermissions();
    }
  }

  /// Arranca el seguimiento; en modo `custom` calcula antes la ruta OSRM.
  Future<String?> _startWith(TripConfig cfg) async {
    RoutePlan? plan;
    if (cfg.mode == TripMode.custom) {
      final dest = cfg.customDestination;
      if (dest == null) return 'Elige un destino para iniciar el viaje.';
      final perms = await PermissionService.check();
      if (!perms.canRunTrip) {
        return 'Faltan requisitos: ${perms.missingForTrip.join(', ')}.';
      }
      planning = true;
      notifyListeners();
      try {
        final origin = await _currentPlace();
        if (origin == null) {
          return 'No se pudo obtener tu ubicación actual. Activa el GPS e inténtalo de nuevo.';
        }
        plan = await _osrm.route(origin: origin, destination: dest);
      } on RoutingException catch (e) {
        return e.message;
      } finally {
        planning = false;
        notifyListeners();
      }
    }
    plannedRoute = plan;
    final result = await BackgroundTripService.startTrip(cfg, plan: plan);
    if (!result.success) return result.message;
    await _publishStarting();
    return null;
  }

  Future<GeoPlace?> _currentPlace() async {
    try {
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: const Duration(seconds: 25),
          ),
        );
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      if (pos == null) return null;
      final place = await _resolver.resolve(pos.latitude, pos.longitude,
          altitudeM: pos.altitude > 0 ? pos.altitude : null);
      return place.copyWith(lat: pos.latitude, lng: pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Cambia modo/sentido/intervalo/señal; si hay viaje activo lo reinicia.
  Future<String?> updateConfig(TripConfig next) async {
    if (!next.isValid && next.mode != TripMode.custom) {
      return 'Configuración de viaje inválida.';
    }
    config = next;
    await settingsRepo.saveTripDefaults(next);
    notifyListeners();
    if (running) {
      if (!next.isValid) {
        await BackgroundTripService.stopTrip();
        return null;
      }
      final r = await _startWith(next);
      notifyListeners();
      return r;
    }
    return null;
  }

  Future<String?> setMode(TripMode m) {
    switch (m) {
      case TripMode.corridor:
        final needsIds = config.originId == 'gps';
        return updateConfig(config.copyWith(
          mode: TripMode.corridor,
          originId: needsIds ? TripConfig.limaToArequipa.originId : config.originId,
          destinationId:
              needsIds ? TripConfig.limaToArequipa.destinationId : config.destinationId,
        ));
      case TripMode.custom:
        final dest = config.customDestination;
        return updateConfig(config.copyWith(
          mode: TripMode.custom,
          originId: 'gps',
          destinationId: dest == null ? 'custom' : 'custom:${dest.id}',
        ));
      case TripMode.free:
        return updateConfig(
            config.copyWith(mode: TripMode.free, originId: 'gps', destinationId: 'free'));
    }
  }

  Future<String?> setCustomDestination(GeoPlace place) =>
      updateConfig(TripConfig.toDestination(place, base: config));

  Future<List<GeoPlace>> searchPlaces(String query) => nominatim.search(query);

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
    for (final k in prefs.getKeys().where((k) => k.startsWith(_heroPrefix)).toList()) {
      await prefs.remove(k);
    }
    _hero.clear();
    _heroPending.clear();
    _prefetched.clear();
    _guides.clear();
    notifyListeners();
  }

  // ── Foto de fondo del pueblo actual (tarjeta "Now Playing") ─────────────

  static const String _heroPrefix = 'rv_hero_v2_';
  static const Duration _heroTtl = Duration(days: 30);
  final Map<String, TownPhoto> _hero = {};
  final Set<String> _heroPending = {};

  TownPhoto? heroFor(TownModel t) => _hero[t.id];

  void ensureHero(TownModel t) {
    if (_hero.containsKey(t.id) || _heroPending.contains(t.id)) return;
    _heroPending.add(t.id);
    unawaited(_loadHero(t));
  }

  TownPhoto? _pickHero(List<TownPhoto> photos) {
    if (photos.isEmpty) return null;
    for (final p in photos) {
      final w = p.width ?? 0;
      final h = p.height ?? 0;
      if (w > 0 && h > 0 && w >= h * 1.2) return p;
    }
    return photos.first;
  }

  Future<void> _loadHero(TownModel t) async {
    TownPhoto? pick;
    try {
      final key = '$_heroPrefix${t.id}';
      final raw = prefs.getString(key);
      if (raw != null) {
        try {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          final at = DateTime.tryParse(j['at'] as String? ?? '');
          if (at != null &&
              DateTime.now().difference(at) < _heroTtl &&
              j['photo'] is Map) {
            pick = TownPhoto.fromJson(
                Map<String, dynamic>.from(j['photo'] as Map));
          }
        } catch (_) {}
      }
      if (pick == null) {
        final photos =
            await ai.fetchPhotos(t, placesApiKey: settings.placesApiKey);
        pick = _pickHero(photos);
        if (pick != null) {
          await prefs.setString(
              key,
              jsonEncode({
                'at': DateTime.now().toIso8601String(),
                'photo': pick.toJson(),
              }));
        }
      }
    } catch (_) {}

    if (pick != null) {
      _hero[t.id] = pick;
      _heroPending.remove(t.id);
      notifyListeners();
      if (running && currentTown.id == t.id) _syncMedia();
    } else {
      // Sin datos: reintentar más tarde (no en cada redibujado).
      Future<void>.delayed(
          const Duration(minutes: 5), () => _heroPending.remove(t.id));
    }
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
    BackgroundTripService.latestSnapshot.removeListener(_onSnapshotChanged);
    BackgroundTripService.lastError.removeListener(_onBackground);
    BackgroundTripService.isRunning.removeListener(_onRunningChanged);
    BackgroundTripService.isPaused.removeListener(_onPausedChanged);
    _resolver.dispose();
    _osrm.dispose();
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    ai.dispose();
    super.dispose();
  }
}
