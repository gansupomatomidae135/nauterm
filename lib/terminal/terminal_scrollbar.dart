part of 'terminal_widget.dart';

const double _terminalScrollbarMinimumThumbExtent = 28;
const Duration _terminalScrollbarScrollVisibilityDuration = Duration(
  milliseconds: 700,
);

class _TerminalScrollbar extends StatefulWidget {
  const _TerminalScrollbar({
    super.key,
    required this.rows,
    required this.historyLines,
    required this.displayOffset,
    required this.theme,
    required this.onScrollToOffset,
  });

  final int rows;
  final int historyLines;
  final int displayOffset;
  final TerminalTheme theme;
  final ValueChanged<int> onScrollToOffset;

  @override
  State<_TerminalScrollbar> createState() => _TerminalScrollbarState();
}

class _TerminalScrollbarState extends State<_TerminalScrollbar> {
  bool _hovered = false;
  bool _dragging = false;
  bool _scrolling = false;
  double _dragOffset = 0;
  Timer? _scrollVisibilityTimer;

  @override
  void didUpdateWidget(covariant _TerminalScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.displayOffset != widget.displayOffset) {
      _showForScroll();
    }
  }

  @override
  void dispose() {
    _scrollVisibilityTimer?.cancel();
    super.dispose();
  }

  void _showForScroll() {
    _scrollVisibilityTimer?.cancel();
    _scrolling = true;
    _scrollVisibilityTimer = Timer(
      _terminalScrollbarScrollVisibilityDuration,
      () {
        if (mounted) {
          setState(() => _scrolling = false);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackExtent = constraints.maxHeight;
        if (trackExtent <= 0 || widget.historyLines <= 0) {
          return const SizedBox.shrink();
        }

        final totalLines = widget.historyLines + math.max(widget.rows, 1);
        final proportionalExtent =
            trackExtent * math.max(widget.rows, 1) / totalLines;
        final thumbExtent = proportionalExtent
            .clamp(
              math.min(_terminalScrollbarMinimumThumbExtent, trackExtent),
              trackExtent,
            )
            .toDouble();
        final thumbTravel = math.max(0.0, trackExtent - thumbExtent);
        final offset = widget.displayOffset.clamp(0, widget.historyLines);
        final progress = widget.historyLines == 0
            ? 1.0
            : (widget.historyLines - offset) / widget.historyLines;
        final thumbTop = thumbTravel * progress;
        final active = _hovered || _dragging || _scrolling;
        final foreground = widget.theme.primary.foreground;

        void scrollToThumbTop(double value) {
          if (thumbTravel <= 0) {
            return;
          }
          final nextTop = value.clamp(0.0, thumbTravel);
          final nextProgress = nextTop / thumbTravel;
          final nextOffset = (widget.historyLines * (1 - nextProgress)).round();
          widget.onScrollToOffset(nextOffset);
        }

        return MouseRegion(
          key: const ValueKey('terminal-scrollbar-hit-region'),
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) {
              scrollToThumbTop(details.localPosition.dy - thumbExtent / 2);
            },
            onVerticalDragStart: (details) {
              setState(() => _dragging = true);
              final localY = details.localPosition.dy;
              if (localY >= thumbTop && localY <= thumbTop + thumbExtent) {
                _dragOffset = localY - thumbTop;
              } else {
                _dragOffset = thumbExtent / 2;
                scrollToThumbTop(localY - _dragOffset);
              }
            },
            onVerticalDragUpdate: (details) {
              scrollToThumbTop(details.localPosition.dy - _dragOffset);
            },
            onVerticalDragEnd: (_) => setState(() => _dragging = false),
            onVerticalDragCancel: () => setState(() => _dragging = false),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  right: 2,
                  bottom: 0,
                  width: 6,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: foreground.withValues(alpha: active ? 0.08 : 0),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Positioned(
                  top: thumbTop,
                  right: 2,
                  width: 6,
                  height: thumbExtent,
                  child: AnimatedContainer(
                    key: const ValueKey('terminal-scrollbar-thumb'),
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: active
                          ? foreground.withValues(
                              alpha: widget.theme.type == TerminalThemeType.dark
                                  ? 0.62
                                  : 0.52,
                            )
                          : foreground.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
