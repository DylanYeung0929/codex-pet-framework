#!/bin/zsh
set -euo pipefail

PET_DIR="${CODEX_PET_DIR:-${PET_DIR:-$HOME/.claude/pet}}"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

say() { print -r -- "$@" }

if [[ -f "$PET_DIR/run/pet.pid" ]]; then
  pid="$(cat "$PET_DIR/run/pet.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == *CodexPet ]]; then
    kill "$pid" 2>/dev/null || true
    say "已停止宠物进程 $pid"
  fi
fi

/usr/bin/python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys, tempfile

path = sys.argv[1]
if not os.path.exists(path):
    print("  未找到 settings.json，跳过")
    sys.exit(0)
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
hooks = data.get("hooks") if isinstance(data, dict) else None
if not isinstance(hooks, dict):
    print("  无需清理的 hooks")
    sys.exit(0)

for event in list(hooks.keys()):
    groups = hooks[event]
    if not isinstance(groups, list):
        continue
    kept_groups = []
    for group in groups:
        if not isinstance(group, dict):
            kept_groups.append(group)
            continue
        kept = [
            hook for hook in (group.get("hooks") or [])
            if "pet_hook.py" not in str(hook.get("command", ""))
        ]
        if kept:
            group["hooks"] = kept
            kept_groups.append(group)
    if kept_groups:
        hooks[event] = kept_groups
    else:
        del hooks[event]

if not hooks:
    data.pop("hooks", None)

shutil.copy2(path, path + ".pet-backup")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("  已移除宠物 hooks（原文件备份为 .pet-backup）")
PY

/usr/bin/python3 - "$ZSHRC" <<'PY'
import os, re, shutil, sys, tempfile

path = sys.argv[1]
if not os.path.exists(path):
    print("  未找到 zshrc，跳过")
    sys.exit(0)
with open(path, encoding="utf-8") as fh:
    text = fh.read()
pattern = re.compile(r"(?ms)^# >>> CodexPet >>>.*?^# <<< CodexPet <<<\n?")
text, count = pattern.subn("", text)
if count == 0:
    print("  未找到安装器写入的包装函数，跳过")
    sys.exit(0)
shutil.copy2(path, path + ".pet-backup")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".zshrc.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, path)
print("  已移除 zsh 包装函数（原文件备份为 .pet-backup）")
PY

if [[ "${1:-}" == "--purge" ]]; then
  if [[ "${2:-}" != "--yes" ]]; then
    read -q "?删除 $PET_DIR（含窗口状态与统计数据）？[y/N] " || { say ""; say "已保留 $PET_DIR"; exit 0; }
    say ""
  fi
  rm -rf "$PET_DIR"
  say "已删除 $PET_DIR"
else
  say "已移除 hooks 与包装函数；保留 $PET_DIR（含统计数据）。"
  say "彻底删除：$0 --purge"
fi
