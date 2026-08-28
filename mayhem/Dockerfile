# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) for stepcode — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base), which already provides debian + clang/llvm + libFuzzer/afl++ + the
# non-root identities + the build-contract ENV. exp2python (stepcode's EXPRESS -> Python code
# generator) has no LLVMFuzzerTestOneInput harness; it is a raw file-input CLI (Mayhem drives the
# sanitized binary directly on a file argument, same pattern as semblance's `dump` / neper's
# `neper`), so there is no separate libFuzzer/standalone build step here — mayhem/build.sh produces
# /mayhem/exp2python directly (chdir-wrapped — see mayhem/exp2python_wrapper_main.c).

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an empty value
# breaks clang ("must be a non-negative decimal integer") both here and for any in-image rebuild.
# build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declared WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to build.sh
# when not passed, and an explicit --build-arg overrides it.
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build for source-coverage measurement.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset.
ARG MAYHEM_JOBS=

# stepcode is CMake-based and needs only the C/C++ toolchain + CMake already in the base image (no
# network fetch — the tracked generated lexer/parser sources ship pre-built, and
# -DSC_BUILD_EXPRESS_ONLY=ON in mayhem/build.sh skips the bundled-schema codegen entirely), so no
# extra apt install is needed here.

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run exp2python's own functional oracle (mayhem/test.sh) at build time. A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
