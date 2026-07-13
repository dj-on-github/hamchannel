# Builds the HamChannel command-line tools (hc_info, hc_gen).
#
# The tools link against the main application's modulation, demodulation
# and error correction code (lib/dsp, lib/fec, lib/modem, lib/proto), which
# is pure Dart, so `dart compile exe` produces self-contained native
# executables.
#
# The dart/flutter binaries are found on PATH by default; override with
#   make DART=$(HOME)/flutter-sdk/flutter/bin/dart \
#        FLUTTER=$(HOME)/flutter-sdk/flutter/bin/flutter

DART    ?= dart
FLUTTER ?= flutter

ROOT := ../..

APP_SRCS := $(shell find $(ROOT)/lib -name '*.dart')

all: ../hc_info ../hc_gen

../hc_info: hc_info.dart $(APP_SRCS) $(ROOT)/pubspec.yaml
	cd $(ROOT) && $(FLUTTER) pub get
	cd $(ROOT) && $(DART) compile exe tools/src/hc_info.dart -o tools/hc_info

../hc_gen: hc_gen.dart $(APP_SRCS) $(ROOT)/pubspec.yaml
	cd $(ROOT) && $(FLUTTER) pub get
	cd $(ROOT) && $(DART) compile exe tools/src/hc_gen.dart -o tools/hc_gen

clean:
	rm -f ../hc_info ../hc_gen

.PHONY: all clean
