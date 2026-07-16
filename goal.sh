#!/usr/bin/env bash
# devecocode-goal-plugin for DevEco Code
#
#   ./goal.sh init <项目目录> [--update]   装：插件 + /goal 命令配置（改你的仓库）
#   ./goal.sh status <项目目录>            看目标状态（.deveco/goals/state.json）
#
# 装好后：cd <项目目录> && deveco ，会话里输入 /goal <目标>。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/template"

PLUGIN_ENTRY=".deveco/plugin/devecocode-goal-plugin.ts"
PLUGIN_DIR=".deveco/plugin/devecocode-goal-plugin"
VENDOR_FILES=(goal-plugin.js opencode-session-api.js native-agent-config.js completion-claim.js goal-tool-result.js persistence-lease.js index.d.ts LICENSE)

say() { printf "\033[1m%s\033[0m\n" "$*"; }
die() { echo "❌ $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
用法:
  $0 init   <项目目录> [--update]   装插件 + merge deveco.json 的 /goal 命令
  $0 status <项目目录>              看当前目标状态

  --update  重新覆盖项目里的插件文件（会丢掉你在项目里的改动）
EOF
  exit 1
}

install_file() {
  local f="$1" update="$2"
  if [ -f "$f" ] && [ "$update" = "0" ]; then
    if ! cmp -s "$TEMPLATE/$f" "$f"; then
      # ${f} 的花括号不能省：macOS 的 bash 3.2 会把紧跟其后的中文字符当成变量名的一部分
      say "→ 保留你改过的 ${f}（要覆盖成模板版本用 --update）"
    fi
    return 0
  fi
  cp "$TEMPLATE/$f" "$f"
  say "→ 装好 $f"
}

cmd_init() {
  local target="${1:-}" update=0
  shift || true
  for a in "$@"; do
    case "$a" in
      --update) update=1 ;;
      *) usage ;;
    esac
  done
  [ -n "$target" ] || usage

  mkdir -p "$target"
  target="$(cd "$target" && pwd)"
  cd "$target"

  # deveco 只认 .deveco/，放 .opencode/ 下是静默失效（lesson2 坑 #1）
  mkdir -p "$PLUGIN_DIR"
  install_file "$PLUGIN_ENTRY" "$update"
  local f
  for f in "${VENDOR_FILES[@]}"; do
    install_file "$PLUGIN_DIR/$f" "$update"
  done

  # /goal 命令必须注册在 deveco.json（$ARGUMENTS 模板）；插件只负责拦截执行。
  # 已有字段一律不覆盖——merge 而不是重写；model 只在 deveco.json 本来就不存在时才补默认值
  # （对齐 lesson2 ralph.sh 的语义：不会覆盖用户已有的项目级模型选择）。
  local had_deveco_json=1
  [ -f "$target/deveco.json" ] || had_deveco_json=0
  node - "$target" "$had_deveco_json" <<'JS'
const fs = require("fs")
const path = require("path")
const file = path.join(process.argv[2], "deveco.json")
const hadFile = process.argv[3] === "1"
const config = hadFile ? JSON.parse(fs.readFileSync(file, "utf-8")) : {}
if (!hadFile) {
  config.model = "deveco/GLM-5.1"
}
config.command ||= {}
config.command.goal ||= {
  description: "设定会话级目标并自动续推到完成",
  template: "$ARGUMENTS",
  agent: "build",
}
fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n")
JS
  if [ "$had_deveco_json" = "0" ]; then
    say "→ 生成 deveco.json（项目默认模型，已有 deveco.json 时不会碰你的 model 配置）"
  fi
  say "→ deveco.json 已 merge /goal 命令（已有字段不覆盖）"

  echo
  say "✅ 装好了: $target"
  say "   下一步: cd $target && deveco ，会话里输入 /goal <目标>"
}

cmd_status() {
  local target="${1:-}"
  [ -n "$target" ] || usage
  [ -d "$target" ] || die "$target 不存在"
  target="$(cd "$target" && pwd)"
  local state="$target/.deveco/goals/state.json"
  if [ ! -f "$state" ]; then
    say "还没有目标状态（${state} 不存在）——先在 deveco 会话里 /goal <目标>"
    return 0
  fi
  cat "$state"
}


case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) usage ;;
esac
