[English](README.md) | 简体中文

# devecocode-goal-plugin

给 DevEco Code 用的会话级 `/goal` 工作流。设一个目标,插件自己把活儿续下去:
挂上 `session.idle`,自动续推,直到**证据门控**判定完成——不用你手动喊「继续」。完成与否不是模型自己
说了算,而是插件用可核实的信号(工具调用记录、turn 数、耗时、token 消耗)去卡完成条件。

## 这是什么

- 在 DevEco Code 会话里输入 `/goal <目标>` 就给这个会话设了一个目标。插件监听 `session.idle`,自动
  注入续推轮次,直到目标达成或撞到 turn/时长/token 预算上限。
- 完成是靠模型调用 `update_goal` 工具、传 `status: "complete"` 和 `evidence` 来声明的,不是模型嘴上
  说"做完了"就算数。
- 状态落盘在项目里(`.deveco/goals/state.json`),所以 `/goal status` 和 `/goal history` 哪怕重启
  服务也能反映真实的生命周期。

## 前置要求

- DevEco Code 0.1.1 及以上(本仓库的适配是针对 0.1.1 实测验证的,其它版本行为不保证)。
- Node.js ≥18,用来跑测试套件(`node --test`)。
- `scripts/smoke.sh` 额外需要 Python 3(用来解析 `curl` 返回的 JSON)。
- **shell 里不能设 `DEVECO_SERVER_PASSWORD`。** 一设这个变量,`deveco serve` 就会开 basic auth,而
  插件内部的 client 不会带凭据去请求——插件回调 server 的每一次调用都会吃 401。
- Windows 用户:`goal.sh` 和 `scripts/smoke.sh` 都是 POSIX shell 脚本,走 Git Bash 运行。

## 安装

```bash
./goal.sh init <项目目录>
```

这条命令做的事:

1. 把插件入口(`.deveco/plugin/devecocode-goal-plugin.ts`)和 vendor 源文件(`goal-plugin.js`、
   `opencode-session-api.js`、`native-agent-config.js`、`completion-claim.js`、`goal-tool-result.js`、
   `persistence-lease.js`、`index.d.ts`、`LICENSE`)复制进
   `<项目目录>/.deveco/plugin/devecocode-goal-plugin/`。
2. 把 `/goal` 命令定义 merge 进 `<项目目录>/deveco.json`(不存在就新建)。已有字段一律不覆盖——
   `command.goal` 已经定义过就跳过;`deveco.json` 之前不存在时会补一个默认 `model`,但如果
   `deveco.json` 本来就存在,它的 `model` 字段绝不会被碰。
3. 项目里已经装过插件文件时,默认重跑 `init` **不会动你本地的改动**(只是打印一句提示)。要强制
   用模板版本覆盖已装文件(会丢掉你在这些文件里的本地改动),加 `--update`。

```bash
./goal.sh init <项目目录> --update   # 强制用模板覆盖已装的插件文件
```

## 用法

```bash
cd <项目目录> && deveco    # 起一个交互会话
```

会话里:

```
/goal <目标>       # 给这个会话设目标,自动续推随即开始
/goal status        # 看当前目标状态和预算用量
/goal history       # 看生命周期历史和最近一次 checkpoint
```

插件还注册了可供 agent 调用的工具:`get_goal`、`get_goal_history`、`set_goal`、`update_goal`——模型
自己用这些工具读写目标状态。冒烟实测确认过:没有活跃目标时,模型能准确说出 `set_goal` 这个工具名,
这是插件工具确实被 host 注册上的直接证据。

`/goal` 还有几个管理多目标的子命令(`resume`、`edit`、`list`、`focus`、`add`、`sequence`),完整的
命令分发逻辑见 `template/.deveco/plugin/devecocode-goal-plugin/goal-plugin.js`。

会话之外:

```bash
./goal.sh status <项目目录>    # 不进会话,直接打印 .deveco/goals/state.json
```

## 配置

可选文件:`<项目目录>/.deveco/goal-plugin.json`,内容原样透传成上游插件的 `pluginOptions`——文件
不存在就走上游默认值。常用几个键:

| 键 | 默认值 | 含义 |
|---|---|---|
| `maxTurns` | `10` | 自动续推轮数上限 |
| `maxDurationMs` | `900000`(15 分钟) | 自动续推的耗时预算 |
| `maxTokens` | `200000` | 自动续推的 token 预算 |
| `commandName` | `"goal"` | 命令名,改了斜杠命令就变成 `/<你的名字>` |

环境变量 `DEVECO_GOAL_STATE_PATH` 用来覆盖状态文件路径,优先级高于上游原有的
`OPENCODE_GOAL_STATE_PATH`(后者仍作为回退被承认,不破坏已有的上游集成)。默认状态写在项目内的
`.deveco/goals/state.json`。

## 排障

**先看 `.deveco/goals/plugin.log`。** 这个文件里没有加载记录,说明插件根本没被 DevEco Code 发现——
通常是装错了路径,或者检查得太早。

"太早"这个坑值得专门说一句:**插件是在首个会话创建时才加载的,不是 `deveco serve` 启动时。** 刚起
的 server 还没有插件日志,日志要等第一个会话建立之后才会出现。如果你在写脚本做检查,记得先建会话,
再去 grep 日志。

## 测试

```bash
node --test test/*.test.js
```

278 条测试:263 条原封不动搬自上游(作为回归基线),另外 15 条是这次移植新增的——覆盖 DevEco
专属适配、`goal.sh` 行为、冒烟测试场景。

```bash
scripts/smoke.sh
```

起一个真实的 `deveco serve`,确认插件被发现并加载,再走一遍 `/goal` 命令拦截链路的端到端验证
(通过 HTTP API 驱动)。

## 致谢与许可

移植自 [willytop8/OpenCode-goal-plugin](https://github.com/willytop8/OpenCode-goal-plugin) v0.6.5,
锁定提交 `2d3e97edeb6e1ecfbe21b193616987df335f047f`(见 [`upstream.lock`](upstream.lock))。采用
[MIT 许可](LICENSE),与上游一致。

本项目起源于 [deveco-lessons](https://github.com/fengyis/deveco-lessons) 的 Lesson 3——完整的教学
写作、移植方法论,以及上面提到的 DevEco 0.1.1 行为是怎么实测验证的原始探针笔记,都在那个仓库里。
