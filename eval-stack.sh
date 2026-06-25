#!/usr/bin/env bash
#
# eval-stack.sh — start/stop the Vachi gateway + billing service for A/B eval runs.
#
# Brings up both services locally (no docker: sqlite + mock-Redis) with the env
# flags the eval harness needs — crucially VACHI_ALLOW_BYPASS_HEADER=1, so the
# "without us" bypass leg actually bypasses (forgetting this makes BOTH legs
# optimize and silently kills the A/B contrast).
#
# Usage:
#   ./eval-stack.sh start     # start billing (8002) then gateway (8000)
#   ./eval-stack.sh stop      # stop both
#   ./eval-stack.sh restart
#   ./eval-stack.sh status
#   ./eval-stack.sh logs [gateway|billing]
#
# Keys: sourced from ./setup_local_keys.sh (canonical) if present, else
# ./.eval-secrets (gitignored), else whatever is already exported.
# Required: OPENAI_API_KEY.  Optional: ANTHROPIC_API_KEY, GEMINI_API_KEY.
set -euo pipefail

# --- Config (override via env) ---------------------------------------------
GW_ROOT="${VACHI_GW_ROOT:-$HOME/Sandbox/llm-gateway/main}"   # latest build lives here
GW_APP="$GW_ROOT/apps/token_distillation"   # code moved here from vmc_architecture_mvp
PY="$GW_APP/venv/bin/python"
GW_PORT="${VACHI_GW_PORT:-8000}"
BILLING_PORT="${VACHI_BILLING_PORT:-8002}"
LOG_DIR="${VACHI_EVAL_LOG_DIR:-/tmp/vachi-eval}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Key source, in priority order: your canonical setup_local_keys.sh, then a
# local .eval-secrets fallback, then whatever is already exported.
SETUP_KEYS="${VACHI_LOCAL_KEYS:-$SCRIPT_DIR/setup_local_keys.sh}"
SECRETS_FILE="${EVAL_SECRETS_FILE:-$SCRIPT_DIR/.eval-secrets}"

GW_LOG="$LOG_DIR/gateway.log"
BILLING_LOG="$LOG_DIR/billing.log"
GW_PID="$LOG_DIR/gateway.pid"
BILLING_PID="$LOG_DIR/billing.pid"

mkdir -p "$LOG_DIR"

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

# --- Preconditions ---------------------------------------------------------
check_paths() {
  [ -d "$GW_APP" ] || { c_red "Gateway app not found: $GW_APP (set VACHI_GW_ROOT)"; exit 1; }
  [ -x "$PY" ]     || { c_red "Gateway venv python not found: $PY"; exit 1; }
}

load_secrets() {
  local sourced=""
  if [ -f "$SETUP_KEYS" ]; then
    set -a; . "$SETUP_KEYS" >/dev/null; set +a      # canonical key script (quiet)
    sourced="$SETUP_KEYS"
  elif [ -f "$SECRETS_FILE" ]; then
    set -a; . "$SECRETS_FILE"; set +a
    sourced="$SECRETS_FILE"
  fi
  [ -n "$sourced" ] && c_dim "[secrets] sourced $sourced" \
                     || c_dim "[secrets] none found — relying on exported env"
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    c_red "OPENAI_API_KEY is not set."
    c_red "  → ensure $SETUP_KEYS exports it, add it to $SECRETS_FILE, or export it."
    exit 1
  fi
}

# Eval-specific env applied to BOTH services. ENVIRONMENT=local => sqlite + mock
# Redis; both services run with CWD=$GW_APP so they share ./telemetry.db.
export_eval_env() {
  export ENVIRONMENT="${ENVIRONMENT:-local}"   # setup_local_keys.sh may set local-debug
  export VACHI_ALLOW_BYPASS_HEADER=1            # the no-touch "without us" leg
  export VACHI_ALLOW_CACHING_PROFILE_HEADER=1   # the caching-only arm (Anthropic phase)
  export STRIPE_API_KEY="${STRIPE_API_KEY:-sk_test_local}"   # dummy; billing won't sync for short runs
  export PYTHONUNBUFFERED=1
  # OPENAI_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY come from secrets/env.
}

port_in_use() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

