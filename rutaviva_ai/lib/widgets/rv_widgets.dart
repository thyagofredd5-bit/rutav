import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../core/app_constants.dart';
import '../core/app_theme.dart';
import '../services/permission_service.dart';

/// "12" para >= 10 km, "4.3" para distancias cortas.
String formatKm(double km) {
  if (km.isNaN || km.isInfinite) return '–';
  return km >= 10 ? km.round().toString() : km.toStringAsFixed(1);
}

/// 3,812 (separador de miles para msnm).
String formatThousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return n < 0 ? '-${b.toString()}' : b.toString();
}

/// Tarjeta base AMOLED con borde fino y soporte de degradado.
class RvCard extends StatelessWidget {
  const RvCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.only(bottom: 12),
    this.onTap,
    this.gradient,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    return Padding(
      padding: margin,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: gradient == null ? AppColors.surface : null,
            gradient: gradient,
            borderRadius: radius,
            border: Border.all(color: borderColor ?? AppColors.outline),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Tarjeta de estado: aviso, error o confirmación con icono y acción opcional.
class RvStatusCard extends StatelessWidget {
  const RvStatusCard({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.color = AppColors.amber,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Color color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return RvCard(
      borderColor: AppColors.alpha(color, 0.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                if (message != null && message!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(message!,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 13, height: 1.35)),
                ],
                if (action != null) ...[
                  const SizedBox(height: 8),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra de progreso estilo reproductor de Spotify (pista + perilla brillante).
class RvProgressBar extends StatelessWidget {
  const RvProgressBar({
    super.key,
    required this.progress,
    this.leftLabel,
    this.rightLabel,
    this.color = AppColors.accent,
    this.trackHeight = 4,
    this.glow = false,
  });

  final double progress;
  final String? leftLabel;
  final String? rightLabel;
  final Color color;
  final double trackHeight;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final p = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    final thumb = trackHeight + 10;
    const anim = Duration(milliseconds: 700);
    return Column(
      children: [
        SizedBox(
          height: thumb + 4,
          child: LayoutBuilder(builder: (context, cons) {
            final w = cons.maxWidth;
            final travel = (w - thumb) * p;
            return Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: trackHeight,
                  decoration: BoxDecoration(
                    color: AppColors.alpha(Colors.white, 0.22),
                    borderRadius: BorderRadius.circular(trackHeight),
                  ),
                ),
                AnimatedContainer(
                  duration: anim,
                  curve: Curves.easeOutCubic,
                  height: trackHeight,
                  width: travel + thumb / 2,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(trackHeight),
                  ),
                ),
                AnimatedPositioned(
                  duration: anim,
                  curve: Curves.easeOutCubic,
                  left: travel,
                  child: Container(
                    width: thumb,
                    height: thumb,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: glow
                          ? [
                              BoxShadow(
                                  color: AppColors.alpha(color, 0.85),
                                  blurRadius: 12,
                                  spreadRadius: 1),
                            ]
                          : null,
                    ),
                  ),
                ),
              ],
            );
          }),
        ),
        if (leftLabel != null || rightLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(leftLabel ?? '',
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                Text(rightLabel ?? '',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Chip compacto (altitud, kilómetro, tipo de lugar…).
class RvChip extends StatelessWidget {
  const RvChip({
    super.key,
    required this.label,
    this.icon,
    this.color = AppColors.accent,
  });

  factory RvChip.altitude(int msnm, {Key? key}) => RvChip(
        key: key,
        icon: Icons.terrain,
        label: '${formatThousands(msnm)} msnm',
        color: AppColors.amber,
      );

  factory RvChip.km(double km, {Key? key}) => RvChip(
        key: key,
        icon: Icons.straighten,
        label: 'Km ${formatKm(km)}',
        color: AppColors.accent,
      );

  final String label;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.alpha(color, 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.alpha(color, 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class RvSectionTitle extends StatelessWidget {
  const RvSectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class RvShimmerBox extends StatelessWidget {
  const RvShimmerBox({super.key, this.height = 16, this.width, this.radius = 10});
  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.surfaceHigh,
      highlightColor: AppColors.outline,
      child: Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// Fila "permiso + estado + botón".
class RvPermissionRow extends StatelessWidget {
  const RvPermissionRow({
    super.key,
    required this.label,
    required this.ok,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  final String label;
  final bool ok;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline,
              size: 20, color: ok ? AppColors.accent : AppColors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (hint != null && !ok)
                  Text(hint!,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
              ],
            ),
          ),
          if (!ok && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel ?? 'Conceder')),
        ],
      ),
    );
  }
}

/// Banner de permisos de Android: verificación y solicitud en un toque.
class RvPermissionBanner extends StatelessWidget {
  const RvPermissionBanner({
    super.key,
    required this.snapshot,
    required this.onGrant,
    this.busy = false,
  });

  final PermissionSnapshot snapshot;
  final VoidCallback onGrant;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    if (s.isOptimal) {
      return RvCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        borderColor: AppColors.alpha(AppColors.accent, 0.35),
        child: const Row(
          children: [
            Icon(Icons.verified_user, color: AppColors.accent, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('Permisos listos · seguimiento en segundo plano habilitado',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
    }

    final blocked = !s.canRunTrip;
    final color = blocked ? AppColors.danger : AppColors.amber;
    return RvCard(
      borderColor: AppColors.alpha(color, 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(blocked ? Icons.gpp_maybe : Icons.shield_outlined,
                  color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  blocked
                      ? 'Faltan permisos para iniciar'
                      : 'Mejora el seguimiento en segundo plano',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          RvPermissionRow(label: 'GPS del teléfono activado', ok: s.gpsEnabled),
          RvPermissionRow(label: 'Ubicación', ok: s.locationWhileInUse),
          RvPermissionRow(label: 'Notificaciones', ok: s.notifications),
          RvPermissionRow(
              label: 'Ubicación "Todo el tiempo"', ok: s.locationAlways),
          RvPermissionRow(
              label: 'Sin optimización de batería',
              ok: s.batteryOptimizationIgnored),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onGrant,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bolt),
              label: const Text('Conceder permisos en un toque'),
            ),
          ),
        ],
      ),
    );
  }
}


// ═════════════════════════════════════════════════════════════════════════
//  Tarjeta "Now Playing" estilo Spotify con foto real de fondo
// ═════════════════════════════════════════════════════════════════════════

class RvNowPlayingCard extends StatelessWidget {
  const RvNowPlayingCard({
    super.key,
    required this.imageUrl,
    required this.pillText,
    required this.running,
    required this.townName,
    required this.subtitle,
    required this.statusText,
    required this.nextLabel,
    required this.nextDetail,
    required this.destinationDetail,
    required this.progress,
    required this.leftLabel,
    required this.rightLabel,
    required this.footer,
    this.warnings = const <String>[],
    this.onTap,
  });

  final String? imageUrl;
  final String pillText;
  final bool running;
  final String townName;
  final String subtitle;
  final String statusText;
  final String nextLabel;
  final String nextDetail;
  final String destinationDetail;
  final double progress;
  final String leftLabel;
  final String rightLabel;
  final String footer;
  final List<String> warnings;
  final VoidCallback? onTap;

  static const Color _bottom = Color(0xFF0A0E14);

  Widget _background() {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return Container(
        key: const ValueKey('rv-bg-none'),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.accentDeep, _bottom],
          ),
        ),
      );
    }
    return Image.network(
      url,
      key: ValueKey(url),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      headers: const {'User-Agent': AppConstants.httpUserAgent},
      errorBuilder: (_, __, ___) => Container(color: AppColors.accentDeep),
      loadingBuilder: (context, child, loading) =>
          loading == null ? child : Container(color: AppColors.accentDeep),
    );
  }

  Widget _glass({
    required Widget child,
    required double radius,
    required EdgeInsets padding,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: AppColors.alpha(Colors.white, 0.14),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: AppColors.alpha(Colors.white, 0.22)),
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 800),
                  switchInCurve: Curves.easeOut,
                  child: SizedBox.expand(
                    key: ValueKey(imageUrl ?? 'none'),
                    child: _background(),
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.alpha(Colors.black, 0.25),
                        AppColors.alpha(_bottom, 0.6),
                        _bottom,
                      ],
                      stops: const [0.0, 0.5, 0.88],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _glass(
                        radius: 999,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: running
                                    ? AppColors.spotify
                                    : AppColors.textMuted,
                                boxShadow: running
                                    ? [
                                        BoxShadow(
                                            color: AppColors.alpha(
                                                AppColors.spotify, 0.9),
                                            blurRadius: 8)
                                      ]
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                pillText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 130),
                    Text(
                      townName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                        height: 1.02,
                        shadows: [
                          Shadow(
                              blurRadius: 16,
                              color: AppColors.alpha(Colors.black, 0.6)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 16)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.near_me_rounded,
                            size: 14, color: AppColors.spotify),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(statusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.spotify,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _glass(
                      radius: 18,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.alpha(AppColors.spotify, 0.22),
                            ),
                            child: const Icon(Icons.explore_rounded,
                                color: AppColors.spotify),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('PRÓXIMO DESTINO',
                                    style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: 10,
                                        letterSpacing: 1.2,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text('$nextLabel • $nextDetail',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800)),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.route_rounded,
                                        size: 14, color: Colors.white60),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(destinationDetail,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    RvProgressBar(
                      progress: progress,
                      leftLabel: leftLabel,
                      rightLabel: rightLabel,
                      color: AppColors.spotify,
                      trackHeight: 8,
                      glow: true,
                    ),
                    const SizedBox(height: 10),
                    for (final w in warnings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                size: 15, color: AppColors.amber),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(w,
                                  style: const TextStyle(
                                      color: AppColors.amber, fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                    Text(footer,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12)),
                    const SizedBox(height: 4),
                    const Row(
                      children: [
                        Icon(Icons.touch_app_rounded,
                            size: 14, color: Colors.white54),
                        SizedBox(width: 6),
                        Text('Toca para explorar este pueblo',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
