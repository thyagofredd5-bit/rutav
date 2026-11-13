import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../models/town_model.dart';
import '../models/trip_models.dart';
import '../providers/trip_provider.dart';
import '../services/background_trip_service.dart';
import '../services/offline_geocoder_service.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _onExplore());
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
    final town = id == null ? null : c.geocoder.byId(id);
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
    final stops = c.timeline;

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
              RvSectionTitle(
                'Línea de tiempo · ${stops.length} localidades',
              ),
              for (var i = 0; i < stops.length; i++)
                _TimelineTile(
                  stop: stops[i],
                  isFirst: i == 0,
                  isLast: i == stops.length - 1,
                  onTap: () => TownExplorerSheet.show(context, stops[i].town),
                ),
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
    final total = (c.destinationTown.kmRuta - c.originTown.kmRuta).abs();

    // Descarga (y cachea) la foto panorámica del pueblo actual.
    WidgetsBinding.instance.addPostFrameCallback((_) => c.ensureHero(town));

    final String status;
    if (p == null) {
      status = c.running ? 'Obteniendo ubicación…' : 'Sin lectura todavía';
    } else if (p.arrived) {
      status = 'Llegaste a tu destino';
    } else if (p.atTown) {
      status = '${town.provincia} · estás en el pueblo';
    } else {
      status = 'Último pueblo · a ${formatKm(p.distanceToCurrentTownKm)} km';
    }

    final double? nextDist = p != null
        ? p.nextTownDistanceKm
        : (next != null ? (next.kmRuta - c.originTown.kmRuta).abs() : null);
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
      pillText: '${c.running ? 'EN RUTA' : 'LISTO'} • '
          '${formatThousands(town.msnm)} msnm • Km ${town.kmRuta.round()}',
      townName: town.nombre,
      subtitle: '${town.provincia} · ${town.departamento}',
      statusText: status,
      nextLabel: next?.nombre ?? 'Destino',
      nextDetail: nextDist != null
          ? 'Faltan ${formatKm(nextDist)} km'
          : 'a la vista',
      destinationDetail:
          'Faltan ${formatKm(remaining)} km hasta ${c.destinationTown.nombreLugar}',
      progress: p?.progress ?? 0,
      leftLabel: '${p?.percent ?? 0}% · ${formatKm(p?.kmTraveled ?? 0)} km',
      rightLabel: '${formatKm(p?.kmTotal ?? total)} km',
      footer: footer,
      warnings: warnings,
      onTap: () => TownExplorerSheet.show(context, town),
    );
  }

  Widget _dirLabel(String a, String b) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(a),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_forward_rounded, size: 16),
          const SizedBox(width: 6),
          Text(b),
        ],
      ),
    );
  }

  // ── Controles ──────────────────────────────────────────────────────────

  Widget _controls(TripController c) {
    final cfg = c.config;
    return RvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RvSectionTitle('Sentido del viaje'),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment<bool>(
                    value: true, label: _dirLabel('Lima', 'Arequipa')),
                ButtonSegment<bool>(
                    value: false, label: _dirLabel('Arequipa', 'Lima')),
              ],
              selected: {c.isForward},
              style: SegmentedButton.styleFrom(
                backgroundColor: AppColors.surfaceHigh,
                foregroundColor: AppColors.textMuted,
                selectedBackgroundColor: AppColors.accentDeep,
                selectedForegroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.outline),
                textStyle: const TextStyle(fontSize: 13),
              ),
              onSelectionChanged: (sel) {
                final fwd = sel.first;
                final base = fwd
                    ? TripConfig.limaToArequipa
                    : TripConfig.arequipaToLima;
                _applyConfig(
                  c,
                  cfg.copyWith(
                    originId: base.originId,
                    destinationId: base.destinationId,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
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
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Actualizar ahora'),
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
                      : Icon(c.running ? Icons.stop : Icons.play_arrow),
                  label: Text(c.running ? 'Detener' : 'Iniciar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  Línea de tiempo
// ═════════════════════════════════════════════════════════════════════════

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  final RouteStop stop;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TownModel t = stop.town;
    final status = stop.status;
    final Color dot;
    switch (status) {
      case TownStatus.current:
        dot = AppColors.accent;
      case TownStatus.passed:
        dot = AppColors.alpha(AppColors.accent, 0.45);
      case TownStatus.detour:
        dot = AppColors.amber;
      case TownStatus.upcoming:
        dot = AppColors.textMuted;
    }
    final lineColor = AppColors.outline;
    final dimmed = status == TownStatus.passed;

    final sub = StringBuffer('${t.provincia} · ${formatThousands(t.msnm)} msnm · '
        'km ${formatKm(stop.kmFromOrigin)}');
    if (status == TownStatus.detour) {
      sub.write(' · desvío ${t.desvioKm.round()} km');
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                        width: 2, color: isFirst ? Colors.transparent : lineColor),
                  ),
                  Container(
                    width: status == TownStatus.current ? 16 : 11,
                    height: status == TownStatus.current ? 16 : 11,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: status == TownStatus.detour ? AppColors.black : dot,
                      border: Border.all(color: dot, width: 2),
                      boxShadow: status == TownStatus.current
                          ? [
                              BoxShadow(
                                  color: AppColors.alpha(AppColors.accent, 0.5),
                                  blurRadius: 8)
                            ]
                          : null,
                    ),
                  ),
                  Expanded(
                    child: Container(
                        width: 2, color: isLast ? Colors.transparent : lineColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.nombre,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: status == TownStatus.current
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: dimmed
                            ? AppColors.textMuted
                            : status == TownStatus.current
                                ? AppColors.accent
                                : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(sub.toString(),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                    if (t.etiqueta.isNotEmpty)
                      Text(t.etiqueta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppColors.alpha(AppColors.textMuted, 0.75),
                              fontSize: 11)),
                  ],
                ),
              ),
            ),
            if (status == TownStatus.current)
              Align(
                alignment: Alignment.center,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.alpha(AppColors.accent, 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('AQUÍ',
                      style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              )
            else
              const Align(
                alignment: Alignment.center,
                child: Icon(Icons.chevron_right,
                    color: AppColors.textMuted, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
