import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../models/app_settings.dart';
import '../providers/trip_provider.dart';
import '../services/ai_explorer_service.dart';
import '../widgets/rv_widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _placesCtrl;
  late final TextEditingController _modelCtrl;
  late bool _grounding;
  bool _obscureKey = true;
  bool _obscurePlaces = true;
  bool _testingLlm = false;
  bool _testingPlaces = false;
  LlmTestResult? _llmResult;
  LlmTestResult? _placesResult;

  @override
  void initState() {
    super.initState();
    final s = ref.read(tripProvider).settings;
    _keyCtrl = TextEditingController(text: s.llmApiKey);
    _placesCtrl = TextEditingController(text: s.placesApiKey);
    _modelCtrl = TextEditingController(text: s.llmModel);
    _grounding = s.useWebGrounding;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(tripProvider).refreshPermissions();
    });
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _placesCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  AppSettings _candidate(AppSettings base) => base.copyWith(
        provider: LlmProvider.gemini,
        llmApiKey: _keyCtrl.text.trim(),
        llmModel: _modelCtrl.text.trim(),
        placesApiKey: _placesCtrl.text.trim(),
        useWebGrounding: _grounding,
      );

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.surfaceHigh,
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _save() async {
    final c = ref.read(tripProvider);
    await c.saveSettings(_candidate(c.settings));
    _snack('Ajustes guardados.');
  }

  Future<void> _testLlm() async {
    final c = ref.read(tripProvider);
    setState(() {
      _testingLlm = true;
      _llmResult = null;
    });
    final r = await c.testLlm(_candidate(c.settings));
    if (!mounted) return;
    setState(() {
      _testingLlm = false;
      _llmResult = r;
    });
  }

  Future<void> _testPlaces() async {
    final c = ref.read(tripProvider);
    setState(() {
      _testingPlaces = true;
      _placesResult = null;
    });
    final r = await c.testPlaces(_placesCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      _testingPlaces = false;
      _placesResult = r;
    });
  }

  Future<void> _clearCache() async {
    final c = ref.read(tripProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Borrar caché de pueblos'),
        content: const Text(
            'Se eliminarán las fichas guardadas. Volver a verlas gastará tu API Key.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    await c.clearGuideCache();
    _snack('Caché borrada.');
  }

  InputDecoration _decor(String label, {String? hint, Widget? suffix}) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.surfaceHigh,
      border: border(AppColors.outline),
      enabledBorder: border(AppColors.outline),
      focusedBorder: border(AppColors.accent),
    );
  }

  Widget _result(LlmTestResult? r) {
    if (r == null) return const SizedBox.shrink();
    final color = r.ok ? AppColors.accent : AppColors.danger;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(r.ok ? Icons.check_circle : Icons.error_outline,
              size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${r.message}${r.latencyMs != null ? ' (${r.latencyMs} ms)' : ''}',
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(tripProvider);
    final p = c.permissions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ajustes'),
        backgroundColor: AppColors.black,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const RvSectionTitle('Inteligencia artificial (Gemini)'),
          RvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _keyCtrl,
                  obscureText: _obscureKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: _decor(
                    'API Key de Gemini',
                    hint: 'AIza…',
                    suffix: IconButton(
                      icon: Icon(_obscureKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Créala gratis en Google AI Studio. Se guarda solo en este teléfono.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _modelCtrl,
                  autocorrect: false,
                  decoration: _decor('Modelo (opcional)',
                      hint: LlmProvider.gemini.defaultModel),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _grounding,
                  onChanged: (v) => setState(() => _grounding = v),
                  title: const Text('Investigar en Google Search',
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    'Grounding web: datos reales y actuales de restaurantes y atractivos.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testingLlm ? null : _testLlm,
                        icon: _testingLlm
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('Probar'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: const Text('Guardar'),
                      ),
                    ),
                  ],
                ),
                _result(_llmResult),
              ],
            ),
          ),
          const RvSectionTitle('Google Places (opcional)'),
          RvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _placesCtrl,
                  obscureText: _obscurePlaces,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: _decor(
                    'API Key de Google Places',
                    suffix: IconButton(
                      icon: Icon(_obscurePlaces
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscurePlaces = !_obscurePlaces),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Añade restaurantes reales con foto, calificación y mapa. Déjala vacía para omitirlo.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testingPlaces ? null : _testPlaces,
                        icon: _testingPlaces
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('Probar'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save),
                        label: const Text('Guardar'),
                      ),
                    ),
                  ],
                ),
                _result(_placesResult),
              ],
            ),
          ),
          const RvSectionTitle('Caché de pueblos'),
          RvCard(
            child: Row(
              children: [
                const Icon(Icons.offline_pin, color: AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${c.cachedTownCount} pueblos guardados para usar sin datos',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                TextButton.icon(
                  onPressed: c.cachedTownCount == 0 ? null : _clearCache,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Borrar'),
                ),
              ],
            ),
          ),
          const RvSectionTitle('Permisos de Android'),
          RvCard(
            child: p == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RvPermissionRow(
                        label: 'GPS del teléfono activado',
                        ok: p.gpsEnabled,
                        actionLabel: 'Activar',
                        onAction: c.openGpsSettings,
                      ),
                      RvPermissionRow(
                        label: 'Ubicación "Todo el tiempo"',
                        hint: 'Necesario para leer tu posición con la pantalla apagada.',
                        ok: p.locationAlways,
                        onAction: c.grantLocationAlways,
                      ),
                      RvPermissionRow(
                        label: 'Notificaciones',
                        hint: 'Muestran tu progreso en la barra de estado.',
                        ok: p.notifications,
                        onAction: c.grantNotifications,
                      ),
                      RvPermissionRow(
                        label: 'Ignorar optimización de batería',
                        hint: 'Evita que Android detenga el seguimiento.',
                        ok: p.batteryOptimizationIgnored,
                        onAction: c.grantBatteryIgnore,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: c.permissionsBusy
                                  ? null
                                  : c.grantAllPermissions,
                              icon: const Icon(Icons.bolt),
                              label: const Text('Conceder todo'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: c.openAppPermissionSettings,
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Ajustes del sistema'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
