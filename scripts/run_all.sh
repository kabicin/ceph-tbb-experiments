#!/usr/bin/env bash
# A/B benchmark of RGW Lua scripts: runs warp once per script against a
# baseline tree and a candidate tree, starting/stopping a vstart cluster in
# each (the same commands as the cephup/cephdown aliases), with a pause
# between runs.
#
# usage (from anywhere):
#   lua-bench/run_all.sh                    # every lua-bench/*.lua
#   lua-bench/run_all.sh counter.lua key-churner.lua lua-bench/read_mostly.lua
#
# settings (environment variables):
#   BASELINE=~/code/ceph        tree to compare against (main)
#   CANDIDATE=~/code/ceph-tbb   tree under test
#   SET=all          which scripts to run:
#                      safe: only scripts that never call pairs(RGW). on main,
#                            pairs(RGW) walks the table with no lock, so any
#                            script that iterates while other requests write
#                            is a data race there and can crash radosgw
#                      racy: only the scripts that call pairs(RGW)
#                      all:  both, the safe ones first
#   RESTART_EACH=1   1: fresh cluster for every run, trees alternate per script
#                       (every run starts with an empty RGW table)
#                    0: one cluster per tree for all scripts; the RGW table is
#                       cleared between scripts by a reset script instead
#   GAP=30           seconds to wait between runs
#   DURATION=60s     warp --duration
#   CONCURRENT=100   warp --concurrent
#   STARTUP_TIMEOUT=300  seconds to wait for radosgw to answer after cephup
#   SCRIPT_SETTLE=10 seconds to wait after "script put" before sending traffic.
#                    put overwrites the old script, but radosgw serves cached
#                    bytecode until its Lua background thread refreshes the
#                    cache, once per background interval (5s by default), so
#                    without this wait the previous script can still run
#   HOST, ACCESS_KEY, SECRET_KEY, BUCKET, OBJ_SIZE   warp connection settings
#                    (the keys are the vstart default user)
#
# output: lua-bench/results/<timestamp>/{baseline,candidate}/<script>.log,
#         warp's .json.zst files, vstart logs and summary.txt

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"

BASELINE="${BASELINE:-$HOME/code/ceph}"
CANDIDATE="${CANDIDATE:-$HOME/code/ceph-tbb}"
SET="${SET:-all}"
RESTART_EACH="${RESTART_EACH:-1}"
GAP="${GAP:-30}"
DURATION="${DURATION:-60s}"
CONCURRENT="${CONCURRENT:-100}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"
SCRIPT_SETTLE="${SCRIPT_SETTLE:-10}"
HOST="${HOST:-localhost:8000}"
ACCESS_KEY="${ACCESS_KEY:-0555b35654ad1656d804}"
SECRET_KEY="${SECRET_KEY:-h7GhxuBLTrlhVUyxSPUKUV8r/2EI4ngqJxD7iBdBYLhwluN30JaT3Q==}"
BUCKET="${BUCKET:-my-bucket}"
OBJ_SIZE="${OBJ_SIZE:-1}"

# scripts: absolute paths, so changing directory into the trees is safe
SCRIPTS=()
if [ "$#" -gt 0 ]; then
  for s in "$@"; do
    [ -f "$s" ] || { echo "no such script: $s" >&2; exit 1; }
    SCRIPTS+=("$(cd "$(dirname "$s")" && pwd)/$(basename "$s")")
  done
