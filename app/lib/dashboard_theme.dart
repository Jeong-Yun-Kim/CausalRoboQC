import 'package:flutter/material.dart';

import 'metric_help.dart';

/// Shared visual language for the monitoring, control and quality screens.
abstract final class DashboardTheme {
  static const ink = Color(0xff242424);
  static const muted = Color(0xff707070);
  static const primary = Color(0xff353535);
  static const success = Color(0xff43765b);
  static const warning = Color(0xff966b28);
  static const danger = Color(0xffad4545);
  static const background = Color(0xfff7f7f7);
  static const border = Color(0xffe3e3e3);
  static const navy = Color(0xff242424);

  static const radius = 4.0;
  static const sectionSpacing = 24.0;
  static const groupSpacing = 32.0;
  static const cardPadding = 16.0;
  static const controlHeight = 44.0;
  static const dialogWidth = 680.0;
  static const sidebarSelected = Color(0xff3b3b3b);
  static const sidebarMuted = Color(0xffbdbdbd);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(seedColor: primary).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      secondary: primary,
      onSecondary: Colors.white,
      secondaryContainer: border,
      onSecondaryContainer: ink,
      tertiary: primary,
      onTertiary: Colors.white,
      tertiaryContainer: background,
      onTertiaryContainer: ink,
      primaryContainer: const Color(0xffe9e9e9),
      onPrimaryContainer: const Color(0xff353535),
      surface: Colors.white,
      surfaceContainerLowest: const Color(0xfffafafa),
      surfaceContainerLow: background,
      surfaceContainer: const Color(0xfff0f0f0),
      surfaceContainerHigh: const Color(0xffe8e8e8),
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: const Color(0xff969696),
      outlineVariant: border,
      error: danger,
      onError: Colors.white,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return base.copyWith(
      scaffoldBackgroundColor: Colors.white,
      dividerColor: border,
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleMedium: text.titleMedium
            ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
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
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: buttonShape,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: buttonShape,
          side: const BorderSide(color: border),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            shape: buttonShape, minimumSize: const Size(0, controlHeight)),
      ),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
        minimumSize: const Size(controlHeight, controlHeight),
        shape: buttonShape,
      )),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
            color: navy, borderRadius: BorderRadius.circular(radius)),
        textStyle:
            const TextStyle(color: Colors.white, fontSize: 12, height: 1.5),
        padding: const EdgeInsets.all(12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xfffafafa),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: background,
        side: BorderSide.none,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        labelStyle: const TextStyle(fontSize: 12, color: ink),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: Colors.white,
        headerForegroundColor: ink,
        headerHeadlineStyle: text.titleLarge
            ?.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
        shape: buttonShape,
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: const Color(0xffe9e9e9),
        borderRadius: BorderRadius.circular(radius),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 5,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 17),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        selectedTileColor: const Color(0xfff0f0f0),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        titleTextStyle: const TextStyle(
            color: ink, fontSize: 13, fontWeight: FontWeight.w600),
        subtitleTextStyle:
            const TextStyle(color: muted, fontSize: 12, height: 1.5),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: const WidgetStatePropertyAll(background),
        headingRowHeight: 44,
        dataRowMinHeight: 52,
        dataRowMaxHeight: 60,
        headingTextStyle: const TextStyle(
            fontSize: 12, color: muted, fontWeight: FontWeight.w600),
        dataTextStyle: const TextStyle(fontSize: 13, color: ink),
        dividerThickness: 0.7,
        dataRowColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? const Color(0xfff0f0f0)
                : states.contains(WidgetState.hovered)
                    ? const Color(0xfffafafa)
                    : null),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xffe9e9e9),
        indicatorShape: buttonShape,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected) ? primary : muted,
            )),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: navy,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
    );
  }

  static EdgeInsets pagePadding(double width) =>
      EdgeInsets.all(width < 600 ? 16 : 24);
}

class DashboardHeading extends StatelessWidget {
  const DashboardHeading(
      {super.key, required this.title, this.description, this.trailing});
  final String title;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DashboardTheme.sectionSpacing),
        child: LayoutBuilder(builder: (context, constraints) {
          final heading =
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.headlineMedium),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(description!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ]);
          if (trailing == null) {
            return heading;
          }
          if (constraints.maxWidth < 320) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 12), trailing!],
            );
          }
          return Row(children: [
            Expanded(child: heading),
            const SizedBox(width: 16),
            trailing!
          ]);
        }),
      );
}

class DashboardSection extends StatelessWidget {
  const DashboardSection(
      {super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
                child:
                    Text(title, style: Theme.of(context).textTheme.titleLarge)),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ]),
          const Divider(height: DashboardTheme.sectionSpacing),
          child,
        ],
      );
}

class DashboardMetric extends StatelessWidget {
  const DashboardMetric(
      {super.key,
      required this.label,
      required this.value,
      this.icon,
      this.color = DashboardTheme.ink,
      this.note,
      this.helpTerm,
      this.onTap});
  final String label;
  final String value;
  final IconData? icon;
  final Color color;
  final String? note;
  final String? helpTerm;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: DashboardTheme.background,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: DashboardTheme.controlHeight),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                        child: helpTerm == null
                            ? Text(label,
                                style: Theme.of(context).textTheme.bodySmall)
                            : MetricLabel(label,
                                term: helpTerm,
                                style: Theme.of(context).textTheme.bodySmall)),
                    const SizedBox(width: 12),
                    Text(value,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ]),
                  if (note != null) ...[
                    const SizedBox(height: 6),
                    Text(note!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall),
                  ],
                ]),
          ),
        ),
      );
}

class DashboardStatusBadge extends StatelessWidget {
  const DashboardStatusBadge(this.label,
      {super.key, this.color = DashboardTheme.muted, this.helpTerm});
  final String label;
  final Color color;
  final String? helpTerm;

  @override
  Widget build(BuildContext context) {
    final style =
        TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DashboardTheme.radius)),
      child: helpTerm == null
          ? Text(label, style: style)
          : MetricLabel(label, term: helpTerm, style: style),
    );
  }
}

class DashboardEmptyState extends StatelessWidget {
  const DashboardEmptyState(
      {super.key, required this.icon, required this.title, this.description});
  final IconData icon;
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.bodySmall),
              if (description != null) ...[
                const SizedBox(height: 6),
                Text(description!,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
      );
}
