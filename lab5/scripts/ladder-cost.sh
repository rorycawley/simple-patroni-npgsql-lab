#!/usr/bin/env bash
set -uo pipefail

# AC-7: every rung's cost, in time AND in rows, emitted by the run.
#
# The ladder is only a decision if the rungs have prices. "Restore beside the
# cluster" and "rewind the cluster" both recover the data; what separates them is
# that one costs nothing and the other discards every transaction since the
# target. An operator choosing under pressure needs that number, and needs it to
# be measured rather than asserted.
#
# So this table is not written by hand. Each rung's own check records what it
# actually measured, and this reads those files back. A rung in the suite that did
# not run leaves no file and this fails rather than printing a shorter table: the
# rung people most need to think twice about is exactly the one that would go
# missing. Rung 6 is the one exception, because it destroys the cluster and runs
# out of band -- its absence is printed, not passed over.
#
# THE TIMES ARE NOT REPRESENTATIVE and the table says so. This database restores
# in seconds because it holds a few thousand rows; the shape of the ladder is the
# finding, not the seconds. The ROW counts are the transferable part.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly COSTS="$LAB_DIR/.costs"
# Rung 6 destroys the cluster, so it runs out of band rather than in the suite.
# Its cost is shown when a total-loss run has recorded one, and its absence is
# stated rather than passed over -- an incomplete ladder should look incomplete.
readonly EXPECTED=(1 3 4 5)
readonly OPTIONAL=(6)

# Rungs whose entire claim is that they cost no committed data. If one of these
# ever reports a loss it is not the rung this lab describes, and the ladder's
# advice to prefer it becomes wrong.
readonly MUST_BE_LOSSLESS=(1 3 6)

# Rungs actually present, filled in below: EXPECTED plus any OPTIONAL that ran.
SHOWN=()

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# A case, not an associative array: this runs on the control machine, and macOS
# ships bash 3.2, where `declare -A` is an error. It appeared to work only because
# every key here is an integer, so the declaration failed and the assignment
# quietly produced an INDEXED array that happened to answer correctly.
rung_name() {
  case "$1" in
    1) echo "Replace one lost node" ;;
    3) echo "Restore a copy beside a live cluster" ;;
    4) echo "Restore one table from a dump" ;;
    5) echo "Rewind the cluster to a point in time" ;;
    6) echo "Rebuild everything after total loss" ;;
    *) echo "rung $1" ;;
  esac
}

echo
echo "=== What each rung of the recovery ladder actually cost ==="
missing=()
for r in "${EXPECTED[@]}"; do
  [[ -f "$COSTS/rung$r" ]] || missing+=("$r")
done
if (( ${#missing[@]} > 0 )); then
  fail "no measurement for rung(s): ${missing[*]} -- run their checks before asking for the table"
  echo "       (each rung records its own cost; an absent file means that rung did not run)" >&2
  echo
  echo "FAILED: $failures problem(s)" >&2
  exit 1
fi

SHOWN=("${EXPECTED[@]}")
for r in "${OPTIONAL[@]}"; do [[ -f "$COSTS/rung$r" ]] && SHOWN+=("$r"); done
IFS=$'\n' SHOWN=($(sort -n <<< "${SHOWN[*]}")); unset IFS

printf '\n  %-4s %-38s %10s %10s %8s\n' "Rung" "What it recovers" "To serve" "To whole" "Rows lost"
printf '  %-4s %-38s %10s %10s %8s\n' "----" "--------------------------------------" "--------" "--------" "---------"
for r in "${SHOWN[@]}"; do
  IFS='|' read -r secs rows downtime _note < "$COSTS/rung$r"
  # Rungs that never stop serving report a downtime of 0, which is the single
  # most important column: it is what distinguishes 3 and 4 from 5 and 6.
  printf '  %-4s %-38s %10s %10s %8s\n' \
    "$r" "$(rung_name "$r")" "${downtime}s" "${secs}s" "$rows"
done
echo

for r in "${SHOWN[@]}"; do
  IFS='|' read -r _secs rows _downtime note < "$COSTS/rung$r"
  printf '  rung %s: %s\n' "$r" "$note"
done

for r in "${OPTIONAL[@]}"; do
  [[ -f "$COSTS/rung$r" ]] || echo "  rung $r: not measured in this run -- 'make test_total_loss' destroys and rebuilds the cluster"
done

echo
echo "=== The claims the ladder rests on ==="
for r in "${MUST_BE_LOSSLESS[@]}"; do
  [[ -f "$COSTS/rung$r" ]] || continue
  IFS='|' read -r _s rows _d _n < "$COSTS/rung$r"
  [[ "$rows" == "0" ]] \
    && pass "rung $r discarded no committed transactions, as the ladder promises" \
    || fail "rung $r reports $rows rows lost; the ladder recommends it as lossless"
done

# The whole argument for a ladder rather than a single procedure: reaching for
# the big hammer costs data that the cheaper rungs do not.
IFS='|' read -r _s rows5 down5 _n < "$COSTS/rung5"
IFS='|' read -r _s rows3 down3 _n < "$COSTS/rung3"
if [[ "$rows5" =~ ^[0-9]+$ ]] && (( rows5 > 0 )); then
  pass "rung 5 discarded $rows5 committed transactions that rung 3 would have kept"
else
  fail "rung 5 reports no data loss, so nothing in this table argues for preferring rung 3"
fi
if [[ "$down3" == "0" && "$down5" =~ ^[0-9]+$ ]] && (( down5 > 0 )); then
  pass "and it stopped the cluster for ${down5}s, where rung 3 stopped it for none"
else
  fail "the downtime figures do not distinguish restoring beside from rewinding"
fi

echo
echo "  The SECONDS above are not representative: this database holds a few"
echo "  thousand rows and restores faster than the cluster can settle. The ROWS"
echo "  and the downtime column are the transferable findings -- they follow from"
echo "  what each rung does, not from how much data it moves."
echo
(( failures == 0 )) && { echo "PASS"; exit 0; }
echo "FAILED: $failures problem(s)" >&2
exit 1
