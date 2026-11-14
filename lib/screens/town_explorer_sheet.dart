import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_constants.dart';
import '../core/app_theme.dart';
import '../models/ai_town_guide.dart';
import '../models/town_model.dart';
import '../providers/trip_provider.dart';
import '../widgets/rv_widgets.dart';
import 'settings_screen.dart';

Future<void> _openUrl(String? url) async {
  if (url == null || url.isEmpty) return;
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Hoja modal con fotos reales + ficha generada por la IA (con caché local).
class TownExplorerSheet extends ConsumerStatefulWidget {
  const TownExplorerSheet({super.key, required this.town, this.scrollController});

  final TownModel town;
  final ScrollController? scrollController;

  static Future<void> show(BuildContext context, TownModel town) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.97,
        builder: (ctx, controller) =>
            TownExplorerSheet(town: town, scrollController: controller),
      ),
    );
  }

  @override
  ConsumerState<TownExplorerSheet> createState() => _TownExplorerSheetState();
}

class _TownExplorerSheetState extends ConsumerState<TownExplorerSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(tripProvider).loadGuide(widget.town);
    });
  }

  String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return 'hace unos minutos';
    if (diff.inHours < 24) return 'hace ${diff.inHours} h';
    return 'hace ${diff.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(tripProvider);
    final town = widget.town;
    final state = c.guideFor(town.id);
    final guide = state.guide;

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(town.nombre,
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w800, height: 1.1)),
                  const SizedBox(height: 4),
                  Text('${town.provincia} · ${town.departamento}',
                      style: const TextStyle(color: AppColors.textMuted)),
                ],
              ),
            ),
            if (state.isBusy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(
                tooltip: 'Actualizar ficha',
                icon: const Icon(Icons.refresh),
                onPressed: () => c.loadGuide(town, forceRefresh: true),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            RvChip.altitude(town.msnm),
            RvChip.km(town.kmRuta),
            RvChip(
                label: town.tipo.label,
                icon: Icons.place,
                color: AppColors.textMuted),
          ],
        ),
        if (town.etiqueta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(town.etiqueta,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        _PhotoCarousel(photos: state.photos, loading: state.loadingPhotos),
        const SizedBox(height: 12),
        _statusLine(state),
        if (state.hasError) _errorCard(c, state),
        if (guide == null && !state.hasError) ...const [
          _SkeletonCard(),
          _SkeletonCard(),
          _SkeletonCard(),
        ],
        if (guide != null) ..._guideSections(guide, state),
        if (state.placesError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text('Restaurantes (Google Places): ${state.placesError}',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ),
        if (guide != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: state.isBusy
                  ? null
                  : () => c.loadGuide(town, forceRefresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Actualizar ficha (usa tu API Key)'),
            ),
          ),
      ],
    );
  }

  Widget _statusLine(TownGuideState state) {
    String? text;
    IconData icon = Icons.info_outline;
    if (state.loadingGuide) {
      text = 'Preparando la ficha del pueblo…';
      icon = Icons.auto_awesome;
    } else if (state.guide != null && state.fromCache) {
      final at = state.cachedAt ?? state.guide!.generatedAt;
      text = 'Guardado en tu teléfono · ${_ago(at)} · sin gastar datos';
      icon = Icons.offline_pin;
    } else if (state.guide != null) {
      final g = state.guide!;
      text = g.groundedWithSearch
          ? 'Investigado hoy en Google Search · ${g.model}'
          : 'Generado por IA · ${g.model}';
      icon = Icons.auto_awesome;
    }
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _errorCard(TripController c, TownGuideState state) {
    final kind = state.errorKind;
    final needsSettings = kind == AiErrorKind.noApiKey || kind == AiErrorKind.auth;
    final String title;
    switch (kind) {
      case AiErrorKind.noApiKey:
        title = 'Falta tu API Key';
      case AiErrorKind.auth:
        title = 'API Key rechazada';
      case AiErrorKind.network:
        title = 'Sin conexión';
      case AiErrorKind.quota:
        title = 'Límite de uso alcanzado';
      case AiErrorKind.blocked:
        title = 'Consulta bloqueada';
      default:
        title = 'No se pudo generar la ficha';
    }
    return RvStatusCard(
      icon: kind == AiErrorKind.network ? Icons.signal_wifi_off : Icons.error_outline,
      color: kind == AiErrorKind.network ? AppColors.amber : AppColors.danger,
      title: title,
      message: state.errorMessage,
      action: Align(
        alignment: Alignment.centerLeft,
        child: needsSettings
            ? TextButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('Ir a Ajustes'),
                onPressed: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  nav.push(MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen()));
                },
              )
            : TextButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
                onPressed: state.isBusy
                    ? null
                    : () => c.loadGuide(widget.town, forceRefresh: true),
              ),
      ),
    );
  }

  List<Widget> _guideSections(AiTownGuide g, TownGuideState state) {
    return [
      if (g.resumenHistoricoCurioso.isNotEmpty)
        _InfoCard(
            icon: Icons.history_edu_outlined,
            title: 'Historia y curiosidades',
            body: g.resumenHistoricoCurioso),
      if (g.climaYGeografia.isNotEmpty)
        _InfoCard(
            icon: Icons.wb_sunny_outlined,
            title: 'Clima y geografía',
            body: g.climaYGeografia),
      if (g.gastronomia.isNotEmpty) ...[
        const RvSectionTitle('Platos típicos imperdibles'),
        for (final d in g.gastronomia) _DishTile(item: d),
      ],
      if (g.lugares.isNotEmpty) ...[
        const RvSectionTitle('Lugares y paradas'),
        for (final p in g.lugares) _StopTile(item: p),
      ],
      if (state.places.isNotEmpty) ...[
        const RvSectionTitle('Restaurantes reales cerca'),
        for (final p in state.places) _PlaceTile(place: p),
      ],
      if (g.recomendacionViajero.isNotEmpty)
        _InfoCard(
          icon: Icons.explore_outlined,
          title: 'Consejo de ruta',
          body: g.recomendacionViajero,
          highlight: true,
        ),
      if (g.fuentes.isNotEmpty) ...[
        const RvSectionTitle('Fuentes consultadas'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in g.fuentes)
              ActionChip(
                avatar: const Icon(Icons.link, size: 16),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(f.titulo,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                backgroundColor: AppColors.surfaceHigh,
                side: const BorderSide(color: AppColors.outline),
                onPressed: () => _openUrl(f.url),
              ),
          ],
        ),
      ],
    ];
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  Piezas de la hoja
// ═════════════════════════════════════════════════════════════════════════

