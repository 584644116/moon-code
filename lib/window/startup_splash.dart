import 'package:flutter/material.dart';

import '../icons/brand_logos.dart';
import '../theme/app_theme.dart';

/// How long the mark takes to settle in.
const _popDuration = Duration(milliseconds: 720);

/// How long the workbench takes to come through it.
const _revealDuration = Duration(milliseconds: 160);

/// The mark pops in fast and settles slowly — the ease-out ZCode starts
/// with, its long tail what makes it feel unhurried at the end.
const _popCurve = Cubic(0.22, 1, 0.36, 1);

/// The app's start: [child] behind the mark, which pops in on its tile and
/// then lets [child] come through — as ZCode opens, and as this app did not
/// until now: it simply appeared.
///
/// The pop overshoots and comes back (see [_popScale]), on the one easing
/// curve the whole of it shares, then both it and the workbench fade over
/// [_revealDuration], the workbench already laid out behind it: nothing is
/// waited for, and nothing jumps when the splash goes.
class StartupSplash extends StatefulWidget {
  const StartupSplash({super.key, required this.child});

  /// What the splash covers: the window's app.
  final Widget child;

  /// Whether the start has played: once for the app, in the window that
  /// shows first. A window opened later (one of the IDE's, one restored)
  /// shows nothing of it. A test sets it back to false.
  @visibleForTesting
  static bool played = false;

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash>
    with TickerProviderStateMixin {
  /// Whether this window is the one the start plays in.
  late final bool _showing = !StartupSplash.played;

  /// Whether the start is over and only [StartupSplash.child] is left.
  bool _done = false;

  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: _popDuration,
  );
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: _revealDuration,
  );

  /// 0.72 → 1.045 → 0.985 → 1.008 → 1: out past its size, then back, by
  /// less each time, until it is its size. The weights are the frames of
  /// ZCode's `startup-logo-pop`.
  static final Animatable<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: .72, end: 1.045).chain(CurveTween(curve: _popCurve)),
      weight: 38,
    ),
    TweenSequenceItem(tween: Tween(begin: 1.045, end: .985), weight: 20),
    TweenSequenceItem(tween: Tween(begin: .985, end: 1.008), weight: 18),
    TweenSequenceItem(tween: Tween(begin: 1.008, end: 1), weight: 24),
  ]);

  /// In by its 38th percent, while it is still growing: it is seen arriving,
  /// not faded in place.
  static final Animatable<double> _popOpacity = CurveTween(
    curve: const Interval(0, .38, curve: Curves.easeOut),
  );

  late final Animation<double> _scale = _popScale.animate(_pop);
  late final Animation<double> _opacity = _popOpacity.animate(_pop);

  @override
  void initState() {
    super.initState();
    if (!_showing) {
      _done = true;
      return;
    }
    StartupSplash.played = true;
    _pop.addStatusListener((status) {
      if (status == AnimationStatus.completed) _reveal.forward();
    });
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted && !_done) {
        setState(() => _done = true);
      }
    });
    _pop.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Motion turned down: the workbench at once, as it was before the start
    // was animated at all.
    if (_showing && !_done && MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _pop.stop();
      _done = true;
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Laid out from the first frame, so nothing jumps when it comes
        // through, but not drawn until then: a sidebar's tint alone would
        // let the workbench show through the splash.
        ExcludeSemantics(child: FadeTransition(opacity: _reveal, child: widget.child)),
        FadeTransition(
          opacity: ReverseAnimation(_reveal),
          child: ColoredBox(
            color: AppColors.background,
            child: Center(
              child: FadeTransition(
                opacity: _opacity,
                child: ScaleTransition(scale: _scale, child: const _Mark()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The mark on its tile: a dark square, rounded as the app's icons are,
/// with BaoCode's logo in white — the same in every theme, as ZCode's is,
/// so the start looks the same whatever the workbench comes up as.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF000000), Color(0xFF151718)],
        ),
        borderRadius: BorderRadius.circular(24),
        // Its own edge: the tile is dark in every theme, so the border is
        // too, and not the theme's.
        border: Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            offset: Offset(0, 20),
            blurRadius: 25,
            spreadRadius: -5,
          ),
          BoxShadow(
            color: Color(0x33000000),
            offset: Offset(0, 8),
            blurRadius: 10,
            spreadRadius: -6,
          ),
        ],
      ),
      child: const SizedBox.square(
        dimension: 96,
        child: Center(
          child: BaoCodeLogo(size: 56, color: Colors.white),
        ),
      ),
    );
  }
}
