#!/usr/bin/env bash
#
# mayhem/build.sh — build stepcode's exp2python (EXPRESS -> Python generator) fuzz target and its
# functional test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) exports the build contract: CC/CXX, SANITIZER_FLAGS (ASan+UBSan,
# halting; already set as an ENV by the base — the `: "${VAR=default}"` lines below are a no-op
# fallback for a bare host run, not something to rely on for overriding), DEBUG_FLAGS
# (-g -gdwarf-3), SRC=/mayhem.
#
# exp2python has no LLVMFuzzerTestOneInput entry point — it is a raw file-input CLI
# (`exp2python <schema.exp>`), so there is no LIB_FUZZING_ENGINE link and no separate
# *-standalone binary: the sanitized CLI binary IS its own run-once reproducer (same pattern as
# semblance's `dump` / neper's `neper`).
#
# WRITABLE-CWD FIX (issue #661 pattern — see mayhem/exp2python_wrapper_main.c for the long form):
# exp2python writes <schema-name>.{py,h} via a bare, relative FILEcreate() — i.e. into whatever the
# process's cwd happens to be, and it has no output-directory flag. Mayhem mounts the commit image
# read-only during coverage collection, and a per-cmd Mayhemfile `cwd:` key restart-loops Mayhem's
# OWN supervisor for a raw (non-libFuzzer) target (proven on abc/microscheme/svf in this fleet), so
# the fix has to live INSIDE the binary: src/express/fedex.c (the shared main() for every exp2* /
# check-express tool) is compiled here with `-Dmain=exp2python_original_main` — a fully-additive
# preprocessor rename, no upstream file is edited — and linked with mayhem/exp2python_wrapper_main.c,
# which supplies the real main(): resolve the input path to absolute, chdir("/tmp/exp2python-out"),
# then call the renamed original.
#
# stepcode is CMake-based; building needs only the C/C++ toolchain already in the base image (no
# network fetch, no FetchContent/vcpkg/conan — cmake/SC_Regenerate.cmake only regenerates the
# lexer/parser from .l/.y sources when bison/flex are found AND the generated sources are stale;
# the tracked generated sources under src/express/generated ship pre-built so a bare CMake
# configure never needs bison/flex). -DSC_BUILD_EXPRESS_ONLY=ON skips stepcode's schema-library
# generation (data/CMakeLists.txt would otherwise codegen+compile tens of thousands of C++ files
# for the bundled AP2xx/IFC schemas at CONFIGURE time — irrelevant to exp2python and enormously
# slow) so the whole build stays fast and fully offline/air-gapped.
#
# The sanitized exp2python binary is linked by hand (not via the CMake `exp2python` target) because
# CMake's own target already supplies `main` via fedex.c — there is no way to swap in the
# chdir-wrapper's main() without editing src/exp2python/CMakeLists.txt (an upstream file, which
# would break the additive invariant). Instead: build libexpress-static via CMake, then compile
# exp2python's own sources (mirrored 1:1 from src/exp2python/CMakeLists.txt's exp2python_SOURCES,
# minus fedex.c which is compiled separately with the rename) plus the wrapper, and link everything
# by hand — the same pattern already proven in this fleet by mayhem/abc_wrapper_main.c.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export CC CXX MAYHEM_JOBS

SRC="${SRC:=/mayhem}"
cd "$SRC"

# ---------------------------------------------------------------------------
# IDEMPOTENCY: wipe both build trees + the manual-link scratch dir first so a second offline
# re-run (PATCH tier) starts clean — stale CMakeCache.txt entries (compiler paths, flags) would
# otherwise survive a re-run with a different env and silently keep the OLD flags.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build" "$SRC/build-tests" "$SRC/mayhem/.manuallink"
mkdir -p "$SRC/mayhem/.manuallink"

CMAKE_COMMON=(
  -DSC_BUILD_EXPRESS_ONLY=ON     # skip generating/compiling the bundled AP2xx/IFC schema libs
  -DSC_ENABLE_TESTING=OFF        # we drive exp2python directly in mayhem/test.sh; no CTest needed
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
)

