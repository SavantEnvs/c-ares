#!/usr/bin/env bash
#
# mayhem/build.sh — build c-ares' two OSS-Fuzz harnesses (sanitized, libFuzzer + standalone) and its
# own GoogleTest suite (arestest, normal flags). Runs in the commit image as `mayhem` in /mayhem; the
# image carries libgtest-dev/libgmock-dev, so a network-less re-run works. Idempotent: build dirs
# are recreated each run. Build dirs live under build/ (gitignored upstream).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# A re-run may use a different compiler path than the image build (ccache pre-fill masquerade vs plain
# clang); cmake then wipes its cache mid-configure and drops the arestest target. Start from scratch.
rm -rf build/fuzz build/tests

# 1) Sanitized static library. fuzzer-no-link adds SanCov to the library itself (without it Mayhem
#    sees 0 edges: $LIB_FUZZING_ENGINE only instruments the harness TU).
cmake -S . -B build/fuzz -DCMAKE_C_COMPILER="$CC" \
  -DCARES_STATIC=ON -DCARES_SHARED=OFF -DCARES_BUILD_TESTS=OFF -DCARES_BUILD_TOOLS=OFF \
  -DCMAKE_C_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake --build build/fuzz -j"$MAYHEM_JOBS"

# 2) Harnesses (upstream's own test/ares-test-fuzz*.c), each twice: libFuzzer + standalone reproducer.
INC=(-DHAVE_CONFIG_H=1 -I build/fuzz -I build/fuzz/src/lib -I "$SRC" -I src/lib -I src/lib/include -I include)
CFLAGS_FUZZ="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS"
LIB=build/fuzz/lib/libcares.a
[ -f "$LIB" ] || LIB="$(find build/fuzz -name 'libcares*.a' | head -n1)"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/fuzz/lsan_off.o

build_harness() {  # <binary name> <source>
  local name="$1" src="$2"
  $CC $CFLAGS_FUZZ "${INC[@]}" $LIB_FUZZING_ENGINE "$src" build/fuzz/lsan_off.o "$LIB" -o "/mayhem/$name"
  $CC $CFLAGS_FUZZ "${INC[@]}" "$STANDALONE_FUZZ_MAIN" "$src" build/fuzz/lsan_off.o "$LIB" -o "/mayhem/$name-standalone"
}
build_harness ares_parse_reply_fuzzer  test/ares-test-fuzz.c
build_harness ares_create_query_fuzzer test/ares-test-fuzz-name.c

# 3) The project's own suite with NORMAL flags (no sanitizers, no -gdwarf-3), kept apart in build/tests.
cmake -S . -B build/tests -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release -DCARES_STATIC=ON -DCARES_SHARED=OFF -DCARES_BUILD_TESTS=ON -DCARES_BUILD_TOOLS=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS" --target arestest
