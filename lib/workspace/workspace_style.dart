part of 'nauterm_workspace.dart';

bool get _workspaceDark {
  return switch (appThemeMode) {
    AppThemeMode.dark => true,
    AppThemeMode.light => false,
    AppThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
  };
}

Color get _topBar =>
    _workspaceDark ? const Color(0xff171d25) : const Color(0xff363c51);
Color get _topBarForeground =>
    _workspaceDark ? const Color(0xffa4b3bd) : const Color(0xffaeb6c8);
Color get _topBarTabActive =>
    _workspaceDark ? const Color(0xff222b35) : const Color(0xff4a5065);
Color get _topBarTabInactive =>
    _workspaceDark ? const Color(0xff1b222b) : const Color(0xff40465b);
Color get _sidebar =>
    _workspaceDark ? const Color(0xff171d25) : const Color(0xfff6f9f9);
Color get _sidebarDivider =>
    _workspaceDark ? const Color(0xff303a46) : const Color(0xffdbe6e8);
Color get _sidebarHover =>
    _workspaceDark ? const Color(0xff222b35) : const Color(0xffedf4f5);
Color get _sidebarPressed =>
    _workspaceDark ? const Color(0xff2c3844) : const Color(0xffc7d5d8);
Color get _surface =>
    _workspaceDark ? const Color(0xff12161c) : const Color(0xffedf3f3);
Color get _card =>
    _workspaceDark ? const Color(0xff1a2028) : const Color(0xffffffff);
Color get _cardHover =>
    _workspaceDark ? const Color(0xff202832) : const Color(0xfffbfdfd);
Color get _mutedText =>
    _workspaceDark ? const Color(0xff8fa0aa) : const Color(0xff8ca0a6);
Color get _text =>
    _workspaceDark ? const Color(0xffedf3f7) : const Color(0xff151927);
Color get _blue =>
    _workspaceDark ? const Color(0xff4da6ff) : const Color(0xff168df2);
Color get _orange =>
    _workspaceDark ? const Color(0xffff7a57) : const Color(0xffff5425);
Color get _green =>
    _workspaceDark ? const Color(0xff35d394) : const Color(0xff35d394);
Color get _topBarDestructiveHover =>
    _workspaceDark ? const Color(0xffe05545) : const Color(0xffe05545);
const double _topBarHeight = 44;
const double _macTrafficLightInset = 76;
const double _linuxWindowControlsEndPadding = 6;
const double _linuxWindowControlsWidth = 108;
const double _sidebarHorizontalInset = 10;
const double _sidebarIconSlotSize = 36;
const double _sidebarIconLabelGap = 10;
const double _sidebarExpandedWidth = 190;
const double _sidebarCollapsedWidth =
    _sidebarHorizontalInset * 2 + _sidebarIconSlotSize;
const double _sidebarCollapseBreakpoint = 760;
const double _sidebarItemHeight = 40;
const double _workspaceToolbarHeight = 48;
const double _workspaceDrawerHeaderHeight = _workspaceToolbarHeight;
const double _workspaceEditorDrawerWidth = 360;
const double _workspaceFormFieldGap = 10;
const EdgeInsets _workspacePanePadding = EdgeInsets.fromLTRB(26, 22, 26, 30);

const double _contextMenuRowHeight = 35;
const double _contextMenuDividerHeight = 13;
const double _contextMenuVerticalPadding = 20;
const double _contextMenuWidth = 286;
const double _contextSubmenuWidth = 190;
const Duration _contextMenuAnimationDuration = Duration(milliseconds: 78);
const Duration _workspacePageTransitionDuration = Duration(milliseconds: 130);
Color get _workspaceMenuBackground =>
    _workspaceDark ? const Color(0xff202832) : const Color(0xffffffff);
Color get _workspaceMenuBorder =>
    _workspaceDark ? const Color(0xff303a46) : const Color(0xffd9e3e6);
Color get _workspaceMenuHover =>
    _workspaceDark ? const Color(0xff293340) : const Color(0xfff0f4f5);
Color get _workspaceMenuPressed =>
    _workspaceDark ? const Color(0xff303c49) : const Color(0xffe9f1f3);
Color get _workspaceMenuDisabledText =>
    _workspaceDark ? const Color(0xff5f707d) : const Color(0xffc2d0d5);
ButtonStyle? get _workspaceIconButtonInteractionStyle => _workspaceDark
    ? IconButton.styleFrom(
        hoverColor: _sidebarHover,
        highlightColor: _workspaceMenuPressed,
      )
    : null;
const double _workspacePopupMenuRowHeight = 34;
const double _workspaceMenuHorizontalInset = 7;
const double _workspaceMenuVerticalInset = 5;
List<BoxShadow> get _workspaceMenuShadows => _workspaceDark
    ? const [
        BoxShadow(
          color: Color(0x66202020),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
        BoxShadow(
          color: Color(0x33202020),
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ]
    : const [
        BoxShadow(
          color: Color(0x1f22313f),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
        BoxShadow(
          color: Color(0x0f22313f),
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ];

double _contextMenuHeightForRows(Iterable<Object> rows) {
  return rows.fold<double>(
    _contextMenuVerticalPadding,
    (height, row) =>
        height +
        (row == _MenuDivider.instance
            ? _contextMenuDividerHeight
            : _contextMenuRowHeight),
  );
}

double _contextMenuTopForRow(List<Object> rows, _ContextMenuAction target) {
  var top = _contextMenuVerticalPadding / 2;
  for (final row in rows) {
    if (row is _ContextMenuAction && _sameContextMenuAction(row, target)) {
      return top;
    }
    top += row == _MenuDivider.instance
        ? _contextMenuDividerHeight
        : _contextMenuRowHeight;
  }
  return _contextMenuVerticalPadding / 2;
}

bool _sameContextMenuAction(
  _ContextMenuAction action,
  _ContextMenuAction other,
) {
  return action.id == other.id &&
      action.label == other.label &&
      action.icon == other.icon &&
      action.shortcut == other.shortcut &&
      action.destructive == other.destructive &&
      action.submenuActions.length == other.submenuActions.length;
}

Color _blend(Color background, Color foreground, double amount) {
  return Color.lerp(background, foreground, amount) ?? background;
}