wait_http() {  # url name max_tries
  local url="$1" name="$2" tries="${3:-40}" i=0
  while [ "$i" -lt "$tries" ]; do
    if curl -sS -o /dev/null -m 3 "$url" 2>/dev/null; then c_grn "  ✓ $name up ($url)"; return 0; fi
    i=$((i+1)); sleep 0.5
  done
  c_red "  ✗ $name did not respond at $url (see logs)"; return 1
}

start_one() {  # name module:app port logfile pidfile
  local name="$1" target="$2" port="$3" log="$4" pidfile="$5"
  if port_in_use "$port"; then
    c_red "  $name: port $port already in use — run '$0 stop' first (or restart)"; return 1
  fi
  ( cd "$GW_APP" && nohup "$PY" -m uvicorn "$target" --host 127.0.0.1 --port "$port" \
      > "$log" 2>&1 </dev/null & echo $! > "$pidfile" )
  c_dim "  $name: pid $(cat "$pidfile") → $log"
}

# --- Commands --------------------------------------------------------------
cmd_start() {
  check_paths; load_secrets; export_eval_env
  c_dim "[gateway build] $GW_APP  (branch: $(git -C "$GW_ROOT" branch --show-current 2>/dev/null || echo '?'))"
  c_dim "[env] ENVIRONMENT=$ENVIRONMENT  VACHI_ALLOW_BYPASS_HEADER=$VACHI_ALLOW_BYPASS_HEADER  VACHI_ALLOW_CACHING_PROFILE_HEADER=$VACHI_ALLOW_CACHING_PROFILE_HEADER"

  echo "Starting billing service (must precede gateway so telemetry emits land)…"
  start_one "billing" "billing_service:app" "$BILLING_PORT" "$BILLING_LOG" "$BILLING_PID"
  wait_http "http://127.0.0.1:$BILLING_PORT/health" "billing" 30 \
    || wait_http "http://127.0.0.1:$BILLING_PORT/" "billing" 4 || true

  echo "Starting gateway…"
  start_one "gateway" "main:app" "$GW_PORT" "$GW_LOG" "$GW_PID"
  wait_http "http://127.0.0.1:$GW_PORT/health" "gateway" 60

  echo
  c_grn "Eval stack up:"
  echo "  gateway : http://127.0.0.1:$GW_PORT"
  echo "  billing : http://127.0.0.1:$BILLING_PORT"
  echo "  bypass leg ENABLED (VACHI_ALLOW_BYPASS_HEADER=1)"
  c_dim "  logs: $0 logs gateway | $0 logs billing"
}

stop_pidfile() { # name pidfile
  local name="$1" pidfile="$2"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    kill "$(cat "$pidfile")" 2>/dev/null && c_dim "  stopped $name (pid $(cat "$pidfile"))"
  fi
  rm -f "$pidfile"
}

free_port() {  # kill whatever holds a port (covers instances started by hand)
  local p="$1" pids
  pids=$(lsof -ti:"$p" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    c_dim "  freed port $p (pids: $(echo $pids | tr '\n' ' '))"
  fi
}

cmd_stop() {
  stop_pidfile "gateway" "$GW_PID"
  stop_pidfile "billing" "$BILLING_PID"
  # belt-and-suspenders: catch instances not started via this script. The
  # billing pattern matches both `uvicorn billing_service:app` and
  # `python billing_service.py`; then free the ports outright.
  pkill -f "uvicorn main:app" 2>/dev/null || true
  pkill -f "billing_service" 2>/dev/null || true
  free_port "$GW_PORT"
  free_port "$BILLING_PORT"
  c_grn "Eval stack stopped."
}

cmd_status() {
  for spec in "gateway:$GW_PORT:$GW_PID" "billing:$BILLING_PORT:$BILLING_PID"; do
    IFS=: read -r name port pidfile <<<"$spec"
    if port_in_use "$port"; then
      c_grn "  $name: LISTENING on $port"
    else
      c_red "  $name: down (port $port free)"
    fi
  done
}

cmd_logs() {
  case "${1:-gateway}" in
    billing) tail -n 60 -f "$BILLING_LOG" ;;
    *)       tail -n 60 -f "$GW_LOG" ;;
  esac
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  status)  cmd_status ;;
  logs)    cmd_logs "${2:-gateway}" ;;
  *) echo "usage: $0 {start|stop|restart|status|logs [gateway|billing]}"; exit 2 ;;
esac
