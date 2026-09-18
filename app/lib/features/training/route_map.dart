import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/tokens.dart';

/// Route line colour — the one thing on the map that should pop.
const routeColor = RetroTokens.accent;

/// Google Encoded Polyline Algorithm Format, the inverse of the backend's
/// `encodePolyline` (services/workoutStream.ts).
List<LatLng> decodePolyline(String? encoded, {int precision = 5}) {
  if (encoded == null || encoded.isEmpty) return const [];
  final factor = 1 / _pow10(precision);
  final out = <LatLng>[];
  var i = 0;
  var lat = 0;
  var lng = 0;

  int next() {
    var shift = 0;
    var result = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(i++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && i < encoded.length);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (i < encoded.length) {
    lat += next();
    if (i >= encoded.length) break;
    lng += next();
    out.add(LatLng(lat * factor, lng * factor));
  }
  return out;
}

double _pow10(int n) {
  var v = 1.0;
  for (var k = 0; k < n; k++) {
    v *= 10;
  }
  return v;
}

/// CARTO Positron: a quiet grey basemap, free and keyless, so the orange route
/// is what the eye lands on.
Widget routeTileLayer(BuildContext context) => TileLayer(
  urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
  subdomains: const ['a', 'b', 'c', 'd'],
  retinaMode: RetinaMode.isHighDensity(context),
  userAgentPackageName: 'app.chiphealth',
  maxZoom: 20,
);

const _attribution = SimpleAttributionWidget(
  source: Text('© OpenStreetMap © CARTO', style: TextStyle(fontSize: 10)),
  backgroundColor: Color(0xB3FFFFFF),
);

List<Polyline> routePolylines(List<LatLng> points) => [
  Polyline(
    points: points,
    color: routeColor,
    strokeWidth: 4,
    borderColor: Colors.white,
    borderStrokeWidth: 1.5,
  ),
];

List<Marker> routeEndpoints(List<LatLng> points) => [
  if (points.isNotEmpty) _dot(points.first, RetroTokens.ok),
  if (points.length > 1) _dot(points.last, RetroTokens.ink),
];

Marker _dot(LatLng at, Color color) => Marker(
  point: at,
  width: 14,
  height: 14,
  child: DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
    ),
  ),
);

/// A finished route, framed to fit. Static for feed cards (taps fall through
/// to the card), pannable on the detail screen.
class RouteMap extends StatelessWidget {
  const RouteMap({super.key, required this.points, this.interactive = false});

  final List<LatLng> points;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final map = FlutterMap(
      options: MapOptions(
        initialCenter: points.first,
        initialZoom: 15,
        initialCameraFit: points.length > 1
            ? CameraFit.coordinates(
                coordinates: points,
                padding: const EdgeInsets.all(28),
                maxZoom: 17,
              )
            : null,
        interactionOptions: InteractionOptions(
          flags: interactive
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.none,
        ),
      ),
      children: [
        routeTileLayer(context),
        PolylineLayer(polylines: routePolylines(points)),
        MarkerLayer(markers: routeEndpoints(points)),
        _attribution,
      ],
    );
    // A non-interactive map still swallows taps; let the card's onTap win.
    return interactive ? map : IgnorePointer(child: map);
  }
}

/// Map shown while recording: follows the newest fix and draws the route so
/// far. [center] is the latest position (may come before any route point).
class LiveRouteMap extends StatefulWidget {
  const LiveRouteMap({super.key, required this.points, required this.center});

  final List<LatLng> points;
  final LatLng center;

  @override
  State<LiveRouteMap> createState() => _LiveRouteMapState();
}

class _LiveRouteMapState extends State<LiveRouteMap> {
  final _controller = MapController();
  bool _ready = false;

  /// Stop following once the user pans; the button brings it back.
  bool _follow = true;

  @override
  void didUpdateWidget(LiveRouteMap old) {
    super.didUpdateWidget(old);
    if (_ready && _follow && old.center != widget.center) {
      _controller.move(widget.center, _controller.camera.zoom);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.center,
            initialZoom: 16,
            onMapReady: () => _ready = true,
            onPositionChanged: (_, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            routeTileLayer(context),
            if (widget.points.length > 1)
              PolylineLayer(polylines: routePolylines(widget.points)),
            MarkerLayer(
              markers: [
                if (widget.points.isNotEmpty)
                  _dot(widget.points.first, RetroTokens.ok),
                Marker(
                  point: widget.center,
                  width: 22,
                  height: 22,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: RetroTokens.info,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Color(0x40000000), blurRadius: 6),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            _attribution,
          ],
        ),
        if (!_follow)
          Positioned(
            right: 12,
            top: 12,
            child: FloatingActionButton.small(
              heroTag: null,
              backgroundColor: Colors.white,
              foregroundColor: RetroTokens.info,
              onPressed: () {
                setState(() => _follow = true);
                if (_ready) {
                  _controller.move(widget.center, _controller.camera.zoom);
                }
              },
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }
}
