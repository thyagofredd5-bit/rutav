import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

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

/// Barra de progreso estilo reproductor de Spotify (pista fina + perilla).
class RvProgressBar extends StatelessWidget {
  const RvProgressBar({
    super.key,
    required this.progress,
    this.leftLabel,
    this.rightLabel,
  });

  final double progress;
  final String? leftLabel;
  final String? rightLabel;

  @override
  Widget build(BuildContext context) {
    final p = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    const thumb = 14.0;
    const anim = Duration(milliseconds: 700);
    return Column(
      children: [
        SizedBox(
          height: 18,
          child: LayoutBuilder(builder: (context, cons) {
            final w = cons.maxWidth;
            final travel = (w - thumb) * p;
            return Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                AnimatedContainer(
                  duration: anim,
                  curve: Curves.easeOutCubic,
                  height: 4,
                  width: travel + thumb / 2,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                AnimatedPositioned(
                  duration: anim,
                  curve: Curves.easeOutCubic,
                  left: travel,
                  child: Container(
                    width: thumb,
                    height: thumb,
                    decoration: const BoxDecoration(
                      color: AppColors.textPrimary,
                      shape: BoxShape.circle,
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
                    style: const TextStyle(
                        color: AppColors.accent,
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
