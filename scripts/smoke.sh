#!/usr/bin/env bash
# 冒烟：goal.sh init 一个临时项目 → 起 deveco serve → 确认插件真的加载了，
# 并（依 docs/probe-notes.md 问题 (2)(3) 的实测结论）走一遍 /goal 命令拦截链路。
set -euo pipefail

# Windows(Git Bash / MSYS)适配:没有 lsof,用 netstat/taskkill;python 叫 python.exe
IS_WINDOWS=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; esac

# python3/python 兼容(Windows 官方安装器只有 python.exe,没有 python3)
PYTHON="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

# 端口工具:列出监听 PID / 按端口杀 / 是否在监听。
# Windows 的 netstat 输出:TCP  0.0.0.0:4097  0.0.0.0:0  LISTENING  1234
_port_pids() {
  if [ "$IS_WINDOWS" = "1" ]; then
    netstat -ano 2>/dev/null | awk -v port=":$1" \
      '$1=="TCP" && $4=="LISTENING" { n=split($2,a,":"); if (":" a[n] == port) print $5 }' | sort -u
  else
    lsof -ti:"$1" 2>/dev/null || true
  fi
}
_port_kill() {
  local pid
  for pid in $(_port_pids "$1"); do
    if [ "$IS_WINDOWS" = "1" ]; then
      # 双斜杠防 MSYS 把 /F 当路径转换
      taskkill //F //PID "$pid" >/dev/null 2>&1 || true
    else
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}
_port_listening() { [ -n "$(_port_pids "$1")" ]; }

[ -n "$PYTHON" ] || { echo "❌ 需要 python3(或 python),请先安装 Python"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-4099}"
WORK="$(mktemp -d /tmp/goal-smoke-XXXXXX)"

