import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../models/geo_models.dart';
import '../models/town_model.dart';
import '../models/trip_models.dart';
import '../providers/trip_provider.dart';
import '../services/background_trip_service.dart';
import '../widgets/destination_picker.dart';
import '../widgets/rv_widgets.dart';
import 'settings_screen.dart';
import 'town_explorer_sheet.dart';

class HomeTripScreen extends ConsumerStatefulWidget {
  const HomeTripScreen({super.key});

  @override
  ConsumerState<HomeTripScreen> createState() => _HomeTripScreenState();
}

class _HomeTripScreenState extends ConsumerState<HomeTripScreen> {
  @override
  void initState() {
    super.initState();
    BackgroundTripService.exploreRequests.addListener(_onExplore);
    // Si la app se abrió desde el botón "¿Qué hay aquí?" de la notificación.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onExplore();
      // Lectura GPS + geocodificación inversa inmediata al abrir la app.
      ref.read(tripProvider).refreshLiveLocation();
    });
  }

  @override
  void dispose() {
    BackgroundTripService.exploreRequests.removeListener(_onExplore);
    super.dispose();
  }

  void _onExplore() {
    final req = BackgroundTripService.exploreRequests.value;
    if (req == null || !mounted) return;
    BackgroundTripService.consumeExploreRequest();
    final c = ref.read(tripProvider);
    final id = req.townId ?? c.snapshot?.progress.currentTownId;
    final town = c.townForId(id);
    if (town != null) TownExplorerSheet.show(context, town);
  }

  void _snack(String? msg) {
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.surfaceHigh,
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _applyConfig(TripController c, TripConfig next) async {
    final err = await c.updateConfig(next);
    _snack(err);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(tripProvider);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.surface,
          onRefresh: c.refreshPermissions,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _header(c),
              _searchBar(c),
              if (!c.settings.hasLlmKey) _aiKeyHint(),
              if (c.permissions != null)
                RvPermissionBanner(
                  snapshot: c.permissions!,
                  busy: c.permissionsBusy,
                  onGrant: c.grantAllPermissions,
                ),
              if (c.serviceError != null && c.running)
                RvStatusCard(
                  icon: Icons.warning_amber_rounded,
                  title: 'Aviso del seguimiento',
                  message: c.serviceError,
                ),
              _nowPlaying(c),
              _controls(c),
            ],
          ),
        ),
      ),
    );
  }

  // ── Cabecera ───────────────────────────────────────────────────────────

  Widget _header(TripController c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Row(
        children: [
          const Icon(Icons.route, color: AppColors.accent),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('RutaViva AI',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
          IconButton(
            tooltip: 'Ajustes',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aiKeyHint() {
    return RvStatusCard(
      icon: Icons.key,
      color: AppColors.accent,
      title: 'Activa la exploración con IA',
      message: 'Agrega tu API Key de Gemini en Ajustes para ver historia, '
          'gastronomía y paradas de cada pueblo.',
      action: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
          child: const Text('Abrir Ajustes'),
        ),
      ),
    );
  }

  // ── Tarjeta "Now Playing" con foto real del pueblo ──────────────────────

  Widget _nowPlaying(TripController c) {
    final snap = c.snapshot;
    final p = snap?.progress;
    final town = c.currentTown;
    final next = c.nextTown;
    final total = c.totalKm;
    final corridor = c.mode == TripMode.corridor;

    // Descarga (y cachea) la foto panorámica del pueblo actual.
    if (c.hasRealPlace) {
      WidgetsBinding.instance.addPostFrameCallback((_) => c.ensureHero(town));
    }

    final String status;
    if (p == null) {
      status = c.running
          ? 'Obteniendo ubicación...'
          : (c.livePlace != null
              ? 'Ubicación actual'
              : (c.liveBusy
                  ? 'Detectando tu ubicación...'
                  : 'Ubicación no disponible'));
    } else if (p.arrived) {
      status = 'Llegaste a tu destino';
    } else if (p.atTown) {
      status = corridor ? '${town.provincia} · estás en el pueblo' : 'Estás aquí';
    } else {
      status = 'Último pueblo · a ${formatKm(p.distanceToCurrentTownKm)} km';
    }

    final double? nextDist = p != null
        ? p.nextTownDistanceKm
        : (next != null && corridor
            ? (next.kmRuta - c.originTown.kmRuta).abs()
            : null);
    final remaining = p?.kmRemaining ?? total;

    final warnings = <String>[
      if (p != null && p.isOffRoute)
        'Estás a ${formatKm(p.offRouteKm)} km de la carretera principal.',
      if (snap != null && snap.isStale)
        'Posición aproximada: se usó la última ubicación conocida.',
    ];

    String footer = 'Inicia el seguimiento para ver tu avance en vivo.';
    if (snap != null) {
      final hh = snap.readAt.hour.toString().padLeft(2, '0');
      final mm = snap.readAt.minute.toString().padLeft(2, '0');
      final acc = snap.accuracyMeters != null
          ? ' · ±${snap.accuracyMeters!.round()} m'
          : '';
      footer = 'Lectura $hh:$mm · ${snap.reason.label}$acc';
    }

    return RvNowPlayingCard(
      imageUrl: c.heroFor(town)?.url,
      running: c.running,
      pillText: '${c.running ? 'EN VIVO' : 'LISTO'}  •  '
          '${town.msnm > 0 ? '${formatThousands(town.msnm)} msnm' : 'altitud no disponible'}'
          '${corridor ? '  •  Km ${town.kmRuta.round()}' : ''}',
      townName: town.nombre,
      subtitle: [town.provincia, town.departamento]
          .where((e) => e.trim().isNotEmpty)
          .join(' · '),
      statusText: status,
      nextLabel: next?.nombre ?? (c.mode == TripMode.free ? 'Explorando' : 'Destino'),
      nextDetail: nextDist != null
          ? 'Faltan ${formatKm(nextDist)} km'
          : (c.mode == TripMode.free ? 'sin destino' : 'a la vista'),
      destinationDetail: c.mode == TripMode.free
          ? 'Ubicación actual en vivo'
          : 'Faltan ${formatKm(remaining)} km hasta ${c.destinationLabel}',
      progress: p?.progress ?? 0,
      leftLabel: '${p?.percent ?? 0}% · ${formatKm(p?.kmTraveled ?? 0)} km',
      rightLabel: '${formatKm(p?.kmTotal ?? total)} km',
      footer: footer,
      warnings: warnings,
      onTap: () => TownExplorerSheet.show(context, town),
    );
  }

  // ── Buscador único (estilo Maps) ───────────────────────────────────────

  Widget _searchBar(TripController c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DestinationPicker(
        selected: c.mode == TripMode.custom ? c.config.customDestination : null,
        enabled: !c.planning && !c.starting,
        planning: c.planning,
        onSearch: c.searchPlaces,
        onSelected: (p) async => _snack(await c.setCustomDestination(p)),
        onClear: () async => _snack(await c.clearDestination()),
      ),
    );
  }

  // ── Controles ──────────────────────────────────────────────────────────

  Widget _controls(TripController c) {
    final cfg = c.config;
    final hasDest = c.mode == TripMode.custom;
    final startLabel = hasDest ? 'Iniciar ruta' : 'Seguir mi ubicación';
    return RvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RvSectionTitle('Intervalo de lectura'),
          Wrap(
            spacing: 8,
            children: [
              for (final m in const [15, 30, 60])
                ChoiceChip(
                  label: Text('$m min'),
                  selected: cfg.intervalMinutes == m,
                  showCheckmark: false,
                  selectedColor: AppColors.accentDeep,
                  backgroundColor: AppColors.surfaceHigh,
                  labelStyle: TextStyle(
                    color: cfg.intervalMinutes == m
                        ? AppColors.accent
                        : AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  side: BorderSide(
                    color: cfg.intervalMinutes == m
                        ? AppColors.accent
                        : AppColors.outline,
                  ),
                  onSelected: (_) =>
                      _applyConfig(c, cfg.copyWith(intervalMinutes: m)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: cfg.updateOnSignalReturn,
            onChanged: (v) =>
                _applyConfig(c, cfg.copyWith(updateOnSignalReturn: v)),
            title: const Text('Actualizar al recuperar señal móvil',
                style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              'Cuando vuelve el 4G/5G se lee tu ubicación al instante.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: c.running
                      ? () async => _snack(await c.refreshNow())
                      : (c.liveBusy ? null : () => c.refreshLiveLocation()),
                  icon: const Icon(Icons.my_location_outlined),
                  label: const Text('Actualizar'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: c.running
                      ? FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                          foregroundColor: AppColors.black)
                      : null,
                  onPressed: c.starting
                      ? null
                      : () async => _snack(await c.toggleTrip()),
                  icon: c.starting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(c.running
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded),
                  label: Text(c.running
                      ? (hasDest ? 'Finalizar ruta' : 'Detener')
                      : startLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
