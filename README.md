# Codex Pet for Claude Code

一个 macOS 透明置顶浮窗宠物，跟随 Claude Code 的实时状态切换动画、显示思考气泡与会话信息。多会话共享同一个宠物窗口，会话状态互相独立。

> 本仓库只包含框架代码。角色美术素材、会话运行数据与本地配置不在公开库中，需自备精灵表后构建。

## 快速开始

```zsh
git clone https://github.com/DylanYeung0929/codex-pet-framework.git ~/.claude/pet
cd ~/.claude/pet
# 把 Codex hatch-pet V2 精灵表放到 source/atlas.webp
./install.sh
```

安装脚本会构建 `bin/CodexPet`、合并 `~/.claude/settings.json` 的 hooks、向 `~/.zshrc` 写入带标记的 `claude()` 包装函数。完成后新开终端运行 `claude` 即可。

- 自定义位置：`CODEX_PET_DIR=~/somewhere ./install.sh`（安装器会把该路径写进 zshrc）
- 启停：`~/.claude/pet/petctl.sh start|stop|restart|status`
- 卸载：`~/.claude/pet/uninstall.sh`，加 `--purge` 一并删除统计与窗口状态
- 临时禁用（不卸载）：`export CODEX_PET_DISABLED=1`

## 预览

以下动图直接由精灵表帧生成，展示各状态对应的动作：

| 待机 | 思考 | 搜索（照片轮盘） |
|:---:|:---:|:---:|
| <img src="demo/idle.gif" width="130"> | <img src="demo/review.gif" width="130"> | <img src="demo/running.gif" width="130"> |

| 运行工具 | 等待回复 | 完成 |
|:---:|:---:|:---:|
| <img src="demo/debug.gif" width="130"> | <img src="demo/waiting.gif" width="130"> | <img src="demo/waving.gif" width="130"> |

| 失败 | 拖动骑行 |
|:---:|:---:|
| <img src="demo/failed.gif" width="130"> | <img src="demo/running-right.gif" width="130"> |

## 功能

- **状态动作**：思考 / 搜索 / 工具 / 等待 / 完成 / 失败 / 空闲分别映射到不同动画，可在右键「状态动画」中逐项自定义，映射持久化，也可一键恢复默认。
- **多会话聚合**：同时运行多个 `claude` 会话时按优先级（等待输入 > 工具 > 失败 > 思考 > 完成 > 空闲）展示最需关注的会话，置顶会话活跃时优先展示；悬停徽章逐行列出各会话「聊天名 · 状态 · 上下文%」。
- **气泡**：非悬停最多 3 行、悬停最多 5 行；显示聊天名、状态、上下文占用、思考内容、工具命令摘要或通知消息；多会话超出时末行标注「还有 N 个」。气泡、悬停徽章与统计卡使用系统液态玻璃（macOS 26+，深色衬底保证可读性）。
- **悬停徽章**：玻璃卡显示所用模型、上下文占用、API 余额、火山引擎余额（读取 `~/.config/ark/env`）、今日 tokens（扫描 `~/.claude/projects` 当日 transcript，按 message.id 去重累计）。
- **预警**：余额低于阈值、或上下文占用越过阈值时气泡提示并播放提示音（各只提醒一次，回落后重置）。
- **红点角标**：存在等待输入或失败的会话时右上角显示红点。
- **空闲半透明**：无活跃任务且未悬停时按「空闲透明度」淡出（默认 60%，右键菜单可选 25%–100%），待机动画半速播放、刷新降至 15fps。
- **提示音**：完成 / 失败 / 等待回复 / 余额不足四组可分别选音，选中即试听；音量 10%–200%，超过 100% 用采样增益突破系统上限。勿扰模式只静音提醒，视觉提示照常。
- **字号**：右键「字号」可选小 / 标准 / 大 / 特大，作用于气泡、悬停徽章与统计卡；内边距、圆角与行距随字号等比缩放，选择持久化。
- **完成用时**：完成气泡显示本轮从提交到 Stop 的耗时。
- **思考力度**：会话子菜单打开滑块，松开后立即向该会话发送原生 `/effort`，即时生效、无需重启。
- **历史统计**：按天归档完成数、失败数、活跃时长与 tokens，保留 30 天；今日统计卡附 7 天走势，右键「近 7 天统计」可查看逐日完成 / 失败 / tokens 列表卡。
- **互动**：双击宠物随机播放欢呼动作；⌥⌘P 全局显示 / 隐藏宠物，可在右键菜单关闭该快捷键；注册失败时自动关闭并在菜单标注。
- **交互**：左键点击按 tty 聚焦对应终端标签；拖动时按水平方向播放左右骑行动画；右键菜单调节大小、字号、动画速度、显示项、锁定位置等。
- **单例**：通过 `run/pet.pid` 锁保证只有一个宠物进程；所有会话消失前挥手告别，8 秒后自动退出。

### 会话管理

右键「会话」列出所有活跃会话，子菜单内：

