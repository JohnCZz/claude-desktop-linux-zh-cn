#!/usr/bin/env bash
set -Eeuo pipefail

# Claude Desktop Linux 简体中文统一维护脚本
# - 官方 /usr/lib/claude-desktop 永不修改
# - 每次从官方安装目录重建独立 overlay
# - 同步 javaht 最新 zh-CN 资源（失败时可用缓存）
# - 合并 i18n + 硬编码前端翻译
# - 合并旧 V1-V5 为一个统一 DOM 运行时，仅保留 1 个 MutationObserver/renderer
# - 不修改 app.asar，尽量保持 Cowork/KVM 兼容

LANG_CODE="zh-CN"
OFFICIAL="${CLAUDE_OFFICIAL_DIR:-/usr/lib/claude-desktop}"
BASE="${CLAUDE_ZH_BASE:-$HOME/.local/share/claude-desktop-plus}"
OVERLAY="$BASE/claude-overlay"
CACHE_ROOT="$HOME/.cache/claude-desktop-zh-cn"
REPO_CACHE="$CACHE_ROOT/javaht"
RESOURCE_CACHE="$CACHE_ROOT/resources"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
MAINT_BIN="$BIN_DIR/claude-desktop-zh-maintain"
LAUNCH_BIN="$BIN_DIR/claude-desktop-zh-cn"
DESKTOP_FILE="$APP_DIR/claude-desktop-zh-cn.desktop"
STATE_FILE="$BASE/unified-state.json"
LOG_DIR="$HOME/.local/state/claude-desktop-zh-cn"
KEEP_BACKUPS="${CLAUDE_ZH_KEEP_BACKUPS:-2}"

ACTION="apply"
OFFLINE=0
NO_LAUNCH=0

usage() {
  cat <<'EOF'
用法：
  claude_linux_zh_unified.sh [选项]

默认：重建当前已安装 Claude Desktop 的中文 overlay 并启动。

选项：
  --apply        重新汉化当前已安装版本（默认）
  --upgrade      先通过 apt 升级 claude-desktop，再重新汉化
  --status       查看官方版本、overlay 版本和补丁状态
  --rollback     回滚到本脚本最近一次完整 overlay 备份
  --offline      不联网，使用上次缓存的 javaht 中文资源
  --no-launch    完成后不自动启动 Claude
  -h, --help     显示帮助

升级后推荐只执行：
  claude-desktop-zh-maintain --apply

如希望“升级 + 重新汉化”一步完成：
  claude-desktop-zh-maintain --upgrade
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) ACTION="apply" ;;
    --upgrade) ACTION="upgrade" ;;
    --status) ACTION="status" ;;
    --rollback) ACTION="rollback" ;;
    --offline) OFFLINE=1 ;;
    --no-launch) NO_LAUNCH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$BASE" "$CACHE_ROOT" "$RESOURCE_CACHE" "$BIN_DIR" "$APP_DIR" "$LOG_DIR"

log() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

pkg_version() {
  dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || true
}

show_status() {
  local pv="$(pkg_version)"
  log "===== Claude Desktop 中文版状态 ====="
  log "官方目录：$OFFICIAL"
  log "官方包版本：${pv:-未检测到}"
  log "Overlay：$OVERLAY"
  if [[ -x "$OVERLAY/claude-desktop" ]]; then
    log "Overlay 主程序：存在"
  else
    log "Overlay 主程序：不存在"
  fi
  if [[ -f "$STATE_FILE" ]]; then
    log ""
    log "最近一次补丁状态："
    python3 - "$STATE_FILE" <<'PY' || true
import json, sys
p=sys.argv[1]
try:
    d=json.load(open(p,encoding='utf-8'))
except Exception as e:
    print(f"无法读取状态文件: {e}")
    raise SystemExit
for k in ["official_version","patched_at","upstream_commit","app_asar_sha256","hardcoded_files","hardcoded_replacements","runtime_entries"]:
    if k in d:
        print(f"  {k}: {d[k]}")
PY
  fi
  if [[ -L "$OVERLAY/chrome-sandbox" ]]; then
    log ""
    log "Sandbox：$(readlink "$OVERLAY/chrome-sandbox")"
    stat -Lc 'Sandbox 实际权限：owner=%U group=%G mode=%a' "$OVERLAY/chrome-sandbox" 2>/dev/null || true
  fi
}

if [[ "$ACTION" == "status" ]]; then
  show_status
  exit 0
fi

[[ -d "$OFFICIAL" ]] || die "找不到官方 Claude Desktop：$OFFICIAL"
[[ -x "$OFFICIAL/claude-desktop" ]] || die "找不到官方主程序：$OFFICIAL/claude-desktop"
[[ -f "$OFFICIAL/resources/app.asar" ]] || die "找不到官方 app.asar"
[[ -d "$OFFICIAL/resources/ion-dist/assets/v1" ]] || die "找不到官方 ion-dist/assets/v1，当前 Claude 目录结构可能已变化"
[[ -f "$OFFICIAL/chrome-sandbox" ]] || die "找不到官方 chrome-sandbox"

