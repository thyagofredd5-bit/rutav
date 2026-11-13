import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../models/geo_models.dart';

/// Buscador de destino libre (Nominatim, solo Perú).
/// Política de Nominatim: sin autocompletado por tecla → se busca al dejar de
/// escribir (900 ms, mínimo 3 letras) o al pulsar la lupa / Enter.
class DestinationPicker extends StatefulWidget {
  const DestinationPicker({
    super.key,
    required this.onSearch,
    required this.onSelected,
    this.selected,
    this.enabled = true,
  });

  final Future<List<GeoPlace>> Function(String query) onSearch;
  final ValueChanged<GeoPlace> onSelected;
  final GeoPlace? selected;
  final bool enabled;

  @override
  State<DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<DestinationPicker> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<GeoPlace> _results = const <GeoPlace>[];
  bool _loading = false;
  bool _searched = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 3) {
      setState(() {
        _results = const <GeoPlace>[];
        _searched = false;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 900), _search);
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final q = _controller.text.trim();
    if (q.length < 3) return;
    final seq = ++_seq;
    setState(() => _loading = true);
    List<GeoPlace> found = const <GeoPlace>[];
    try {
      found = await widget.onSearch(q);
    } catch (_) {}
    if (!mounted || seq != _seq) return;
    setState(() {
      _results = found;
      _loading = false;
      _searched = true;
    });
  }

  void _pick(GeoPlace p) {
    FocusScope.of(context).unfocus();
    setState(() {
      _results = const <GeoPlace>[];
      _searched = false;
      _controller.clear();
    });
    widget.onSelected(p);
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sel != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.accentDeep,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accent),
            ),
            child: Row(
              children: [
                const Icon(Icons.flag_rounded, color: AppColors.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sel.name,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w700)),
                      if (sel.subtitle.isNotEmpty)
                        Text(sel.subtitle,
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        TextField(
          controller: _controller,
          enabled: widget.enabled,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (_) => _search(),
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Busca un destino (Cusco, Surquillo, Estadio Nacional…)',
            hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            filled: true,
            fillColor: AppColors.surfaceHigh,
            prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textMuted),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.arrow_forward_rounded),
                    color: AppColors.accent,
                    onPressed: widget.enabled ? _search : null,
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.outline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.outline),
            ),
          ),
        ),
        if (_searched && _results.isEmpty && !_loading)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Sin resultados en Perú. Prueba con otro nombre.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
          ),
        for (final r in _results)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined, color: AppColors.accent),
            title: Text(r.name,
                style: const TextStyle(color: AppColors.textPrimary)),
            subtitle: Text(r.subtitle,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
            onTap: () => _pick(r),
          ),
      ],
    );
  }
}
