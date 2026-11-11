#!/bin/zsh
set -euo pipefail

PET_DIR="${CODEX_PET_DIR:-${PET_DIR:-$HOME/.claude/pet}}"
BIN="$PET_DIR/bin/CodexPet"
PIDFILE="$PET_DIR/run/pet.pid"
RUN_DIR="$PET_DIR/run"

say() { print -r -- "$@" }
die() { print -r -- "✗ $@" >&2; exit 1 }

running_pid() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == *CodexPet ]] || return 1
  print -r -- "$pid"
}

start() {
  [[ -x "$BIN" ]] || die "未找到 $BIN，请先运行 ./install.sh"
  local pid
  if pid="$(running_pid)"; then
    if [[ -e "$RUN_DIR/pet.hidden" ]]; then
      say "已在运行（pid $pid）· 已隐藏，可用 petctl.sh show 显示"
    else
      say "已在运行（pid $pid）"
    fi
    return 0
  fi
  nohup "$BIN" >/dev/null 2>&1 &!
  for _ in {1..20}; do
    sleep 0.1
    if pid="$(running_pid)"; then
      say "已启动（pid $pid）"
      return 0
    fi
  done
  die "启动失败，请检查 $PET_DIR/bin/CodexPet 是否可执行"
}

stop() {
  local pid
  if ! pid="$(running_pid)"; then
    say "未运行"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in {1..25}; do
    sleep 0.1
    if ! running_pid >/dev/null; then
      rm -f "$RUN_DIR/pet.hidden" "$RUN_DIR/pet.show" "$RUN_DIR/pet.hide"
      say "已停止（pid $pid）"
      return 0
    fi
  done
  die "进程 $pid 未在 2.5 秒内退出"
}

show() {
  local pid
  if ! pid="$(running_pid)"; then
    die "未运行，请先运行 petctl.sh start"
  fi
  : > "$RUN_DIR/pet.show"
  for _ in {1..20}; do
    sleep 0.1
    if [[ ! -e "$RUN_DIR/pet.show" ]]; then
      say "已显示（pid $pid）"
      return 0
    fi
  done
  die "宠物未响应显示请求，请尝试 restart"
}

hide() {
  local pid
  if ! pid="$(running_pid)"; then
    die "未运行，请先运行 petctl.sh start"
  fi
  : > "$RUN_DIR/pet.hide"
  for _ in {1..20}; do
    sleep 0.1
    if [[ -e "$RUN_DIR/pet.hidden" ]]; then
      say "已隐藏（pid $pid），可用 petctl.sh show 恢复"
      return 0
    fi
  done
  die "宠物未响应隐藏请求，请尝试 restart"
}

toggle() {
  local pid
  if ! pid="$(running_pid)"; then
    die "未运行，请先运行 petctl.sh start"
  fi
  if [[ -e "$RUN_DIR/pet.hidden" ]]; then
    show
  else
    hide
  fi
}

status() {
  local pid
  if pid="$(running_pid)"; then
    local count=0
    for f in "$RUN_DIR"/*.json(N); do
      count=$((count + 1))
    done
    local hidden=""
    [[ -e "$RUN_DIR/pet.hidden" ]] && hidden=" · 已隐藏"
    say "运行中（pid $pid）· 会话 $count$hidden"
  else
    say "未运行"
  fi
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  show) show ;;
  hide) hide ;;
  toggle) toggle ;;
  status) status ;;
  *)
    say "用法：$0 {start|stop|restart|show|hide|toggle|status}"
    exit 1
    ;;
esac
