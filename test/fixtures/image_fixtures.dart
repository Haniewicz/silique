import 'dart:typed_data';

Uint8List sampleBmp({int width = 1024, int height = 400}) {
  final size = 54 + width * height * 3;
  final bytes = Uint8List(size);
  final view = ByteData.sublistView(bytes);
  bytes[0] = 66;
  bytes[1] = 77;
  view.setUint32(2, size, Endian.little);
  view.setUint32(10, 54, Endian.little);
  view.setUint32(14, 40, Endian.little);
  view.setInt32(18, width, Endian.little);
  view.setInt32(22, height, Endian.little);
  view.setUint16(26, 1, Endian.little);
  view.setUint16(28, 24, Endian.little);
  for (var i = 54; i < size; i++) {
    bytes[i] = i % 251;
  }
  return bytes;
}
