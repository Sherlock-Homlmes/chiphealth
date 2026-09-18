import 'package:chiphealth/features/training/route_map.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes the reference Google polyline', () {
    final points = decodePolyline(r'_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(points, hasLength(3));
    expect(points[0].latitude, closeTo(38.5, 1e-6));
    expect(points[0].longitude, closeTo(-120.2, 1e-6));
    expect(points[2].latitude, closeTo(43.252, 1e-6));
    expect(points[2].longitude, closeTo(-126.453, 1e-6));
  });

  test('empty or null polyline yields no points', () {
    expect(decodePolyline(null), isEmpty);
    expect(decodePolyline(''), isEmpty);
  });
}
