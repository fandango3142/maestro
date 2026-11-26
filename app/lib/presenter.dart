import 'package:flutter/material.dart';

import 'theme.dart';

// Pieces of the two-screen presenter view (the layout itself is in stage.dart, next to the state it shows).

/// How far behind the plan the show is (negative = ahead). Plan time counts from the planned start of the
/// item where Ryan first pressed play ([firstStart]) to the current item's planned start plus [progress]
/// into it; real time counts from that first press ([sinceFirstPlay]).
Duration behindPlan({
  required Duration sinceFirstPlay,
  required Duration firstStart,
  required Duration currentStart,
  required Duration progress,
}) =>
    sinceFirstPlay - (currentStart - firstStart + progress);

/// "3 min behind" / "2 min ahead", or "on time" within half a minute.
String driftLabel(Duration behind) {
  final m = (behind.inSeconds / 60).round();
  return m == 0 ? 'on time' : '${m.abs()} min ${m > 0 ? 'behind' : 'ahead'}';
}

const _label = TextStyle(color: K.muted, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2);

/// A rounded surface with a small caps [header] row.
Widget panel({required Widget header, required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) =>
    Container(
      padding: padding,
      decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DefaultTextStyle.merge(style: _label, child: header),
        const SizedBox(height: 10),
        child,
      ]),
    );

/// SONG / SET / KEY card: a value, then a progress bar ([bar] 0..1) or a small line of text.
Widget statCard(String label, String value, {double? bar, Widget? sub}) => panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      header: Text(label),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, fontFeatures: K.tabular)),
        const SizedBox(height: 8),
        if (bar != null)
          LinearProgressIndicator(
              value: bar.clamp(0.0, 1.0),
              minHeight: 6,
              color: K.accent,
              backgroundColor: K.surface2,
              borderRadius: BorderRadius.circular(3))
        else
          sub ?? const SizedBox(height: 6),
      ]),
    );

/// Acts only after a 1 s hold, filling up meanwhile; a tap does nothing (SPEC §5.4: holds, never dialogs).
class HoldButton extends StatefulWidget {
  final IconData icon;
  final String? label;
  final VoidCallback onHeld;
  const HoldButton({super.key, required this.icon, this.label, required this.onHeld});

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))
    ..addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      _c.reset();
      widget.onHeld();
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Listener(
          onPointerDown: (_) => _c.forward(from: 0),
          onPointerUp: (_) => _c.reset(),
          onPointerCancel: (_) => _c.reset(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, child) => Container(
                constraints: const BoxConstraints(minWidth: 72),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    K.accent.withValues(alpha: 0.35),
                    K.accent.withValues(alpha: 0.35),
                    K.surface2,
                    K.surface2,
                  ], stops: [0, _c.value, _c.value, 1]),
                ),
                child: child,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(widget.icon, color: K.text),
                if (widget.label != null) ...[
                  const SizedBox(width: 8),
                  Text(widget.label!, style: const TextStyle(color: K.text, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
          ),
        ),
      );
}
