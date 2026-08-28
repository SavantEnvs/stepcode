#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for stepcode's exp2python (EXPRESS -> Python generator).
#
# RUNS the prebuilt, un-sanitized oracle binary mayhem/build.sh already built at
# build-tests/bin/exp2python (no compiling here) against upstream's OWN regression fixtures —
# test/unitary_schemas/*.exp — the same corpus stepcode's own CTest suite
# (test/unitary_schemas/CMakeLists.txt) drives through `check-express`, including its `fail_*`
# naming convention for schemas that MUST be rejected.
#
# BEHAVIORAL, not exit-code-only: for every schema that should compile, this asserts the generated
# <schema>.py file actually EXISTS and CONTAINS the schema's own name (`schema_name = '<schema>'`)
# AND the first ENTITY/TYPE the .exp file declares, rendered as exp2python is known to render it
# (`class <entity>(BaseEntityClass)` for an ENTITY, or the bare identifier for a TYPE — enums become
# `<type> = ENUMERATION(...)`, defined types with a WHERE rule become `class <type>(...)`, SELECTs
# become `<type> = SELECT(...)`, so a name/word-boundary match on the TYPE identifier is what's
# common across all of exp2python's TYPE renderings). A no-op/`exit(0)` PATCH produces no output
# file at all and FAILS every one of these; a PATCH that garbles codegen loses the asserted names
# and also fails. For `fail_*` schemas, the oracle asserts a NON-zero exit and NO output file
# (exp2python must still reject them, exactly like upstream's WILL_FAIL CTest property).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

ORACLE_BIN="$PWD/build-tests/bin/exp2python"
SCHEMA_DIR="$PWD/test/unitary_schemas"
SCRATCH=/tmp/exp2python-test-scratch
passed=0; failed=0

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" p="$2" f="$3" s="${4:-0}" pe="${5:-0}" o="${6:-0}"
  local tests=$(( p + f + s + pe + o ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $p, "failed": $f, "pending": $pe, "skipped": $s, "other": $o }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$p" "$f" "$pe" "$s" "$o"
  [ "$f" -eq 0 ]
}

if [ ! -x "$ORACLE_BIN" ]; then
  echo "test.sh: oracle binary $ORACLE_BIN missing — build.sh must build it (not rebuilding here)" >&2
  emit_ctrf stepcode-exp2python-oracle 0 1
  exit $?
fi
if [ ! -d "$SCHEMA_DIR" ]; then
  echo "test.sh: fixture dir $SCHEMA_DIR missing" >&2
  emit_ctrf stepcode-exp2python-oracle 0 1
  exit $?
fi

shopt -s nullglob
n=0
for f in "$SCHEMA_DIR"/*.exp; do
  n=$((n+1))
  name=$(basename "$f" .exp)
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"

  out=$(cd "$SCRATCH" && "$ORACLE_BIN" "$f" 2>&1); rc=$?

  case "$name" in
    fail_*)
      if [ "$rc" -ne 0 ] && [ -z "$(ls -A "$SCRATCH")" ]; then
        echo "  ok   - $name: correctly REJECTED (rc=$rc, no output written)"
        passed=$((passed+1))
      else
        echo "  FAIL - $name: expected rejection (nonzero rc, no output) but rc=$rc, files: $(ls -A "$SCRATCH")"
        failed=$((failed+1))
      fi
      ;;
    *)
      schema=$(grep -m1 -oE '^[[:space:]]*SCHEMA[[:space:]]+[A-Za-z0-9_]+' "$f" | awk '{print $2}')
      symbol=$(grep -m1 -oE '^[[:space:]]*ENTITY[[:space:]]+[A-Za-z0-9_]+' "$f" | awk '{print $2}')
      [ -z "$symbol" ] && symbol=$(grep -m1 -oE '^[[:space:]]*TYPE[[:space:]]+[A-Za-z0-9_]+' "$f" | awk '{print $2}')
      # exp2python lowercases EXPRESS identifiers in its Python output (EXPRESS is
      # case-insensitive) — e.g. `ENTITY A` -> `class a(BaseEntityClass)`.
      symbol=$(printf '%s' "$symbol" | tr '[:upper:]' '[:lower:]')
      pyfile="$SCRATCH/$schema.py"
      if [ "$rc" -ne 0 ]; then
        echo "  FAIL - $name: expected acceptance (rc=0) but rc=$rc: $out"
        failed=$((failed+1))
      elif [ ! -s "$pyfile" ]; then
        echo "  FAIL - $name: expected output $pyfile missing/empty"
        failed=$((failed+1))
      elif ! grep -qF "schema_name = '$schema'" "$pyfile"; then
        echo "  FAIL - $name: $pyfile missing schema_name marker for '$schema'"
        failed=$((failed+1))
      elif [ -n "$symbol" ] && ! grep -qE "(^|[^A-Za-z0-9_])$symbol([^A-Za-z0-9_]|$)" "$pyfile"; then
        echo "  FAIL - $name: $pyfile missing expected identifier '$symbol'"
        failed=$((failed+1))
      else
        echo "  ok   - $name: schema '$schema' generated, contains '$schema' + '$symbol'"
        passed=$((passed+1))
      fi
      ;;
  esac
done
rm -rf "$SCRATCH"

if [ "$n" -eq 0 ]; then
  echo "test.sh: no fixtures found under $SCHEMA_DIR" >&2
  emit_ctrf stepcode-exp2python-oracle 0 1
  exit $?
fi

echo "test.sh: passed=$passed failed=$failed (of $n unitary_schemas fixtures)"
emit_ctrf stepcode-exp2python-oracle "$passed" "$failed"