- **上下文**：显示该会话当前上下文占用百分比与 used / window，下一行显示所用模型与本轮已运行时长（完成后改为上一轮用时）。
- **聚焦终端**：按 tty 选中对应的 Terminal 或 iTerm2 标签页。
- **复制会话 UUID**：把该会话的 resume UUID 写入剪贴板。
- **复制恢复命令**：按所选模型生成 `cd <目录> && claude --resume <UUID> [--model …]` 并写入剪贴板；该会话已关闭个人审查时附带 `--dangerously-skip-permissions`。
- **置顶会话**：把该会话固定在其他会话之前展示，状态为空闲或完成时不抢占优先级；选择持久化，再次点击取消。
- **思考力度**：显示该会话当前力度，点击「调整思考力度…」打开滑块（低 / 中 / 高 / 超高 / 最高）。松开后立即向该会话的终端标签发送原生 `/effort <level>`，与手动输入等效，无需重启；会话正在等待权限确认或计划审批时不会注入。
- **恢复会话**：运行 `claude --resume <UUID>`，可选择最近使用过的模型；「官方模型」小节列出当前 API 供应商 `/v1/models` 返回、但最近未用过的模型（10 分钟后台缓存，失败静默忽略）。新窗口优先开在当前前台终端，否则用最近会话对应的终端。执行前会提示先在旧终端退出，避免两个进程同时写入同一份会话记录。
- **个人审查**：逐会话控制工具权限确认，只影响你修改的那一个会话。关闭后把该会话 UUID 写入 `review_off.txt`；确认重启后，宠物会结束该会话的 Claude 进程，并由包装函数在同一终端自动 `claude --resume <UUID>`（保留模型与力度）。包装函数只在 `--resume <该 UUID>` 时追加 `--dangerously-skip-permissions`，其他会话不受影响。该开关不改变计划审批与你主动发起的提问。若该会话由旧版包装函数启动，宠物会提示无法自动重启且不会结束进程；请换到新开的终端会话。

### 生图模型

右键「生图模型」从 `~/.config/ark/env` 读取 `ARK_IMAGE_MODEL`，列出火山方舟图像模型、官方价格与下线状态；选择后写回该文件，并提供手动刷新与官方定价链接。缺少凭证文件时菜单显示提示，不影响其他功能。

## 目录结构

```
CodexPet.swift     AppKit 浮窗主程序（单文件）
pet_hook.py        Claude Code hooks → 状态文件桥
pet_wrapper.zsh    zsh claude() 包装函数（由 install.sh 写入 ~/.zshrc）
install.sh         一键安装：构建 + hooks + zshrc
uninstall.sh       卸载 hooks 与包装函数（--purge 删除整个目录）
petctl.sh          宠物进程控制：start / stop / restart / status
build_assets.py    精灵表切帧工具（生成 assets/manifest.json 与逐帧 PNG）
build.sh           构建脚本
config.json        上下文窗口与预警阈值
LICENSE            MIT
source/            放置 atlas.webp（不入库）
```

## 依赖

- macOS 26+（使用 `NSGlassEffectView` 液态玻璃；若需支持旧系统，可移除玻璃分支改用深色卡片回退）
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

`./install.sh` 会自动完成下面的 Hook 桥与包装函数配置，并保留原文件为 `.pet-backup`。如需手动配置或排查问题，见下。

### 1. Hook 桥

在 `~/.claude/settings.json` 注册以下 hooks（命令里的路径按实际位置修改）：

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

在 `~/.zshrc` 末尾添加一行（`pet_wrapper.zsh` 会按 `CODEX_PET_DIR` 定位，默认 `~/.claude/pet`）：

```zsh
source ~/.claude/pet/pet_wrapper.zsh
```

安装器写入的是带 `# >>> CodexPet >>>` / `# <<< CodexPet <<<` 标记的块，卸载时可精确移除。若 `~/.zshrc` 里已有其他来源的 `claude()` 函数，安装器只提示不覆盖，需手动合并。

包装函数还支持宠物写入的一次性 `run/<id>.restart` 标记：Claude 退出后在原终端按标记自动执行 `claude --resume <UUID>`，可带 `--model`、`--effort` 与 `--dangerously-skip-permissions`；只影响该会话。新版包装函数会写 `run/<id>.restartable` 就绪标记，缺少该标记的旧会话不会被自动重启。

已打开的旧终端不会自动加载新函数，需新开终端或 `source ~/.zshrc`。

## 配置

`config.json`：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `contextWindow` | 1000000 | 上下文百分比的分母，需与模型实际窗口一致（如 DeepSeek Flash 为 1M） |
| `balanceAlert` | 5 | 余额低于该值（元）提醒一次 |
| `contextAlert` | 0.8 | 上下文占用达到该比例提醒一次 |

余额接口：读取 `~/.claude/settings.json` 里 env 的 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL`，host 含 `deepseek` 时请求 `/user/balance`，60 秒缓存。

使用非 Anthropic 模型时，还需在 `~/.claude/settings.json` 的 `env` 中设置 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`（如 DeepSeek Flash 为 `"1000000"`），否则 Claude Code 会对未识别模型按 200k 计算并过早自动压缩；修改后需新开会话生效。

其他状态（窗口位置、大小、速度、动画映射、音效、显示开关）保存在 `window.json`，运行数据在 `run/`、`stats.json`，均不入库。

## 启动

```zsh
~/.claude/pet/petctl.sh start     # 也支持 stop / restart / status
```

手动启动时不要用 `open`——会弹出终端窗口，关窗时宠物一并被杀：

```zsh
nohup ~/.claude/pet/bin/CodexPet >/dev/null 2>&1 & disown
```

## 说明

- Hook 事件来自 stdin 的 `hook_event_name`；配置里的 `args` 不会转发。
- Notification 中「Claude is waiting for your input」是回合结束后的空闲提醒，映射为完成；只有权限请求类才映射为等待。
- 聊天名取自 Terminal 标签的 custom title 或 iTerm2 标签名，每 8 秒刷新；无 tty 信息时回退项目目录名。

## 隐私

公开仓库不包含：角色美术素材（`source/*.webp`、`assets/`）、会话运行数据（`run/`）、统计与窗口状态（`stats.json`、`window.json`）、个人审查开关记录（`review_off.txt`）、构建产物与缓存。代码本身不含个人标识信息。

## 许可证

[MIT](LICENSE)
