part of 'terminal_widget.dart';

enum _TerminalContextAction {
  copy,
  paste,
  splitRight,
  splitDown,
  newTab,
  search,
  clear,
  selectAll,
  close,
  settings,
}

const double _terminalContextMenuWidth = 214;

String? _terminalEditingShortcutLabel(String shortcut) {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return formatShortcutForPlatform(shortcut);
  }
  return formatTerminalEditingShortcutForPlatform(shortcut);
}

List<NautermContextMenuEntry<_TerminalContextAction>> _terminalContextMenuRows(
  TerminalShortcutConfig shortcuts,
) => [
  NautermContextMenuAction(
    value: _TerminalContextAction.copy,
    icon: LucideIcons.copy,
    label: 'Copy',
    shortcut: _terminalEditingShortcutLabel(shortcuts.copy),
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.paste,
    icon: LucideIcons.clipboardPaste,
    label: 'Paste',
    shortcut: _terminalEditingShortcutLabel(shortcuts.paste),
  ),
  NautermContextMenuDivider(),
  NautermContextMenuAction(
    value: _TerminalContextAction.splitRight,
    icon: LucideIcons.squareSplitHorizontal,
    label: 'Split Right',
    shortcut: formatShortcutForPlatform(shortcuts.splitRight),
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.splitDown,
    icon: LucideIcons.squareSplitVertical,
    label: 'Split Down',
    shortcut: formatShortcutForPlatform(shortcuts.splitDown),
  ),
  NautermContextMenuDivider(),
  NautermContextMenuAction(
    value: _TerminalContextAction.newTab,
    icon: LucideIcons.squarePlus,
    label: 'New Tab',
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.search,
    icon: LucideIcons.search,
    label: 'Search',
    shortcut: _terminalEditingShortcutLabel(shortcuts.search),
  ),
  NautermContextMenuDivider(),
  NautermContextMenuAction(
    value: _TerminalContextAction.clear,
    icon: LucideIcons.eraser,
    label: 'Clear',
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.selectAll,
    icon: LucideIcons.listChecks,
    label: 'Select All',
    shortcut: _terminalEditingShortcutLabel(shortcuts.selectAll),
  ),
  NautermContextMenuDivider(),
  NautermContextMenuAction(
    value: _TerminalContextAction.settings,
    icon: LucideIcons.settings,
    label: 'Settings',
    shortcut: formatShortcutForPlatform(shortcuts.openSettings),
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.close,
    icon: LucideIcons.x,
    label: 'Close',
    shortcut: formatShortcutForPlatform(shortcuts.closeTab),
    destructive: true,
  ),
];

List<NautermContextMenuEntry<_TerminalContextAction>>
_readOnlyTerminalContextMenuRows(TerminalShortcutConfig shortcuts) => [
  NautermContextMenuAction(
    value: _TerminalContextAction.copy,
    icon: LucideIcons.copy,
    label: 'Copy',
    shortcut: _terminalEditingShortcutLabel(shortcuts.copy),
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.search,
    icon: LucideIcons.search,
    label: 'Search',
    shortcut: _terminalEditingShortcutLabel(shortcuts.search),
  ),
  NautermContextMenuAction(
    value: _TerminalContextAction.selectAll,
    icon: LucideIcons.listChecks,
    label: 'Select All',
    shortcut: _terminalEditingShortcutLabel(shortcuts.selectAll),
  ),
];

List<NautermContextMenuEntry<_TerminalContextAction>>
_visibleTerminalContextMenuRows({
  required bool newTabEnabled,
  required bool readOnly,
  required TerminalShortcutConfig shortcuts,
}) {
  if (readOnly) return _readOnlyTerminalContextMenuRows(shortcuts);
  final rows = _terminalContextMenuRows(shortcuts);
  if (newTabEnabled) {
    return rows;
  }
  return [
    for (final row in rows)
      if (row is! NautermContextMenuAction<_TerminalContextAction> ||
          row.value != _TerminalContextAction.newTab)
        row,
  ];
}

class _TerminalContextMenuOverlay extends StatelessWidget {
  const _TerminalContextMenuOverlay({
    required this.position,
    required this.newTabEnabled,
    required this.readOnly,
    required this.onDismissed,
    required this.onAction,
    required this.theme,
  });

  final Offset position;
  final bool newTabEnabled;
  final bool readOnly;
  final VoidCallback onDismissed;
  final ValueChanged<_TerminalContextAction> onAction;
  final TerminalTheme theme;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = nautermTransientOverlaySafePadding(
      context,
      base: MediaQuery.paddingOf(context),
    );
    final rows = _visibleTerminalContextMenuRows(
      newTabEnabled: newTabEnabled,
      readOnly: readOnly,
      shortcuts: terminalShortcutConfig,
    );
    final contentHeight = nautermContextMenuHeight(rows);
    final menuHeight = math.min(
      contentHeight,
      math.max(0.0, size.height - padding.vertical - 16),
    );
    final preferredRect = nautermContextMenuRect(
      anchor: position,
      overlaySize: size,
      menuSize: Size(_terminalContextMenuWidth, menuHeight),
      safePadding: padding,
    );
    final rect = positionNautermTransientOverlay(
      context: context,
      preferredRect: preferredRect,
      overlaySize: size,
      safePadding: padding,
    );

    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: TapRegion(
            onTapOutside: (_) => onDismissed(),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: nautermContextMenuAnimationDuration,
              curve: Curves.easeOutCubic,
              builder: (context, value, child) =>
                  Opacity(opacity: value, child: child),
              child: NautermContextMenu<_TerminalContextAction>(
                entries: rows,
                width: _terminalContextMenuWidth,
                height: menuHeight < contentHeight ? menuHeight : null,
                style: _terminalContextMenuStyle(theme),
                showScrollbarOnHover: menuHeight < contentHeight,
                onSelected: onAction,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

NautermContextMenuStyle _terminalContextMenuStyle(TerminalTheme theme) {
  final canvas = theme.primary.background;
  final foreground = theme.primary.foreground;
  final dark = theme.type == TerminalThemeType.dark;
  final background = Color.lerp(canvas, foreground, dark ? 0.035 : 0.04)!;
  final inputBackground = Color.lerp(canvas, foreground, dark ? 0.075 : 0.07)!;
  return NautermContextMenuStyle(
    background: background,
    foreground: foreground,
    mutedForeground: Color.lerp(background, foreground, 0.58)!,
    disabledForeground: foreground.withValues(alpha: 0.30),
    border: Color.lerp(canvas, foreground, dark ? 0.13 : 0.11)!,
    hoverBackground: inputBackground,
    accent: theme.primary.accent,
    shadows: [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.28 : 0.14),
        blurRadius: 16,
        spreadRadius: -4,
        offset: const Offset(0, 6),
      ),
    ],
  );
}
