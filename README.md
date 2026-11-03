# Codex Pet for Claude Code

一个 macOS 透明置顶浮窗宠物，跟随 Claude Code 的实时状态切换动画、显示思考气泡与会话信息。多会话共享同一个宠物窗口，会话状态互相独立。

> 本仓库只包含框架代码。角色美术素材、会话运行数据与本地配置不在公开库中，需自备精灵表后构建。

## 功能

- **状态动作**：思考 / 搜索 / 工具 / 等待 / 完成 / 失败 / 空闲分别映射到不同动画，可在右键「状态动画」中逐项自定义，映射持久化。
- **多会话聚合**：同时运行多个 `claude` 会话时按优先级（等待输入 > 工具 > 思考 > 完成 > 空闲）展示最需关注的会话；悬停徽章逐行列出各会话「聊天名 · 状态 · 上下文%」。
- **气泡**：非悬停最多 3 行、悬停最多 5 行；显示聊天名、状态、思考内容、工具命令摘要或通知消息。
- **悬停徽章**：深色玻璃卡显示上下文占用、API 余额、今日 tokens（扫描 `~/.claude/projects` 当日 transcript，按 message.id 去重累计）。
- **预警**：余额低于阈值、或上下文占用越过阈值时气泡提示并播放提示音（各只提醒一次，回落后重置）。
- **红点角标**：存在等待输入或失败的会话时右上角显示红点。
- **空闲半透明**：无活跃任务且未悬停时窗口变为 45% 不透明度。
- **提示音**：完成 / 失败 / 等待回复 / 余额不足四组可分别选音，选中即试听；音量 10%–200%，超过 100% 用采样增益突破系统上限。
- **交互**：左键点击按 tty 聚焦对应终端标签；拖动时按水平方向播放左右骑行动画；右键菜单调节大小、动画速度、显示项、锁定位置等。
- **单例**：通过 `run/pet.pid` 锁保证只有一个宠物进程；所有会话消失 8 秒后自动退出。

## 目录结构

```
CodexPet.swift     AppKit 浮窗主程序（单文件）
pet_hook.py        Claude Code hooks → 状态文件桥
build_assets.py    精灵表切帧工具（生成 assets/manifest.json 与逐帧 PNG）
build.sh           构建脚本
config.json        上下文窗口与预警阈值
source/            放置 atlas.webp（不入库）
```

## 依赖

- macOS 12+
- Xcode Command Line Tools（`swiftc`）
- Python 3 + Pillow
- `webpmux`（可选，仅逐动作 webp 回退流程需要）

## 构建

```zsh
cd ~/.claude/pet
python3 -m pip install pillow   # 如未安装
./build.sh
```

产物为 `bin/CodexPet`。

### 素材

把 Codex hatch-pet V2 格式的精灵表放到 `source/atlas.webp`：8 列 × 11 行、单元 192×208，行序与帧数定义见 `build_assets.py` 的 `ATLAS_ROWS`（idle、右骑、左骑、招手、跳跃、失败、等待、照片轮盘、思考、调试机械臂、look）。`build_assets.py` 会按各行动画的联合透明包围盒裁剪并对齐，输出 `assets/<动作>/NNN.png` 与 `manifest.json`。

也可省略 atlas，改为在 `source/` 下按动作名放置独立 webp（`idle.webp`、`waving.webp` 等），脚本会走回退流程。

## 接入 Claude Code

### 1. Hook 桥

将 `pet_hook.py` 放到 `~/.claude/pet/`，在 `~/.claude/settings.json` 注册以下 hooks（命令里的路径按实际位置修改）：

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }],
    "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }],
    "PostToolUse":      [{ "matcher": "", "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "[ -n \"$CODEX_PET_ID\" ] && /usr/bin/python3 /Users/<you>/.claude/pet/pet_hook.py; true", "timeout": 5 }] }]
  }
}
```

`[ -n "$CODEX_PET_ID" ]` 守卫保证非宠物会话只启动一个 shell、零 Python 开销。

### 2. Shell 包装函数

在 `~/.zshrc` 末尾添加（路径按实际位置修改）：

```zsh
claude() {
  local pet="$HOME/.claude/pet/bin/CodexPet"
  local pet_id=""
  local show_pet=1
  [[ -t 1 ]] || show_pet=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      -p|--print|--version|-v|--help|-h) show_pet=0 ;;
    esac
  done
  if (( show_pet )) && [[ -x "$pet" && -z "$CODEX_PET_DISABLED" ]]; then
    pet_id="pet-$$-$RANDOM-$(date +%s)"
    mkdir -p "$HOME/.claude/pet/run"
    print -r -- $$ > "$HOME/.claude/pet/run/$pet_id.pid"
    print -r -- "${TERM_PROGRAM:-Apple_Terminal}|${TTY:-}" > "$HOME/.claude/pet/run/$pet_id.term"
    "$pet" >/dev/null 2>&1 &!
  fi
  local rc=0
  if [[ -n "$pet_id" ]]; then
    ( export CODEX_PET_ID="$pet_id"; command claude "$@" )
    rc=$?
    rm -f "$HOME/.claude/pet/run/$pet_id.json" "$HOME/.claude/pet/run/$pet_id.pid" "$HOME/.claude/pet/run/$pet_id.term"
  else
    command claude "$@"
    rc=$?
  fi
  return $rc
}
```

已打开的旧终端不会自动加载新函数，需新开终端或 `source ~/.zshrc`。停用宠物：`export CODEX_PET_DISABLED=1`。

## 配置

`config.json`：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `contextWindow` | 200000 | 上下文百分比的分母 |
| `balanceAlert` | 5 | 余额低于该值（元）提醒一次 |
| `contextAlert` | 0.8 | 上下文占用达到该比例提醒一次 |

余额接口：读取 `~/.claude/settings.json` 里 env 的 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL`，host 含 `deepseek` 时请求 `/user/balance`，60 秒缓存。

其他状态（窗口位置、大小、速度、动画映射、音效、显示开关）保存在 `window.json`，运行数据在 `run/`、`stats.json`，均不入库。

## 启动

```zsh
nohup ~/.claude/pet/bin/CodexPet >/dev/null 2>&1 & disown
```

不要用 `open` 启动裸可执行文件——会弹出终端窗口，关窗时宠物一并被杀。

## 说明

- Hook 事件来自 stdin 的 `hook_event_name`；配置里的 `args` 不会转发。
- Notification 中「Claude is waiting for your input」是回合结束后的空闲提醒，映射为完成；只有权限请求类才映射为等待。
- 聊天名取自 Terminal 标签的 custom title，每 8 秒刷新；无 tty 信息时回退项目目录名。

## 隐私

公开仓库不包含：角色美术素材（`source/*.webp`、`assets/`）、会话运行数据（`run/`）、统计与窗口状态（`stats.json`、`window.json`）、构建产物与缓存。代码本身不含个人标识信息。
