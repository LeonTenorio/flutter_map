import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

part 'marker.dart';

/// A [Marker] layer for [FlutterMap].
@immutable
class MarkerLayer extends StatefulWidget {
  /// The list of [Marker]s.
  final List<Marker> markers;

  /// Alignment of each marker relative to its normal center at [Marker.point]
  ///
  /// For example, [Alignment.topCenter] will mean the entire marker widget is
  /// located above the [Marker.point].
  ///
  /// The center of rotation (anchor) will be opposite this.
  ///
  /// Defaults to [Alignment.center]. Overriden by [Marker.alignment] if set.
  final Alignment alignment;

  /// Whether to counter rotate markers to the map's rotation, to keep a fixed
  /// orientation
  ///
  /// When `true`, markers will always appear upright and vertical from the
  /// user's perspective. Defaults to `false`. Overriden by [Marker.rotate].
  ///
  /// Note that this is not used to apply a custom rotation in degrees to the
  /// markers. Use a widget inside [Marker.child] to perform this.
  final bool rotate;

  /// Whether to use a single meters to pixels conversion ratio for all markers
  /// with [Marker.useDimensionsInMeters] enabled.
  ///
  /// > [!IMPORTANT]
  /// > This reduces the accuracy of the dimensions of markers. Depending on the
  /// > location of the markers, this may or may not be significant.
  ///
  /// Where all markers within this layer are geographically (particularly
  /// latitudinally) close, the difference in the ratio between pixels and
  /// meters between markers is likely to be small. Calculating this conversion
  /// ratio is expensive, and is usually done for every marker to ensure
  /// accuracy, as the ratio depends on the latitude. Setting this `true` means
  /// the ratio is calculated based off the first marker only, then reused for
  /// all other markers within this layer.
  ///
  /// This should not be used where markers are geographically spread out - it
  /// is best suited, for example, for markers located within a single city.
  ///
  /// Defaults to `false`.
  final bool optimizeDimensionsInMeters;

  /// Create a new [MarkerLayer] to use inside of [FlutterMap.children].
  const MarkerLayer({
    super.key,
    required this.markers,
    this.alignment = Alignment.center,
    this.rotate = false,
    this.optimizeDimensionsInMeters = false,
  });

  @override
  State<MarkerLayer> createState() => _MarkerLayerState();
}

class _MarkerLayerState extends State<MarkerLayer> {
  static const _distance = Distance();

  /// Projected (zoom-independent) coordinates of every [Marker.point], in the
  /// same order as the markers list
  ///
  /// Projecting a point is relatively expensive (it involves trigonometry),
  /// but only depends on the CRS - not on the camera position or zoom. Caching
  /// it means each camera movement only costs the cheap linear
  /// projected -> screen transformation per marker, instead of a full
  /// re-projection.
  List<Offset>? _projectedPoints;
  Map<int, (Offset, Offset)>? _projectedMeterSizes;
  Crs? _projectionCrs;

  // Cached number of pixels per meter.
  double? _pixelsPerMeter;

  @override
  void didUpdateWidget(MarkerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Matches the invalidation convention of the polyline/polygon layers: any
    // new widget instance re-projects, so in-place mutations of the markers
    // list keep working as they did when projection was performed per-frame.
    _projectedPoints = null;
    _projectedMeterSizes = null;
  }

  List<Offset> _projectPoints(Crs crs) {
    final projection = crs.projection;
    return List<Offset>.generate(
      widget.markers.length,
      (i) {
        final point = widget.markers[i].point;
        // Guard against memory leaks (see
        // https://github.com/fleaflet/flutter_map/issues/2178)
        if (!(point.latitude.isFinite && point.longitude.isFinite)) {
          throw RangeError('All markers must have finite `point`s');
        }
        return projection.project(point);
      },
      growable: false,
    );
  }

  Map<int, (Offset, Offset)> _projectMeterSizes(Crs crs) {
    final projection = crs.projection;
    return Map.fromEntries(
      () sync* {
        for (int i = 0; i < widget.markers.length; i++) {
          final m = widget.markers[i];
          if (m.useDimensionsInMeters == null) continue;

          final w =
              projection.project(_distance.offset(m.point, m.width / 2, 180));
          if (m.width == m.height) yield MapEntry(i, (w, w));
          yield MapEntry(
            i,
            (
              w,
              projection.project(_distance.offset(m.point, m.height / 2, 180)),
            ),
          );

          if (widget.optimizeDimensionsInMeters) break;
        }
      }(),
    );
  }