# server 只能按端口杀：真正监听的是 deveco serve fork 出的子进程（lesson2 经验）
cleanup() {
  _port_kill "$PORT"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

"$HERE/goal.sh" init "$WORK" >/dev/null

# 一设这个变量 serve 就开 basic auth，插件内 client 会 401（lesson2 坑 #4）
unset DEVECO_SERVER_PASSWORD || true
_port_kill "$PORT"
( cd "$WORK" && nohup deveco serve --port "$PORT" > serve.log 2>&1 & )
for _ in $(seq 1 25); do
  _port_listening "$PORT" && break
  sleep 1
done
_port_listening "$PORT" || { echo "❌ server 没起来"; cat "$WORK/serve.log"; exit 1; }

# 整条管线用 `|| true` 兜底：curl|"$PYTHON" 任一段非零（server 返回错误体导致
# python3 KeyError 等）在 pipefail 下会让这次赋值本身失败，set -e 会在这一行
# 直接把脚本杀掉，导致下面 [ -n "$SID" ] 的诊断分支（dump serve.log）永远走不到。
SID=$(curl -s -m 30 -X POST "http://127.0.0.1:$PORT/session?directory=$WORK" \
  -H 'Content-Type: application/json' -d '{"title":"goal-smoke"}' \
  | "$PYTHON" -c "import sys,json;print(json.load(sys.stdin)['id'])" || true)
[ -n "$SID" ] || { echo "❌ 建会话失败"; cat "$WORK/serve.log"; exit 1; }

# docs/probe-notes.md 问题 (3)：插件是在「首个会话创建时」才实例化加载的，
# 不是 server 启动时；所以加载信号的 grep 必须放在建会话之后，这里的 sleep
# 是留给插件工厂函数 + 写日志的时间。
sleep 2
grep -q "devecocode-goal-plugin loaded" "$WORK/.deveco/goals/plugin.log" 2>/dev/null \
  || { echo "❌ 插件没加载（.deveco/goals/plugin.log 无加载记录）"; cat "$WORK/serve.log"; exit 1; }
# ${SID} 的花括号不能省：紧跟其后是全角右括号，macOS bash 3.2 会把它当成变量名的一部分
# （goal.sh 的 install_file 里也有同样的坑，见其注释）
echo "✅ 插件已被 deveco 发现并加载（session ${SID}）"

# ── /goal 命令拦截链路（依 docs/probe-notes.md 问题 (2)(1) 结论）──────────
# 问题 (2)：POST /session/{id}/command?directory=<dir>，body
# {"command":"<name>","arguments":"..."} 会返回 200 并真的触发
# command.execute.before（探针 A 路验证过），所以这里直接用它触发 `/goal status`。
#
# 问题 (1) 的 caveat：deveco 0.1.1 下，command.execute.before 里对
# output.parts 的写入并没有进入最终持久化的响应——命令触发之后依然会走一整轮
# 真实模型对话（探针实测 ~8s、12k input tokens），意味着：
#   (a) 命令调用本身的 HTTP 响应体不一定就是插件想返回的文本；
#   (b) 即使 output.parts 这次生效了，上游 /goal status 的实现本身也会在
#       "无活跃目标"时继续把请求交给模型续写一轮，所以持久化的会话消息里
#       也不保证一定原样出现 "No active goal"。
# 两个位置哪个都不能单独确定为"标准答案"，所以断言设计成防御性的：命令调用后
# 先直接看 HTTP 响应体，没找到就转去轮询 GET /session/$SID/message?directory=$WORK
# 落盘的消息列表（给真实模型轮次留够时间，最多轮询到 ~60s），只要任一处出现
# 预期文本 "No active goal" 就算通过；如果两处都没有，才判定为真失败，把两份
# 原始数据都 dump 到 stderr 方便排障。
OUT=$(curl -s -m 30 -X POST "http://127.0.0.1:$PORT/session/$SID/command?directory=$WORK" \
  -H 'Content-Type: application/json' -d '{"command":"goal","arguments":"status"}')

FOUND=0
MATCH_SOURCE=""
MATCH_LINE=""
MATCH_LINE=$(echo "$OUT" | grep -m1 "No active goal" || true)
if [ -n "$MATCH_LINE" ]; then
  FOUND=1
  MATCH_SOURCE='命令响应体（$OUT，直接 POST .../command 的返回）'
fi

# 轮询用 `MSGS=$(curl ... || true)` 兜底：单次 curl 瞬时失败（超时/连接被
# 重置）不能让 set -e 直接中断整个 30 次轮询——必须能落到 sleep 后重试，
# 且轮询结束后仍要能走到下面的诊断 dump，而不是被 set -e 提前带走。
MSGS=""
if [ "$FOUND" -eq 0 ]; then
  for _ in $(seq 1 30); do
    MSGS=$(curl -s -m 30 "http://127.0.0.1:$PORT/session/$SID/message?directory=$WORK" || true)
    MATCH_LINE=$(echo "$MSGS" | grep -m1 "No active goal" || true)
    if [ -n "$MATCH_LINE" ]; then
      FOUND=1
      MATCH_SOURCE='落盘会话消息（$MSGS，轮询 GET .../message 命中）'
      break
    fi
    sleep 2
  done
fi

if [ "$FOUND" -eq 0 ]; then
  echo "❌ /goal status 没有走到插件拦截（命令响应体和落盘消息里都没有 'No active goal'）" >&2
  echo "--- command response (curl POST .../command) ---" >&2
  echo "$OUT" >&2
  echo "--- session messages (curl GET .../message) ---" >&2
  echo "${MSGS:-<never fetched: 命令响应体已命中，未走到轮询>}" >&2
  exit 1
fi
# 命中来源可审计：明确是哪条路径（直接响应 vs 轮询落盘消息）命中的，以及命中的原始行，
# 而不是只有一个内部 FOUND 标记——见评审 Important #1。
# 同 ${SID} 的坑：$MATCH_SOURCE 后面紧跟全角右括号，必须加花括号，
# 否则 macOS bash 3.2 会把 ） 吞进变量名（见上文 ${SID} 处的注释）
echo "✅ /goal 命令拦截链路通（命中来源：${MATCH_SOURCE}）"
echo "   命中行：$MATCH_LINE"
