/// CRC-32 (IEEE 802.3, reflected) and CRC-16/CCITT-FALSE.
library;

import 'dart:typed_data';

final Uint32List _crc32Table = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    t[i] = c;
  }
  return t;
}();

int crc32(Uint8List data, [int start = 0, int? end]) {
  end ??= data.length;
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crc32Table[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int crc16(Uint8List data, [int start = 0, int? end]) {
  end ??= data.length;
  var crc = 0xFFFF;
  for (var i = start; i < end; i++) {
    crc ^= data[i] << 8;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}
