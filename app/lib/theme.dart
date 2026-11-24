import 'package:flutter/material.dart';

import 'library.dart';

/// Design tokens from design/stage_ready_karaoke_manager/DESIGN.md.
abstract final class K {
  static const bg = Color(0xFF111317);
  static const surface1 = Color(0xFF1A1D24);
  static const surface2 = Color(0xFF232730);
  static const text = Color(0xFFF3F4F6);
  static const muted = Color(0xFF9CA3AF);
  static const accent = Color(0xFFF59E0B);
  static const border = Color(0x14FFFFFF); // white 8%
  static const divider = Color(0x0FFFFFFF); // white 6%

  static const fallback = ['NotoSansDevanagari'];
  static const tabular = [FontFeature.tabularFigures()];

  static Color status(SongStatus s) => switch (s) {
        SongStatus.ready => const Color(0xFF10B981),
        SongStatus.needsSync => accent,
        SongStatus.needsLyrics => const Color(0xFFF43F5E),
        SongStatus.processing => const Color(0xFF64748B),
      };

  static String statusLabel(SongStatus s) => switch (s) {
        SongStatus.ready => 'Ready',
        SongStatus.needsSync => 'Needs sync',
        SongStatus.needsLyrics => 'Needs lyrics',
        SongStatus.processing => 'Processing',
      };

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'NotoSans',
      fontFamilyFallback: fallback,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        onPrimary: bg,
        surface: bg,
        onSurface: text,
        surfaceContainer: surface1,
        surfaceContainerHigh: surface2,
        outline: border,
      ),
      dividerColor: divider,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: bg,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: accent)),
        hintStyle: TextStyle(color: muted),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'NotoSans'),
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final SongStatus status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = K.status(status);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(K.statusLabel(status), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