if [[ "$ACTION" == "rollback" ]]; then
  latest="$(find "$BASE" -maxdepth 1 -type d -name 'unified-backup-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
  [[ -n "$latest" && -d "$latest" ]] || die "没有找到本脚本创建的 unified-backup-* 备份"
  log "准备回滚：$latest"
  pkill -f "$OVERLAY/claude-desktop" 2>/dev/null || true
  sleep 2
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$OVERLAY" ]]; then
    mv "$OVERLAY" "$BASE/unified-failed-$stamp"
  fi
  mv "$latest" "$OVERLAY"
  log "✅ 已回滚到：$OVERLAY"
  if [[ "$NO_LAUNCH" -eq 0 && -x "$OVERLAY/claude-desktop" ]]; then
    nohup "$OVERLAY/claude-desktop" --lang="$LANG_CODE" >"$LOG_DIR/rollback-launch.log" 2>&1 &
    log "✅ 已启动回滚版本"
  fi
  exit 0
fi

if [[ "$ACTION" == "upgrade" ]]; then
  log "===== 先升级官方 Claude Desktop ====="
  sudo apt update
  sudo apt install -y --only-upgrade claude-desktop
  log "官方版本：$(pkg_version)"
fi

for cmd in python3 sha256sum tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：$cmd"
done

