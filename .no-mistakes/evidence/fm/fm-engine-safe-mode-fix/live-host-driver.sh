#!/usr/bin/env bash
# Live driver: real fm-supervision-host.sh with the real Claude engine on a
# marked disposable lab home. $1 = name, $2 = number of away wakes (1 or 3).
set -u
NAME=$1 WAKES=$2
WT=${WT:-/Users/hjetmundsen/.no-mistakes/worktrees/ab5a0f935e90/01M7HGH6DYR7XMWEAD43F70HE5}
EV=/Users/hjetmundsen/.no-mistakes/evidence/01M7HGH6DYR7XMWEAD43F70HE5
OUT="$EV/$NAME"
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd -P "$LAB" && pwd -P)
rmdir "$LAB" && "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
AUX=$(mktemp -d "${TMPDIR:-/tmp}/fm-aux.XXXXXX"); AUX=$(cd -P "$AUX" && pwd -P)
mkdir -p "$AUX/harness" "$AUX/tmuxbin"
ln -s /bin/bash "$AUX/harness/claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$AUX/tmuxbin/tmux"; chmod +x "$AUX/tmuxbin/tmux"
printf 'claude claude-haiku-5-5\n' > "$LAB/config/supervision-host"
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$LAB/state/demo.meta"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/driver.log"; }
CLEANENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_SUPERVISION_ENGINE_CLAUDE_BIN
  -u FM_SUPERVISION_ACTOR -u FM_BRANCH_REPORT_TURN -u FM_LEASE_HOLDER_PID -u PI_CODING_AGENT
  -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_TOKEN
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ATTENDED
  FM_HOME="$LAB" PATH="$AUX/tmuxbin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999)
log "lab home $LAB (marker: $(ls -A "$LAB" | tr '\n' ' '))"
log "claude $(claude --version | head -1)"
"${CLEANENV[@]}" "$WT/bin/fm-afk-contract.sh" enter --words 'Watch the fleet. Merge nothing and dispatch nothing.' > "$OUT/afk-enter.out" 2>&1 \
  || { log "afk enter failed: $(cat "$OUT/afk-enter.out")"; exit 1; }

stop_lab() {
  local pid
  : > "$AUX/session.stop"
  if [ -f "$LAB/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$LAB/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
  fi
  pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  pid=$(cat "$AUX/holder.pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  cp -R "$LAB/state" "$OUT/lab-state" 2>/dev/null || true
  rm -rf "$LAB" "$AUX"
  log "lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
}
trap stop_lab EXIT

"${CLEANENV[@]}" "$AUX/harness/claude" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  printf "%s\n" "$$" > "$1/holder.pid"
  while [ ! -e "$1/session.stop" ] && [ -d "$FM_HOME" ]; do
    if [ -e "$1/park.go" ]; then
      rm -f "$1/park.go"
      "$0" park > "$1/host.out" 2>&1
      printf "%s\n" "$?" > "$1/host.rc"
    fi
    sleep 0.1
  done
' "$WT/bin/fm-supervision-host.sh" "$AUX" 2>> "$OUT/holder.err" &

wait_until() { local limit=$1 i=0; shift; while [ "$i" -lt "$limit" ]; do "$@" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
watcher_live() { local pid; pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null) || return 1; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
host_exited() { [ -s "$AUX/host.rc" ]; }
rows() { local n; n=$(grep -cE "	$1	" "$LAB/state/.supervision-host.log" 2>/dev/null); echo "${n:-0}"; }
park() { rm -f "$AUX/host.rc"; : > "$AUX/park.go"; wait_until 300 watcher_live || { log "no watcher cycle: $(cat "$AUX/host.out")"; exit 1; }; }
main_drain_and_ack() {
  local out ack
  out=$("${CLEANENV[@]}" "$WT/bin/fm-wake-drain.sh" 2>&1)
  printf '%s\n' "$out" > "$OUT/main-drain.$1.out"
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  # shellcheck disable=SC2086
  [ -z "$ack" ] || "${CLEANENV[@]}" "$WT/bin/fm-wake-drain.sh" $ack >> "$OUT/main-drain.$1.out" 2>&1
}

for w in $(seq 1 "$WAKES"); do
  park
  log "wake $w: host parked on watcher $(cat "$LAB/state/.watch.lock/pid")"
  before_failed=$(rows failed); before_handled=$(rows handled)
  printf 'done [at=%s]: demo cleanup step %s finished; nothing else is needed\n' "$(date +%s)" "$w" >> "$LAB/state/demo.status"
  t0=$(date +%s)
  wait_until 6000 host_exited || { log "wake $w: host never handed back in 600s (handled=$(rows handled))"; }
  log "wake $w: host exit rc=$(cat "$AUX/host.rc" 2>/dev/null) after $(( $(date +%s) - t0 ))s; failed rows $before_failed->$(rows failed), handled rows $before_handled->$(rows handled)"
  cp "$AUX/host.out" "$OUT/host.out.wake$w"
  cp "$LAB/state/.supervision-host-health" "$OUT/health.wake$w" 2>/dev/null || true
  { printf -- '--- host.out (wake %s)\n' "$w"; cat "$AUX/host.out"; printf -- '--- health\n'; cat "$LAB/state/.supervision-host-health" 2>/dev/null; } | tee -a "$OUT/driver.log"
  main_drain_and_ack "$w"
done
cp "$LAB/state/.supervision-host.log" "$OUT/supervision-host.log"
printf -- '--- ledger\n' | tee -a "$OUT/driver.log"; cat "$LAB/state/.supervision-host.log" | tee -a "$OUT/driver.log"

# The captain returns: the away return brief, with the holder (main session) still alive.
pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
[ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
sleep 1
"${CLEANENV[@]}" "$WT/bin/fm-afk-return.sh" begin > "$OUT/return-brief.out" 2>&1
log "return brief exit $?"
cat "$OUT/return-brief.out" | tee -a "$OUT/driver.log"