class _NetImage extends StatelessWidget {
  const _NetImage({required this.url, this.width, this.height, this.radius = 12});
  final String url;
  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        httpHeaders: AppConstants.httpHeaders,
        placeholder: (_, __) =>
            RvShimmerBox(height: height ?? 100, width: width, radius: 0),
        errorWidget: (_, __, ___) => Container(
          width: width,
          height: height,
          color: AppColors.surfaceHigh,
          child: const Icon(Icons.image_not_supported_outlined,
              color: AppColors.textMuted),
        ),
      ),
    );
  }
}

class _PhotoCarousel extends StatefulWidget {
  const _PhotoCarousel({required this.photos, required this.loading});
  final List<TownPhoto> photos;
  final bool loading;

  @override
  State<_PhotoCarousel> createState() => _PhotoCarouselState();
}

class _PhotoCarouselState extends State<_PhotoCarousel> {
  final PageController _page = PageController(viewportFraction: 0.92);
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    if (photos.isEmpty) {
      return widget.loading
          ? const RvShimmerBox(height: 220, radius: 18)
          : Container(
              height: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Text('Sin fotos disponibles (requiere conexión)',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            );
    }
    final safe = _index.clamp(0, photos.length - 1);
    return Column(
      children: [
        SizedBox(
          height: 220,
          child: PageView.builder(
            controller: _page,
            itemCount: photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) {
              final p = photos[i];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: GestureDetector(
                  onTap: () => _openUrl(p.pageUrl),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _NetImage(
                          url: p.thumbUrl ?? p.url, height: 220, radius: 18),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(18)),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Color(0xCC000000)],
                              ),
                            ),
                            child: Text(p.attribution,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white70)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (photos.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < photos.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: i == safe ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == safe ? AppColors.accent : AppColors.outline,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return const RvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RvShimmerBox(height: 14, width: 140),
          SizedBox(height: 12),
          RvShimmerBox(height: 12),
          SizedBox(height: 8),
          RvShimmerBox(height: 12),
          SizedBox(height: 8),
          RvShimmerBox(height: 12, width: 200),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return RvCard(
      borderColor: highlight ? AppColors.alpha(AppColors.accent, 0.4) : null,
      gradient: highlight
          ? const LinearGradient(
              colors: [AppColors.accentDeep, AppColors.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 14, height: 1.45)),
        ],
      ),
    );
  }
}

class _DishTile extends StatelessWidget {
  const _DishTile({required this.item});
  final GastronomyItem item;

  @override
  Widget build(BuildContext context) {
    final foto = item.foto;
    return RvCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (foto != null) ...[
            _NetImage(url: foto.thumbUrl ?? foto.url, width: 76, height: 76),
            const SizedBox(width: 12),
          ] else ...[
            Container(
              width: 76,
              height: 76,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.restaurant_outlined,
                  size: 30, color: AppColors.textMuted),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.plato,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 4),
                Text(item.descripcion,
                    style: const TextStyle(fontSize: 13, height: 1.35)),
                if (item.dondeBuscarlo.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.place_outlined,
                          size: 14, color: AppColors.accent),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(item.dondeBuscarlo,
                            style: const TextStyle(
                                color: AppColors.accent, fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({required this.item});
  final StopItem item;

  @override
  Widget build(BuildContext context) {
    final kind = item.kind;
    return RvCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(kind.icon, size: 26, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.nombre,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    RvChip(label: kind.label, color: AppColors.accent),
                    if (item.distanciaCarretera.isNotEmpty)
                      RvChip(
                          label: item.distanciaCarretera,
                          icon: Icons.alt_route,
                          color: AppColors.textMuted),
                  ],
                ),
                if (item.detalle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(item.detalle,
                      style: const TextStyle(fontSize: 13, height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({required this.place});
  final RoadsidePlace place;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (place.rating != null)
        'Valoración ${place.rating!.toStringAsFixed(1)}'
            '${place.ratingCount != null ? ' (${place.ratingCount})' : ''}',
      if (place.abiertoAhora != null)
        place.abiertoAhora! ? 'Abierto ahora' : 'Cerrado',
      if (place.distanciaKm != null) '${formatKm(place.distanciaKm!)} km',
    ].join(' · ');

    return RvCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      onTap: place.mapsUrl != null ? () => _openUrl(place.mapsUrl) : null,
      child: Row(
        children: [
          if (place.photoUrl != null) ...[
            _NetImage(url: place.photoUrl!, width: 64, height: 64),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.nombre,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                if (meta.isNotEmpty)
                  Text(meta,
                      style: const TextStyle(
                          color: AppColors.accent, fontSize: 12)),
                if (place.direccion != null)
                  Text(place.direccion!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
              ],
            ),
          ),
          if (place.mapsUrl != null)
            const Icon(Icons.map_outlined, color: AppColors.textMuted),
        ],
      ),
    );
  }
}