refresh_resources() {
  local required=(frontend-zh-CN.json frontend-hardcoded-zh-CN.json desktop-zh-CN.json statsig-zh-CN.json)
  if [[ "$OFFLINE" -eq 1 ]]; then
    for f in "${required[@]}"; do
      [[ -s "$RESOURCE_CACHE/$f" ]] || die "离线模式缺少缓存：$RESOURCE_CACHE/$f"
    done
    log "✅ 使用离线缓存中文资源"
    return
  fi

  log "===== 更新 javaht 中文资源 ====="
  local ok=0
  if command -v git >/dev/null 2>&1; then
    for attempt in 1 2 3 4 5; do
      log "Git 同步尝试 $attempt/5 ..."
      if [[ -d "$REPO_CACHE/.git" ]]; then
        if git -c http.version=HTTP/1.1 -C "$REPO_CACHE" fetch --depth 1 origin main \
          && git -C "$REPO_CACHE" reset --hard origin/main; then
          ok=1; break
        fi
      else
        rm -rf "$REPO_CACHE"
        if git -c http.version=HTTP/1.1 clone --depth 1 https://github.com/javaht/claude-desktop-zh-cn.git "$REPO_CACHE"; then
          ok=1; break
        fi
      fi
      sleep 3
    done
  fi

  if [[ "$ok" -eq 1 ]]; then
    for f in "${required[@]}"; do
      [[ -s "$REPO_CACHE/resources/$f" ]] || die "上游仓库缺少资源：$f"
      cp -f "$REPO_CACHE/resources/$f" "$RESOURCE_CACHE/$f"
    done
    git -C "$REPO_CACHE" rev-parse HEAD > "$RESOURCE_CACHE/upstream_commit.txt" 2>/dev/null || true
    log "✅ javaht 资源已更新"
    return
  fi

  log "Git 同步失败，尝试直接下载 4 个资源文件 ..."
  command -v curl >/dev/null 2>&1 || {
    log "⚠️ 未安装 curl，无法直接下载。"
    for f in "${required[@]}"; do [[ -s "$RESOURCE_CACHE/$f" ]] || die "无可用缓存：$f"; done
    log "⚠️ 使用旧缓存继续"
    return
  }

  local tmp="$CACHE_ROOT/download.$$"
  rm -rf "$tmp"; mkdir -p "$tmp"
  local dl_ok=1
  for f in "${required[@]}"; do
    if ! curl --http1.1 -fL --retry 12 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
      "https://raw.githubusercontent.com/javaht/claude-desktop-zh-cn/main/resources/$f" -o "$tmp/$f"; then
      dl_ok=0; break
    fi
  done
  if [[ "$dl_ok" -eq 1 ]]; then
    cp -f "$tmp"/* "$RESOURCE_CACHE/"
    printf 'raw-main-%s\n' "$(date -Iseconds)" > "$RESOURCE_CACHE/upstream_commit.txt"
    rm -rf "$tmp"
    log "✅ 中文资源已直接下载"
    return
  fi
  rm -rf "$tmp"

  for f in "${required[@]}"; do
    [[ -s "$RESOURCE_CACHE/$f" ]] || die "联网失败且没有可用缓存：$f"
  done
  log "⚠️ 上游下载失败，使用上次缓存继续"
}

refresh_resources

STAMP="$(date +%Y%m%d-%H%M%S)"
NEW_OVERLAY="$BASE/claude-overlay.new-$STAMP"
BACKUP="$BASE/unified-backup-$STAMP"
rm -rf "$NEW_OVERLAY"

export OFFICIAL NEW_OVERLAY RESOURCE_CACHE LANG_CODE

log "===== 从官方版本构建全新 overlay ====="
python3 <<'PY'
from __future__ import annotations
import hashlib, json, os, re, shutil, stat, sys, time
from pathlib import Path

src = Path(os.environ["OFFICIAL"])
dst = Path(os.environ["NEW_OVERLAY"])
cache = Path(os.environ["RESOURCE_CACHE"])
lang = os.environ.get("LANG_CODE", "zh-CN")

if dst.exists():
    shutil.rmtree(dst)

def ignore_root(path, names):
    # SUID chrome-sandbox 不复制到用户可写目录，稍后链接官方 root:4755 文件。
    if Path(path).resolve() == src.resolve():
        return {"chrome-sandbox"} if "chrome-sandbox" in names else set()
    return set()

print("复制官方 Claude 到临时 overlay ...", flush=True)
shutil.copytree(src, dst, symlinks=True, copy_function=shutil.copy2, ignore=ignore_root)

sandbox = src / "chrome-sandbox"
st = sandbox.stat()
mode = stat.S_IMODE(st.st_mode)
if st.st_uid != 0 or mode != 0o4755:
    raise SystemExit(f"官方 chrome-sandbox 权限异常：uid={st.st_uid}, mode={mode:o}；停止构建")
(dst / "chrome-sandbox").symlink_to(sandbox)

res = dst / "resources"
i18n = res / "ion-dist" / "i18n"
assets = res / "ion-dist" / "assets" / "v1"
if not i18n.is_dir() or not assets.is_dir():
    raise SystemExit("Claude 目录结构发生变化：缺少 ion-dist/i18n 或 assets/v1")

frontend_translation = cache / "frontend-zh-CN.json"
hardcoded_path = cache / "frontend-hardcoded-zh-CN.json"
desktop_translation = cache / "desktop-zh-CN.json"
statsig_translation = cache / "statsig-zh-CN.json"
for p in [frontend_translation, hardcoded_path, desktop_translation, statsig_translation]:
    if not p.is_file():
        raise SystemExit(f"缺少中文资源：{p}")

def load(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))

def save(p: Path, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(p)

def merge(base, trans):
    if isinstance(base, dict) and isinstance(trans, dict):
        out = dict(base)
        for k, v in trans.items():
            out[k] = merge(out[k], v) if k in out else v
        return out
    return trans

# 1) 语言白名单：先使用 javaht 当前规则，再使用更宽松的 locale-array fallback。
LANG_LIST_RE = re.compile(
    r'\["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]'
)
BASE = '["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'
replacement = BASE + ',"zh-CN"]'
whitelist_patched = None
js_files = sorted(assets.glob("*.js"))
for p in js_files:
    text = p.read_text(encoding="utf-8", errors="strict")
    if replacement in text:
        whitelist_patched = p.name
        break
    if LANG_LIST_RE.search(text):
        p.write_text(LANG_LIST_RE.sub(replacement, text, count=1), encoding="utf-8")
        whitelist_patched = p.name
        break

if whitelist_patched is None:
    # 未来版本可能增加 locale；只对同时含多个已知 locale 的短数组追加 zh-CN。
    arr_re = re.compile(r'\[(?:"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,4})?",?){6,}\]')
    known = {"en-US","de-DE","fr-FR","ko-KR","ja-JP","es-ES","it-IT","pt-BR"}
    for p in js_files:
        text = p.read_text(encoding="utf-8", errors="ignore")
        changed = False
        def repl(m):
            nonlocal_changed = None
            s = m.group(0)
            vals = set(re.findall(r'"([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,4})?)"', s))
            if len(vals & known) >= 5:
                if "zh-CN" in vals:
                    return s
                return s[:-1] + ',"zh-CN"]'
            return s
        patched, n = arr_re.subn(repl, text, count=1)
        if n and patched != text:
            p.write_text(patched, encoding="utf-8")
            whitelist_patched = p.name
            break

print(f"语言白名单：{whitelist_patched or '未定位（继续使用 --lang + DOM 运行时）'}", flush=True)

# 2) i18n 资源：以当前英文资源为骨架，中文覆盖，新增字段保留英文。
frontend_en = i18n / "en-US.json"
frontend_zh = i18n / "zh-CN.json"
if frontend_en.exists():
    save(frontend_zh, merge(load(frontend_en), load(frontend_translation)))
else:
    shutil.copy2(frontend_translation, frontend_zh)

desktop_en = res / "en-US.json"
desktop_zh = res / "zh-CN.json"
if desktop_en.exists():
    save(desktop_zh, merge(load(desktop_en), load(desktop_translation)))
else:
    shutil.copy2(desktop_translation, desktop_zh)

statsig_en = i18n / "statsig" / "en-US.json"
statsig_zh = i18n / "statsig" / "zh-CN.json"
statsig_zh.parent.mkdir(parents=True, exist_ok=True)
if statsig_en.exists():
    save(statsig_zh, merge(load(statsig_en), load(statsig_translation)))
else:
    shutil.copy2(statsig_translation, statsig_zh)

# 3) 语言显示名称。
label_patch = ';(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLinuxLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":n.call(this,e)},Object.defineProperty(e,"__claudeZhLinuxLabelPatch",{value:!0})})();'
index_files = sorted(assets.glob("index-*.js"))
for p in index_files:
    t = p.read_text(encoding="utf-8")
    if "__claudeZhLinuxLabelPatch" not in t:
        p.write_text(t + label_patch, encoding="utf-8")

# 4) javaht 硬编码文本替换（沿用其结构安全规则）。
raw_rules = load(hardcoded_path)
rules = []
for item in raw_rules:
    if isinstance(item, list) and len(item) == 2 and all(isinstance(x, str) for x in item):
        rules.append((item[0], item[1]))
rules.sort(key=lambda x: len(x[0]), reverse=True)

STRUCTURAL = {"hour","hours","minute","minutes","second","seconds","day","days","week","weeks","month","months","year","years"}
STRUCTURAL_LITERALS = {'"Search"'}
CTX = re.compile(r"(?<![A-Za-z0-9_$-])(?:as|component|displayName|glyph|icon|iconName|leadingIcon|name|role|trailingIcon|type)\s*[:=]\s*$")

def plain(s: str) -> bool:
    return "\n" not in s and not any(x in s for x in ['"','\\','=',';','=>'])

def replace_plain(text: str, source: str, target: str):
    pat = re.compile(r'(?P<quote>["\'`])' + re.escape(source) + r'(?P=quote)')
    count = 0
    def f(m):
        nonlocal count
        prefix = text[max(0, m.start()-96):m.start()]
        if CTX.search(prefix):
            return m.group(0)
        count += 1
        q = m.group('quote')
        return f"{q}{target}{q}"
    return pat.sub(f, text), count

patched_files = 0
patched_strings = 0
print(f"扫描硬编码前端：{len(js_files)} JS / {len(rules)} 规则", flush=True)
for idx, p in enumerate(js_files, 1):
    original = p.read_text(encoding="utf-8")
    text = original
    cnt = 0
    for source, target in rules:
        if source in STRUCTURAL or source in STRUCTURAL_LITERALS:
            continue
        if source not in text:
            continue
        if plain(source):
            text, n = replace_plain(text, source, target)
        else:
            n = text.count(source)
            if n:
                text = text.replace(source, target)
        cnt += n
    if text != original:
        p.write_text(text, encoding="utf-8")
        patched_files += 1
        patched_strings += cnt
    if idx % 250 == 0:
        print(f"  {idx}/{len(js_files)}，已替换 {patched_strings}", flush=True)
print(f"硬编码替换：{patched_strings} 次 / {patched_files} 文件", flush=True)

# 5) 构建统一 DOM 映射：i18n + hardcoded + V1-V5 扩展。
def collect_pairs(en, zh, out):
    if isinstance(en, dict) and isinstance(zh, dict):
        for k, ev in en.items():
            if k in zh:
                collect_pairs(ev, zh[k], out)
    elif isinstance(en, str) and isinstance(zh, str):
        s, t = en.strip(), zh.strip()
        if s and t and s != t and len(s) <= 1000 and "\n" not in s and "{" not in s:
            out[s] = t

mapping = {}
if frontend_en.exists():
    collect_pairs(load(frontend_en), load(frontend_zh), mapping)
for s, t in rules:
    if s and t and s != t and len(s) <= 1000 and "\n" not in s and "{" not in s:
        mapping[s.strip()] = t.strip()

# 用户当前 Linux Claude 版本中已观察到、但上游词表可能尚未覆盖的可见文本。
extras = {
    "New":"新建", "Customize":"自定义", "Overview":"概览", "Sessions":"会话", "Messages":"消息",
    "Total tokens":"Token 总数", "Active days":"活跃天数", "Current streak":"当前连续天数",
    "Longest streak":"最长连续天数", "Peak hour":"高峰时段", "Favorite model":"常用模型",
    "Sessions you start will show up here":"你启动的会话会显示在这里",
    "You've used about as many tokens as The Little Prince.":"你使用的 Token 数大约相当于《小王子》的篇幅。",
    "You’ve used about as many tokens as The Little Prince.":"你使用的 Token 数大约相当于《小王子》的篇幅。",
    "Select folder...":"选择文件夹...", "Select folder…":"选择文件夹…",
    "Describe a task or ask a question":"描述任务或提出问题", "Accept edits":"接受编辑",
    "Usage":"使用情况", "Import & export":"导入与导出", "Plugins":"插件",
    "Claude Light":"Claude 浅色", "Claude Dark":"Claude 深色", "System":"系统",
    "Small":"小", "Medium":"中等", "Large":"大", "Narrow":"窄", "Wide":"宽",
    "Local sessions":"本地会话", "Allow bypass permissions mode":"允许绕过权限检查模式",
    "Bypass all permission checks and let Claude work uninterrupted. This works well for workflows like fixing lint errors or generating boilerplate code. Letting Claude run arbitrary commands is risky and can result in data loss, system corruption, or data exfiltration (e.g., via prompt injection attacks).":"绕过所有权限检查，让 Claude 不受打断地工作。这适合修复代码检查错误、生成样板代码等工作流。但允许 Claude 任意执行命令存在风险，可能导致数据丢失、系统损坏或数据泄露，例如受到提示注入攻击时。",
    "See best practices for safe usage":"查看安全使用最佳实践",
    "Enable remote control by default":"默认启用远程控制",
    "Automatically connect new local sessions to Remote Control so you can continue them from the CLI or claude.ai/code.":"自动将新的本地会话连接到远程控制，以便你可以继续通过 CLI 或 claude.ai/code 操作这些会话。",
    "Dynamic workflows":"动态工作流",
    "Let Claude run multiple agents in parallel for complex tasks. Workflows can use a lot of your usage limit quickly.":"允许 Claude 针对复杂任务并行运行多个智能体。工作流可能会较快消耗你的使用额度。",
    "Draw attention on notifications":"通知时吸引注意",
    "Flash the app icon when Claude needs your attention and the app is not focused.":"当 Claude 需要你注意且应用当前未获得焦点时，让应用图标闪烁提醒。",
    "Worktree location":"工作树位置", "Where to store git worktrees for isolated coding sessions":"设置用于隔离编码会话的 Git worktree 存储位置",
    "Inside project":"项目内", "Code appearance":"代码外观", "Transcript width":"会话内容宽度",
    "Maximum width for transcripts and input boxes.":"设置会话内容和输入框的最大宽度。",
    "You're here!":"已准备就绪！", "You’re here!":"已准备就绪！", "Project or folder":"项目或文件夹",
    "Ideas for you":"为你推荐", "Send me a daily briefing":"为我生成每日简报", "Organize my inbox":"整理我的收件箱",
    "Customize Cowork for me":"为我自定义 Cowork",
    "Browser":"浏览器", "Browser tools":"浏览器工具",
    "Claude can start dev servers, open a live preview, and verify code changes with screenshots, snapshots, and DOM inspection.":"Claude 可以启动开发服务器、打开实时预览，并通过截图、快照和 DOM 检查验证代码修改。",
    "Persist sessions":"保留会话", "Don't keep":"不保留", "Don’t keep":"不保留", "Shared":"共享", "Separate":"独立",
    "Pull requests":"拉取请求", "Branch prefix":"分支前缀",
    "Prefix added to branch names for both local and cloud sessions":"为本地会话和云端会话创建的分支名称添加此前缀",
    "Automatically create pull requests":"自动创建拉取请求",
    "Cowork files":"Cowork 文件", "Your artifacts and scheduled tasks are stored at":"你的产物和计划任务存储在",
    "Change":"更改", "Trusted Cowork folders":"受信任的 Cowork 文件夹",
    "When you attach one of these folders to a Cowork task, Claude won’t ask you to confirm.":"当你将这些文件夹之一添加到 Cowork 任务时，Claude 将不再要求你确认。",
    "When you attach one of these folders to a Cowork task, Claude won't ask you to confirm.":"当你将这些文件夹之一添加到 Cowork 任务时，Claude 将不再要求你确认。",
    "Global instructions":"全局指令", "Instructions here apply to all Cowork sessions. Use this for preferences, conventions, or context that Claude should always know.":"这里的指令适用于所有 Cowork 会话。可在此设置希望 Claude 始终了解的偏好、约定或上下文。",
    "Use memory in sessions":"在会话中使用记忆", "Claude will read and update these memories during Cowork sessions.":"Claude 会在 Cowork 会话中读取并更新这些记忆。",
    "Claude saves what it learns about you and your work during Cowork sessions. These files are stored on this device.":"Claude 会保存它在 Cowork 会话中了解到的与你及你的工作有关的信息。这些文件存储在当前设备上。",
    "No memories yet. Claude will add entries here as you work together.":"目前还没有记忆。随着你与 Claude 一起工作，新的记忆条目会显示在这里。",
    "Token usage on this device across Chat, Cowork, and Code. Costs aren’t shown — your organization is billed at its own provider rates.":"此设备上 Chat、Cowork 和 Code 的 Token 使用情况。此处不显示费用，你的组织会按照其推理提供方的费率结算。",
    "Token usage on this device across Chat, Cowork, and Code. Costs aren't shown — your organization is billed at its own provider rates.":"此设备上 Chat、Cowork 和 Code 的 Token 使用情况。此处不显示费用，你的组织会按照其推理提供方的费率结算。",
    "Tokens per day":"每日 Token", "Input and output tokens by tab, last 30 days":"最近 30 天各模块的输入与输出 Token",
    "Import":"导入", "Import isn’t enabled for this deployment. Contact your organization’s administrator to turn it on.":"当前部署未启用导入功能。请联系你所在组织的管理员启用此功能。",
    "Import isn't enabled for this deployment. Contact your organization's administrator to turn it on.":"当前部署未启用导入功能。请联系你所在组织的管理员启用此功能。",
    "What Anthropic doesn’t see":"Anthropic 无法看到的内容", "What Anthropic doesn't see":"Anthropic 无法看到的内容",
    "Your prompts, Claude’s responses, or any conversation content":"你的提示词、Claude 的回复或任何对话内容",
    "Your prompts, Claude's responses, or any conversation content":"你的提示词、Claude 的回复或任何对话内容",
    "Your files, code, or workspace contents":"你的文件、代码或工作区内容", "Your identity or account details":"你的身份信息或账户详情",
    "What Anthropic may receive (configured by your organization)":"Anthropic 可能接收的内容（由你的组织配置）",
    "Crash reports and error diagnostics, so we can fix bugs":"崩溃报告和错误诊断信息，用于修复问题",
    "Anonymous usage metrics including usage counts (not conversation content)":"匿名使用统计信息，包括使用次数，但不包含对话内容",
    "Update-check requests, so the app can stay current":"更新检查请求，用于保持应用为最新版本",
    "A diagnostic report, only if you explicitly choose “Send to Anthropic”":"诊断报告，仅在你明确选择“发送给 Anthropic”时提交",
    "What's new":"新增功能", "What’s new":"新增功能",
    "These release notes are included with this version of the app and may be one release behind.":"这些发行说明随当前版本附带，内容可能比最新版本落后一个版本。",
    "See the online changelog for the latest.":"最新内容请查看在线更新日志。",
    "IMPROVED":"改进", "FIXED":"修复", "NEW":"新增", "Effort":"思考强度",
    "Higher effort means more thorough responses, but takes longer and uses your limits faster.":"更高的思考强度通常会带来更充分的回答，但耗时更长，也会更快消耗使用额度。",
    "Low":"低", "High":"高", "Extra":"更高", "Max":"最高", "Default":"默认"
}
mapping.update(extras)

# 统一运行时：1 个 guard + 1 个 MutationObserver / renderer。
M = json.dumps(mapping, ensure_ascii=False, separators=(",", ":"))
marker = "CLAUDE_ZH_CN_LINUX_UNIFIED_V1"
runtime = r'''
;/*__MARKER__*/(()=>{try{
if(window.__claudeZhLinuxUnifiedV1)return;window.__claudeZhLinuxUnifiedV1=1;
const L="zh-CN",M=__MAP__;
try{localStorage.setItem("spa:locale",L);document.documentElement&&document.documentElement.setAttribute("lang",L)}catch{}
const N=s=>(s||"").replace(/\s+/g," ").trim();
const G=[
[/^(?:What's|What’s) up next,\s*(.+)\?$/,"接下来做什么，$1？"],
[/^(\d+)\s+web searches?$/,"$1 次网页搜索"],
[/^(\d+)d$/,"$1天"],
[/^Inside project(.*)$/,"项目内$1"],
[/^You're running Claude through your organization's own inference provider \((.+?)\)\. Your conversations are sent there, not to Anthropic, and are governed by your organization's agreement with that provider\.$/,"你正在通过所在组织自己的推理提供方（$1）运行 Claude。你的对话会发送到该提供方，而不是 Anthropic，并受你所在组织与该提供方之间协议的约束。"],
[/^You’re running Claude through your organization’s own inference provider \((.+?)\)\. Your conversations are sent there, not to Anthropic, and are governed by your organization’s agreement with that provider\.$/,"你正在通过所在组织自己的推理提供方（$1）运行 Claude。你的对话会发送到该提供方，而不是 Anthropic，并受你所在组织与该提供方之间协议的约束。"],
[/^Updated (\d+) minutes? ago$/,"$1 分钟前更新"],[/^Updated (\d+) hours? ago$/,"$1 小时前更新"],
[/^Updated (\d+) days? ago$/,"$1 天前更新"],[/^Updated (\d+) weeks? ago$/,"$1 周前更新"],
[/^Updated (\d+) months? ago$/,"$1 个月前更新"],[/^Updated (\d+) years? ago$/,"$1 年前更新"]
];
const R=s=>{const n=N(s);if(!n)return;const e=M[n];if(e)return e;for(const [r,t] of G){const m=n.match(r);if(m){let o=t;for(let i=1;i<m.length;i++)o=o.replace("$"+i,m[i]??"");return o}}};
const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]),C="pre,code,kbd,samp,var,[data-language],[data-testid*=code],.cm-editor,.monaco-editor,.hljs",P='[data-testid="user-message"],.standard-markdown,.progressive-markdown,[data-testid="chat-input"],[data-testid="conway-composer-input"],[data-testid="conway-user-message"] .user-bubble,[data-testid="conway-output-cell"]';
const Q=n=>{const e=n&&n.nodeType===1?n:n?.parentElement;return !!(e&&e.closest(P))};
const H=n=>Q(n)||!!(n&&n.nodeType===1&&n.querySelector?.(P));
function W(root){try{if(!root)return;if(root.nodeType===3){const p=root.parentElement;if(!p||X.has(p.tagName)||p.closest('[contenteditable],textarea,'+C)||Q(root))return;const v=R(root.nodeValue);if(v)root.nodeValue=v;return}if(root.nodeType!==1&&root.nodeType!==9)return;const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode(n){const p=n.parentElement;if(!p||X.has(p.tagName)||p.closest('[contenteditable],textarea,'+C)||Q(n)||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}});let n;while(n=w.nextNode()){const v=R(n.nodeValue);if(v)n.nodeValue=v}if(root.querySelectorAll){const els=[...(root.matches?.('[aria-label],[title],[placeholder]')?[root]:[]),...root.querySelectorAll('[aria-label],[title],[placeholder]')];for(const e of els){if(e.closest?.(C)||Q(e))continue;for(const a of ["aria-label","title","placeholder"]){const v=e.getAttribute?.(a),t=R(v);if(t)e.setAttribute(a,t)}}}}catch{}}
let due=0,timer=0;const RUN=()=>{due=0;W(document.body||document.documentElement)};const S=()=>{const now=Date.now();if(!due)due=now+250;clearTimeout(timer);timer=setTimeout(RUN,Math.max(0,Math.min(30,due-now)))};
RUN();new MutationObserver(ms=>{for(const m of ms){if(m.type==="characterData")W(m.target);else for(const n of m.addedNodes)W(n)}S()}).observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:false});
addEventListener("hashchange",S);addEventListener("popstate",S);setTimeout(RUN,500);setTimeout(RUN,1500);setTimeout(RUN,3500);
}catch{}})();
'''.replace("__MARKER__", marker).replace("__MAP__", M)

# 注入到所有 index-*.js；window guard 保证每个 renderer 最终只创建一个 Observer。
if not index_files:
    # 兼容少数版本：选最大的几个 JS 作为载入候选。
    index_files = sorted(js_files, key=lambda p: p.stat().st_size, reverse=True)[:3]
for p in index_files:
    t = p.read_text(encoding="utf-8")
    if marker not in t:
        p.write_text(t + runtime, encoding="utf-8")
print(f"统一 DOM 运行时：{len(mapping)} 条映射，注入 {len(index_files)} 个 index bundle（guard 仅启用 1 个 Observer/renderer）", flush=True)

# 6) 关键完整性：绝不修改 app.asar。
def sha256(p: Path):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()

official_asar = src / "resources" / "app.asar"
overlay_asar = dst / "resources" / "app.asar"
sha_off = sha256(official_asar)
sha_new = sha256(overlay_asar)
if sha_off != sha_new:
    raise SystemExit("安全检查失败：overlay app.asar 与官方 app.asar 不一致")

meta = {
    "language": lang,
    "app_asar_sha256": sha_new,
    "hardcoded_files": patched_files,
    "hardcoded_replacements": patched_strings,
    "runtime_entries": len(mapping),
    "language_whitelist_bundle": whitelist_patched,
}
(dst / ".claude-zh-meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2)+"\n",encoding="utf-8")
print("✅ 临时 overlay 构建和完整性检查通过", flush=True)
PY

# 写入版本/上游元数据到临时 overlay 元信息
OFFICIAL_VERSION="$(pkg_version)"
UPSTREAM_COMMIT="$(cat "$RESOURCE_CACHE/upstream_commit.txt" 2>/dev/null || echo unknown)"
APP_SHA="$(sha256sum "$OFFICIAL/resources/app.asar" | awk '{print $1}')"
export NEW_OVERLAY OFFICIAL_VERSION UPSTREAM_COMMIT APP_SHA
python3 <<'PY'
import json, os
from pathlib import Path
p=Path(os.environ['NEW_OVERLAY'])/'.claude-zh-meta.json'
d=json.loads(p.read_text(encoding='utf-8'))
d.update({
  'official_version': os.environ.get('OFFICIAL_VERSION',''),
  'upstream_commit': os.environ.get('UPSTREAM_COMMIT',''),
  'patched_at': __import__('datetime').datetime.now().astimezone().isoformat(timespec='seconds'),
  'app_asar_sha256': os.environ.get('APP_SHA','')
})
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY

log "===== 切换到新 overlay ====="
pkill -f "$OVERLAY/claude-desktop" 2>/dev/null || true
pkill -f '/usr/lib/claude-desktop/claude-desktop' 2>/dev/null || true
sleep 2

SWAPPED=0
restore_on_error() {
  rc=$?
  if [[ $rc -ne 0 && "$SWAPPED" -eq 1 ]]; then
    log "⚠️ 切换阶段失败，尝试自动恢复旧 overlay ..."
    rm -rf "$OVERLAY" 2>/dev/null || true
    if [[ -d "$BACKUP" ]]; then mv "$BACKUP" "$OVERLAY" || true; fi
  fi
  exit $rc
}
trap restore_on_error EXIT

if [[ -e "$OVERLAY" ]]; then
  mv "$OVERLAY" "$BACKUP"
  log "旧 overlay 已备份：$BACKUP"
fi
mv "$NEW_OVERLAY" "$OVERLAY"
SWAPPED=1

# 状态文件
cp -f "$OVERLAY/.claude-zh-meta.json" "$STATE_FILE"

# 清理本脚本创建的过老完整备份，仅保留 KEEP_BACKUPS 个。
mapfile -t OLD_BACKUPS < <(find "$BASE" -maxdepth 1 -type d -name 'unified-backup-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | tail -n +$((KEEP_BACKUPS+1)) | cut -d' ' -f2-)
for b in "${OLD_BACKUPS[@]:-}"; do
  [[ -n "$b" && -d "$b" ]] && rm -rf "$b"
done

# 安装维护脚本自身，方便升级后一句命令重跑。
SELF="$(readlink -f "$0")"
if [[ "$SELF" != "$MAINT_BIN" ]]; then
  install -m 0755 "$SELF" "$MAINT_BIN"
fi

cat > "$LAUNCH_BIN" <<EOF
#!/usr/bin/env bash
set -e
OVERLAY="$OVERLAY"
exec "\$OVERLAY/claude-desktop" --lang=zh-CN "\$@"
EOF
chmod 0755 "$LAUNCH_BIN"

ICON="$OVERLAY/resources/ion-dist/images/claude_app_icon.png"
[[ -f "$ICON" ]] || ICON="claude-desktop"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Claude Desktop 中文版
GenericName=AI Assistant
Comment=Claude Desktop 简体中文 Overlay
Exec=$LAUNCH_BIN
Icon=$ICON
Terminal=false
Categories=Network;Utility;Development;
StartupNotify=true
EOF
chmod 0644 "$DESKTOP_FILE"
update-desktop-database "$APP_DIR" 2>/dev/null || true

SWAPPED=0
trap - EXIT

log ""
log "✅ 统一汉化完成"
log "官方 Claude：$OFFICIAL_VERSION"
log "Overlay：$OVERLAY"
log "上游中文资源：$UPSTREAM_COMMIT"
log "app.asar：保持官方原始 SHA256 $APP_SHA"
log "统一运行时：仅 1 个 MutationObserver / renderer（window guard）"
log "维护命令：$MAINT_BIN"
log "启动命令：$LAUNCH_BIN"
log ""
log "以后 Claude 官方升级后，只需："
log "  claude-desktop-zh-maintain --apply"
log ""
log "如希望升级 + 汉化一步完成："
log "  claude-desktop-zh-maintain --upgrade"

if [[ "$NO_LAUNCH" -eq 0 ]]; then
  LAUNCH_LOG="$LOG_DIR/launch-$(date +%Y%m%d-%H%M%S).log"
  nohup "$LAUNCH_BIN" >"$LAUNCH_LOG" 2>&1 &
  pid=$!
  sleep 5
  if kill -0 "$pid" 2>/dev/null; then
    log "✅ Claude Desktop 中文版已启动（PID $pid）"
  else
    log "⚠️ Claude 启动进程已退出，请查看：$LAUNCH_LOG"
    tail -60 "$LAUNCH_LOG" 2>/dev/null || true
  fi
fi

show_status
