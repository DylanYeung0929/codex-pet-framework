#!/bin/zsh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PET_DIR="${CODEX_PET_DIR:-${PET_DIR:-$HOME/.claude/pet}}"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

say() { print -r -- "$@" }
die() { print -r -- "✗ $@" >&2; exit 1 }

[[ "$(uname -s)" == "Darwin" ]] || die "仅支持 macOS"
command -v xcrun >/dev/null 2>&1 || die "未找到 xcrun，请先运行：xcode-select --install"
command -v python3 >/dev/null 2>&1 || die "未找到 python3"
python3 -c 'import PIL' >/dev/null 2>&1 || die "缺少 Pillow，请先运行：python3 -m pip install --user pillow"

FRAMEWORK_FILES=(
  CodexPet.swift
  pet_hook.py
  pet_wrapper.zsh
  build.sh
  build_assets.py
  install.sh
  uninstall.sh
  petctl.sh
  config.json
  README.md
  LICENSE
)

if [[ "$REPO_DIR" != "$PET_DIR" ]]; then
  say "安装到 $PET_DIR"
  mkdir -p "$PET_DIR"
  for f in "${FRAMEWORK_FILES[@]}"; do
    [[ -f "$REPO_DIR/$f" ]] && cp -f "$REPO_DIR/$f" "$PET_DIR/$f"
  done
  if [[ -d "$REPO_DIR/source" ]]; then
    mkdir -p "$PET_DIR/source"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$REPO_DIR/source/" "$PET_DIR/source/"
    else
      cp -R "$REPO_DIR/source/." "$PET_DIR/source/"
    fi
  fi
fi
chmod +x "$PET_DIR/build.sh" "$PET_DIR/install.sh" "$PET_DIR/uninstall.sh" "$PET_DIR/petctl.sh" 2>/dev/null || true

have_art=0
[[ -f "$PET_DIR/source/atlas.webp" ]] && have_art=1
if (( ! have_art )); then
  for f in "$PET_DIR"/source/*.webp(N); do
    have_art=1
    break
  done
fi
(( have_art )) || die "缺少精灵表：请先把 atlas.webp 放入 $PET_DIR/source/（或按动作放置 idle.webp 等）后重试"

say "构建宠物..."
( cd "$PET_DIR" && ./build.sh )

say "写入 Claude Code hooks..."
/usr/bin/python3 - "$SETTINGS" "$PET_DIR/pet_hook.py" <<'PY' || die "hooks 写入失败"
import json, os, shlex, shutil, sys, tempfile

settings_path, hook_path = sys.argv[1], sys.argv[2]
command = '[ -n "$CODEX_PET_ID" ] && /usr/bin/python3 {} ; true'.format(shlex.quote(hook_path))
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
data = {}
if os.path.exists(settings_path):
    shutil.copy2(settings_path, settings_path + ".pet-backup")
    with open(settings_path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        sys.exit("settings.json 根节点不是对象，已中止")

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit("settings.json 的 hooks 字段不是对象，已中止")

added = []
for event in events:
    groups = hooks.get(event)
    if not isinstance(groups, list):
        groups = []
    found = False
    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks") or []:
            if isinstance(hook, dict) and "pet_hook.py" in str(hook.get("command", "")):
                hook["type"] = "command"
                hook["command"] = command
                hook.setdefault("timeout", 5)
                found = True
    if not found:
        entry = {"type": "command", "command": command, "timeout": 5}
        group = {"matcher": "", "hooks": [entry]} if event in ("PreToolUse", "PostToolUse") else {"hooks": [entry]}
        groups.append(group)
        added.append(event)
    hooks[event] = groups

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path), prefix=".settings.", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, settings_path)
print("  hooks: " + (", ".join(added) if added else "已存在，已更新路径"))
PY

say "配置 zsh 包装函数..."
rc=0
zshrc_ok=1
/usr/bin/python3 - "$ZSHRC" "$PET_DIR/pet_wrapper.zsh" "$PET_DIR" <<'PY' || rc=$?
import os, re, shlex, shutil, sys, tempfile

zshrc, wrapper_path, pet_dir = sys.argv[1], sys.argv[2], sys.argv[3]
start, end = "# >>> CodexPet >>>", "# <<< CodexPet <<<"
with open(wrapper_path, encoding="utf-8") as fh:
    block = fh.read().strip("\n")
default_dir = os.path.join(os.path.expanduser("~"), ".claude", "pet")
if os.path.abspath(pet_dir) != os.path.abspath(default_dir):
    block = "export CODEX_PET_DIR=" + shlex.quote(pet_dir) + "\n" + block
block = start + "\n" + block + "\n" + end + "\n"

existing = ""
if os.path.exists(zshrc):
    with open(zshrc, encoding="utf-8") as fh:
        existing = fh.read()

pattern = re.compile(r"(?ms)^" + re.escape(start) + r".*?^" + re.escape(end) + r"\n?")
if pattern.search(existing):
    text = pattern.sub(lambda _: block, existing)
elif re.search(r"(?m)^\s*(?:function\s+)?claude\s*\(\s*\)", existing):
    print("  检测到已有 claude() 函数，未修改 " + zshrc)
    print("  请参考 " + wrapper_path + " 手动合并，或在卸载后重装")
    sys.exit(2)
else:
    text = existing.rstrip("\n")
    text = (text + "\n\n" if text else "") + block

os.makedirs(os.path.dirname(zshrc), exist_ok=True)
if os.path.exists(zshrc):
    shutil.copy2(zshrc, zshrc + ".pet-backup")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(zshrc), prefix=".zshrc.", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, zshrc)
print("  写入 " + zshrc + "（原文件备份为 .pet-backup）")
PY
if (( rc == 2 )); then
  zshrc_ok=0
  say "⚠ 未自动写入 zshrc，其余步骤已完成"
elif (( rc != 0 )); then
  die "zshrc 写入失败"
fi

say ""
say "✓ 安装完成"
say "  程序：$PET_DIR/bin/CodexPet"
say "  启停：$PET_DIR/petctl.sh {start|stop|restart|status}"
say "  卸载：$PET_DIR/uninstall.sh [--purge]"
if [[ "${SHELL##*/}" != "zsh" ]]; then
  say "  当前 shell 不是 zsh，包装函数已写入 $ZSHRC，请自行适配"
fi
if (( zshrc_ok )); then
  say "  新开终端或执行 source $ZSHRC 后，运行 claude 即可召唤宠物"
else
  say "  手动合并 $PET_DIR/pet_wrapper.zsh 到 $ZSHRC 后，运行 claude 即可召唤宠物"
fi