  Size _getSizeInPixels(Marker m, int i, Offset pxPoint, double zoomScale) {
    final constraints = m.useDimensionsInMeters;
    if (constraints == null) return Size(m.width, m.height);
    if (!constraints.minWidth.isFinite || !constraints.minHeight.isFinite) {
      throw RangeError(
        '`Marker.useDimensionsInMeters` must have finite minimums',
      );
    }

    // Marker dimensions are now in meters and constraints are valid

    final camera = MapCamera.of(context);
    Size metersToScreenPixels(int i) {
      final p = _projectedMeterSizes![i]!;

      final (wpx, wpy) = camera.crs.transform(p.$1.dx, p.$1.dy, zoomScale);
      final width = 2 * (pxPoint - Offset(wpx, wpy)).distance;
      if (m.width == m.height) return Size(width, width);
      final (hpx, hpy) = camera.crs.transform(p.$2.dx, p.$2.dy, zoomScale);
      return Size(
        width,
        2 * (pxPoint - Offset(hpx, hpy)).distance,
      );
    }

    if (!widget.optimizeDimensionsInMeters) {
      return constraints.constrain(metersToScreenPixels(i));
    }
    // If optimizing, use the cached ratio if available, or calculate it
    // (using the first marker in the layer, given how this method is called)
    _pixelsPerMeter ??= metersToScreenPixels(i).width / m.width;
    return constraints.constrainDimensions(
      _pixelsPerMeter! * m.width,
      _pixelsPerMeter! * m.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final map = MapCamera.of(context);

    if (_projectedPoints == null ||
        _projectedMeterSizes == null ||
        _projectionCrs != map.crs) {
      _projectionCrs = map.crs;
      _projectedPoints = _projectPoints(map.crs);
      _projectedMeterSizes = _projectMeterSizes(map.crs);
    }
    _pixelsPerMeter = null;

    final worldWidth = map.getWorldWidthAtZoom();
    final zoomScale = map.crs.scale(map.zoom);

    return MobileLayerTransformer(
      child: Stack(
        children: () sync* {
          for (int i = 0; i < widget.markers.length; i++) {
            final m = widget.markers[i];

            // Scale the cached projection to the current zoom
            final projected = _projectedPoints![i];
            final (px, py) =
                map.crs.transform(projected.dx, projected.dy, zoomScale);
            final pxPoint = Offset(px, py);

            // Resolve real size and alignment
            final size = _getSizeInPixels(m, i, pxPoint, zoomScale);
            final alignment = m.alignment ?? widget.alignment;
            final left = 0.5 * size.width * (alignment.x + 1);
            final top = 0.5 * size.height * (alignment.y + 1);
            final right = size.width - left;
            final bottom = size.height - top;

            Positioned? getPositioned(double worldShift) {
              final shiftedX = pxPoint.dx + worldShift;

              // Cull if out of bounds
              if (!map.pixelBounds.overlaps(
                Rect.fromPoints(
                  Offset(shiftedX + left, pxPoint.dy - bottom),
                  Offset(shiftedX - right, pxPoint.dy + top),
                ),
              )) {
                return null;
              }

              // Shift original coordinate along worlds, then move into relative
              // to origin space
              final shiftedLocalPoint =
                  Offset(shiftedX, pxPoint.dy) - map.pixelOrigin;

              return Positioned(
                key: m.key,
                width: size.width,
                height: size.height,
                left: shiftedLocalPoint.dx - right,
                top: shiftedLocalPoint.dy - bottom,
                child: (m.rotate ?? widget.rotate)
                    ? Transform.rotate(
                        angle: -map.rotationRad,
                        alignment: Alignment(-alignment.x, -alignment.y),
                        child: m.child,
                      )
                    : m.child,
              );
            }

            // Create marker in main world, unless culled
            final main = getPositioned(0);
            if (main != null) yield main;
            // It is unsafe to assume that if the main one is culled, it will
            // also be culled in all other worlds, so we must continue

            // TODO: optimization - find a way to skip these tests in some
            // obvious situations. Imagine we're in a map smaller than the
            // world, and west lower than east - in that case we probably don't
            // need to check eastern and western.

            // Repeat over all worlds (<--||-->) until culling determines that
            // that marker is out of view, and therefore all further markers in
            // that direction will also be
            if (worldWidth == 0) continue;
            for (double shift = -worldWidth;; shift -= worldWidth) {
              final additional = getPositioned(shift);
              if (additional == null) break;
              yield additional;
            }
            for (double shift = worldWidth;; shift += worldWidth) {
              final additional = getPositioned(shift);
              if (additional == null) break;
              yield additional;
            }
          }
        }()
            .toList(),
      ),
    );
  }
}