# ---------------------------------------------------------------------------
# 1) TEST oracle build -> build-tests/bin/exp2python : project's NORMAL flags, clean, built via the
#    project's own CMake target (dynamically linked — BUILD_SHARED_LIBS=ON, the project default —
#    so mayhem/test.sh's LD_PRELOAD-based sabotage check can actually interpose it), independent
#    of the sanitized fuzz binary below. mayhem/test.sh runs THIS binary directly from a scratch
#    dir it controls, so it needs no chdir-wrapper. $COVERAGE_FLAGS (empty by default) is appended
#    so an opt-in coverage build instruments it.
# ---------------------------------------------------------------------------
cmake -S "$SRC" -B "$SRC/build-tests" "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$SRC/build-tests" --target exp2python -j"$MAYHEM_JOBS"
[ -x "$SRC/build-tests/bin/exp2python" ] || { echo "ERROR: build-tests/bin/exp2python not built" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2) FUZZ target -> /mayhem/exp2python : the project ITSELF (not a thin wrapper) instrumented with
#    $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF < 4) so ASan/UBSan cover the real EXPRESS parser +
#    Python-generator code, and Mayhem triage can resolve source lines.
# ---------------------------------------------------------------------------
# 2a) libexpress-static via CMake (static — the manual link below needs one archive, not a .so
#     that would also have to be shipped/rpath'd alongside /mayhem/exp2python).
cmake -S "$SRC" -B "$SRC/build" "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build "$SRC/build" --target express-static -j"$MAYHEM_JOBS"
LIBEXPRESS="$SRC/build/lib/libexpress-static.a"
[ -f "$LIBEXPRESS" ] || { echo "ERROR: $LIBEXPRESS not built" >&2; exit 1; }

# 2b) exp2python's own sources, compiled by hand (1:1 with src/exp2python/CMakeLists.txt's
#     exp2python_SOURCES) so the chdir-wrapper's main() can be linked in instead of fedex.c's.
#     -DHAVE_CONFIG_H + the same include dirs CMake used (SC_SOURCE_DIR/include,
#     SC_BINARY_DIR/include for the generated config.h, SC_SOURCE_DIR/include/express).
INC=(-I"$SRC/include" -I"$SRC/build/include" -I"$SRC/include/express" -DHAVE_CONFIG_H)
OBJDIR="$SRC/mayhem/.manuallink"

# fedex.c supplies every exp2*/check-express tool's main(); rename it so our wrapper's main() can
# take over (chdir to a writable scratch dir first — see file header + exp2python_wrapper_main.c).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -Dmain=exp2python_original_main \
    -c "$SRC/src/express/fedex.c" -o "$OBJDIR/fedex.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/exp2python_wrapper_main.c" -o "$OBJDIR/exp2python_wrapper_main.o"

for f in classes_misc_python.c fedex_main_python.c classes_python.c selects_python.c multpass_python.c; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -c "$SRC/src/exp2python/src/$f" -o "$OBJDIR/${f%.c}.o"
done
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -c "$SRC/src/exp2python/src/classes_wrapper_python.cc" -o "$OBJDIR/classes_wrapper_python.o"
for f in collect complexlist entlist multlist orlist entnode expressbuild non-ors match-ors trynext write generated_output print; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -c "$SRC/src/exp2cxx/$f.cc" -o "$OBJDIR/exp2cxx_${f//-/_}.o"
done

# 2c) Link everything (+ libexpress-static.a) into /mayhem/exp2python.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -o /mayhem/exp2python "$OBJDIR"/*.o "$LIBEXPRESS" -lm
[ -x /mayhem/exp2python ] || { echo "ERROR: /mayhem/exp2python not built" >&2; exit 1; }

echo "build.sh: built /mayhem/exp2python (sanitized, chdir-wrapped) and build-tests/bin/exp2python (clean oracle)"
