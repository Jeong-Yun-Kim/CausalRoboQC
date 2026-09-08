import 'package:flutter/material.dart';

import 'metric_help.dart';

/// Shared visual language for the monitoring, control and quality screens.
abstract final class DashboardTheme {
  static const ink = Color(0xff172b3a);
  static const muted = Color(0xff697b88);
  static const primary = Color(0xff087f8c);
  static const success = Color(0xff21866b);
  static const warning = Color(0xffb77817);
  static const danger = Color(0xffcf4856);
  static const background = Color(0xfff3f6f8);
  static const border = Color(0xffe3e9ee);
  static const navy = Color(0xff132b3a);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(seedColor: primary).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xffe0f2f2),
      onPrimaryContainer: const Color(0xff08636c),
      surface: Colors.white,
      surfaceContainerLowest: const Color(0xfff8fafb),
      surfaceContainerLow: background,
      surfaceContainer: const Color(0xffeef3f6),
      surfaceContainerHigh: const Color(0xffe7eef2),
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: const Color(0xff8b9ca8),
      outlineVariant: border,
      error: danger,
      onError: Colors.white,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      dividerColor: border,
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 13, height: 1.5),
        bodySmall: text.bodySmall?.copyWith(color: muted, height: 1.5),
        labelSmall: text.labelSmall?.copyWith(color: muted, fontSize: 11),
        labelMedium: text.labelMedium?.copyWith(color: muted, fontSize: 12),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: buttonShape,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: buttonShape,
          side: const BorderSide(color: border),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShape),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xfff8fafb),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: background,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: const TextStyle(fontSize: 12, color: ink),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: const Color(0xffe8eff2),
        borderRadius: BorderRadius.circular(6),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 5,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 17),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        selectedTileColor: const Color(0xffeaf5f5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: const TextStyle(
            color: ink, fontSize: 13, fontWeight: FontWeight.w600),
        subtitleTextStyle:
            const TextStyle(color: muted, fontSize: 12, height: 1.5),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: const WidgetStatePropertyAll(background),
        headingRowHeight: 48,
        dividerThickness: 0.7,
        dataRowColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? const Color(0xffeaf5f5)
                : null),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xffe0f2f2),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected) ? primary : muted,
            )),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: navy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static EdgeInsets pagePadding(double width) =>
      EdgeInsets.all(width < 600 ? 16 : 28);

  static BoxDecoration get bannerDecoration => BoxDecoration(
        gradient: const LinearGradient(
          colors: [navy, Color(0xff1d4453)],
          begin: Alignment.centerLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      );
}

class DashboardHeading extends StatelessWidget {
  const DashboardHeading(
      {super.key,
      required this.eyebrow,
      required this.title,
      required this.description,
      this.trailing});

  final String eyebrow;
  final String title;
  final String description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(eyebrow,
            style: const TextStyle(
                color: DashboardTheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.8)),
        const SizedBox(height: 7),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 5),
        Text(description, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: LayoutBuilder(builder: (context, constraints) {
        if (trailing == null) return text;
        if (constraints.maxWidth < 620) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 12), trailing!]);
        }
        return Row(children: [
          Expanded(child: text),
          const SizedBox(width: 20),
          trailing!
        ]);
      }),
    );
  }
}

class DashboardSection extends StatelessWidget {
  const DashboardSection(
      {super.key, required this.title, required this.child, this.icon});

  final String title;
  final Widget child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Card(
        semanticContainer: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                if (icon != null) ...[
                  Icon(icon, color: DashboardTheme.primary, size: 19),
                  const SizedBox(width: 9),
                ],
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleLarge)),
              ]),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      );
}

class DashboardMetric extends StatelessWidget {
  const DashboardMetric(
      {super.key,
      required this.label,
      required this.value,
      required this.icon,
      this.color = DashboardTheme.primary,
      this.note,
      this.helpTerm,
      this.onTap});

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? note;
  final String? helpTerm;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: color.withValues(alpha: 0.04),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, size: 19, color: color),
                  ),
                  const Spacer(),
                  if (onTap != null)
                    const Icon(Icons.north_east,
                        size: 15, color: DashboardTheme.muted),
                ]),
                const SizedBox(height: 16),
                if (helpTerm == null)
                  Text(label, style: Theme.of(context).textTheme.labelMedium)
                else
                  MetricLabel(label, term: helpTerm,
                      style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 5),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontSize: 27)),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Text(note ?? '',
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              ],
            ),
          ),
        ),
      );
}

class DashboardEmptyState extends StatelessWidget {
  const DashboardEmptyState(
      {super.key, required this.icon, required this.title, this.description});

  final IconData icon;
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: DashboardTheme.background,
                  borderRadius: BorderRadius.circular(18)),
              child: Icon(icon, size: 28, color: DashboardTheme.muted),
            ),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall),
            if (description != null) ...[
              const SizedBox(height: 6),
              Text(description!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ]),
        ),
      );
}