else
  SCRIPTS=("$SELF_DIR"/*.lua)
fi

# split into race-free scripts and ones that iterate the table (racy on main)
SAFE=(); RACY=()
for s in "${SCRIPTS[@]}"; do
  if grep -q "pairs(RGW)" "$s"; then RACY+=("$s"); else SAFE+=("$s"); fi
done
case "$SET" in
  safe) SCRIPTS=("${SAFE[@]}") ;;
  racy) SCRIPTS=("${RACY[@]}") ;;
  all)  SCRIPTS=("${SAFE[@]}" "${RACY[@]}") ;;
  *) echo "SET must be safe, racy or all (got: $SET)" >&2; exit 1 ;;
esac
[ "${#SCRIPTS[@]}" -gt 0 ] || { echo "no scripts selected (SET=$SET)" >&2; exit 1; }

command -v warp >/dev/null || { echo "warp not found in PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found in PATH" >&2; exit 1; }
for tree in "$BASELINE" "$CANDIDATE"; do
  for bin in radosgw radosgw-admin; do
    [ -x "$tree/build/bin/$bin" ] || {
      echo "$tree/build/bin/$bin is missing or not executable (still building?)" >&2; exit 1; }
  done
  [ -x "$tree/src/vstart.sh" ] || { echo "$tree/src/vstart.sh not found" >&2; exit 1; }
done

OUT="$REPO/lua-bench/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/baseline" "$OUT/candidate"
SUMMARY="$OUT/summary.txt"
RUNNING_TREE=""

tree_of() { [ "$1" = baseline ] && echo "$BASELINE" || echo "$CANDIDATE"; }

admin() {   # admin <label> <args...>: radosgw-admin of that tree's cluster
  local tree; tree="$(tree_of "$1")"; shift
  "$tree/build/bin/radosgw-admin" -c "$tree/build/ceph.conf" -k "$tree/build/keyring" "$@"
}

# install_script <label> <file>: replaces the prerequest script, then waits
# until radosgw's bytecode cache has picked up the new one
install_script() {
  admin "$1" script put --context prerequest --infile "$2"
  sleep "$SCRIPT_SETTLE"
}

cephdown() {   # same as the alias: ../src/stop.sh from the build directory
  local label="$1" tree; tree="$(tree_of "$label")"
  echo "--- cephdown ($label: $tree)"
  (cd "$tree/build" && ../src/stop.sh) >> "$OUT/$label/vstart.log" 2>&1 || true
  RUNNING_TREE=""
}

cephup() {   # same as the alias, then wait until radosgw answers
  local label="$1" tree; tree="$(tree_of "$label")"
  echo "--- cephup ($label: $tree)"
  (cd "$tree/build" && MON=1 OSD=1 MDS=0 MGR=0 RGW=1 ../src/vstart.sh -n -d) \
    >> "$OUT/$label/vstart.log" 2>&1 || {
      echo "vstart failed, see $OUT/$label/vstart.log" >&2; exit 1; }
  RUNNING_TREE="$label"
  local waited=0
  until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST/" || true)" != "000" ]; do
    if [ "$waited" -ge "$STARTUP_TIMEOUT" ]; then
      echo "radosgw did not answer on $HOST within ${STARTUP_TIMEOUT}s" >&2; exit 1
    fi
    sleep 2; waited=$((waited + 2))
  done
  echo "--- radosgw is up after ${waited}s"
}

# on exit (ctrl-c, error, or done): stop whichever cluster is still running
cleanup() {
  if [ -n "$RUNNING_TREE" ]; then
    admin "$RUNNING_TREE" script rm --context prerequest >/dev/null 2>&1 || true
    cephdown "$RUNNING_TREE"
  fi
}
trap cleanup EXIT

# clears the shared RGW table (only needed with RESTART_EACH=0): installs a
# script that erases every key and sends one request so it runs.
# tostring(k) works on main (userdata keys) and on the candidate (string keys)
reset_table() {
  local label="$1" reset_lua="$OUT/.reset.lua"
  cat > "$reset_lua" <<'EOF'
local keys = {}
for k in pairs(RGW) do keys[#keys + 1] = tostring(k) end
for _, k in ipairs(keys) do RGW[k] = nil end
EOF
  install_script "$label" "$reset_lua"
  # one request runs the reset script; a few in case one is not served by Lua
  for _ in 1 2 3; do curl -s -o /dev/null "http://$HOST/" || true; done
  sleep 1
}

rgw_alive() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST/" || true)" != "000" ]
}

# run_one <label> <script>: never fails the whole run. if warp fails, records
# why; if radosgw died, saves its crash backtrace and returns 1 so the caller
# can restart the cluster
run_one() {
  local label="$1" script="$2" name; name="$(basename "$script" .lua)"
  local log="$OUT/$label/$name.log" tree; tree="$(tree_of "$label")"
  local rgw_log="$tree/build/out/radosgw.${HOST##*:}.log"
  local crashes_before=0
  [ -f "$rgw_log" ] && crashes_before="$(grep -c "Caught signal" "$rgw_log" || true)"

  echo "=== $name on $label ($(date +%T))"
  install_script "$label" "$script"
  # warp writes its .json.zst into the current directory
  local warp_rc=0
  (
    cd "$OUT/$label"
    warp mixed --host="$HOST" --access-key="$ACCESS_KEY" --secret-key="$SECRET_KEY" \
      --bucket="$BUCKET" --duration="$DURATION" --concurrent="$CONCURRENT" \
      --obj.size="$OBJ_SIZE"
  ) 2>&1 | tee "$log" || warp_rc=$?

  local crashes_after=0
  [ -f "$rgw_log" ] && crashes_after="$(grep -c "Caught signal" "$rgw_log" || true)"
  local status=0 crash="$OUT/$label/$name.radosgw-crash.log"
  if [ "$crashes_after" -gt "$crashes_before" ] || ! rgw_alive; then
    status=1
    if [ "$crashes_after" -gt "$crashes_before" ]; then
      # first new backtrace: the signal line and the 40 lines after it
      grep -A40 "Caught signal" "$rgw_log" \
        | awk -v n=$((crashes_before + 1)) '/Caught signal/{c++} c==n' > "$crash"
    fi
  fi
  {
    echo "=== $name / $label"
    if [ "$status" -ne 0 ] && [ -s "$crash" ]; then
      echo "CRASHED: radosgw died during the run, backtrace in $label/$name.radosgw-crash.log"
      grep -m1 "Caught signal" "$crash" | sed 's/^/  /'
    elif [ "$status" -ne 0 ]; then
      echo "CRASHED: radosgw stopped answering (no backtrace found in $rgw_log)"
    elif [ "$warp_rc" -ne 0 ]; then
      echo "FAILED: warp exited with $warp_rc, see $label/$name.log"
      grep -m3 "<ERROR>" "$log" | sed 's/^/  /' || true
    else
      grep -E "Total|Throughput|Requests considered" "$log" || echo "(no totals found, see $label/$name.log)"
    fi
    echo
  } | tee -a "$SUMMARY"
  return "$status"
}

pause() {
  echo "--- waiting ${GAP}s"
  sleep "$GAP"
}

total=${#SCRIPTS[@]}
echo "baseline:  $BASELINE ($(git -C "$BASELINE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
echo "candidate: $CANDIDATE ($(git -C "$CANDIDATE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
echo "$total scripts (SET=$SET), results in $OUT"
for s in "${SCRIPTS[@]}"; do
  if grep -q "pairs(RGW)" "$s"; then echo "  racy on main  $(basename "$s")"; else echo "  safe          $(basename "$s")"; fi
done

# make sure no cluster from an earlier session is still holding the ports
cephdown baseline
cephdown candidate

if [ "$RESTART_EACH" = "1" ]; then
  # interleaved: each script runs on baseline then candidate, each on a fresh cluster
  i=0
  for script in "${SCRIPTS[@]}"; do
    i=$((i + 1))
    echo; echo "##### [$i/$total] $(basename "$script")"
    for label in baseline candidate; do
      cephup "$label"
      run_one "$label" "$script" || true   # a crash is recorded; the cluster is restarted anyway
      admin "$label" script rm --context prerequest >/dev/null 2>&1 || true
      cephdown "$label"
      if [ "$label" = baseline ] || [ "$i" -lt "$total" ]; then pause; fi
    done
  done
else
  # grouped: one cluster per tree, table cleared between scripts
  for label in baseline candidate; do
    cephup "$label"
    i=0
    for script in "${SCRIPTS[@]}"; do
      i=$((i + 1))
      echo; echo "##### [$i/$total] $(basename "$script") on $label"
      reset_table "$label"
      if ! run_one "$label" "$script"; then
        echo "--- radosgw crashed, restarting the $label cluster"
        cephdown "$label"
        cephup "$label"
      fi
      if [ "$i" -lt "$total" ]; then pause; fi
    done
    admin "$label" script rm --context prerequest >/dev/null 2>&1 || true
    cephdown "$label"
    if [ "$label" = baseline ]; then pause; fi
  done
fi

echo
echo "results: $OUT"
cat "$SUMMARY"
