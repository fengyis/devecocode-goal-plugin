import type { Plugin } from "@opencode-ai/plugin"
import fs from "fs"
import path from "path"
import { GoalPlugin } from "./devecocode-goal-plugin/goal-plugin.js"

// 可选配置：<项目>/.deveco/goal-plugin.json，内容就是上游的 pluginOptions
// （maxTurns / maxTokens / commandName / completionAudit / ...），缺省全走上游默认值。
export function loadPluginOptions(directory: string): Record<string, unknown> {
  const file = path.join(directory, ".deveco", "goal-plugin.json")
  if (!fs.existsSync(file)) return {}
  return JSON.parse(fs.readFileSync(file, "utf-8"))
}

export const DevecocodeGoalPlugin: Plugin = async (ctx) => {
  const directory = (ctx as { directory: string }).directory
  // 判断插件到底加载没加载，看这个文件——lesson2 的 .ralph/plugin.log 同款经验：
  // 插件放错目录是静默失效，必须有个落盘信号。
  fs.mkdirSync(path.join(directory, ".deveco", "goals"), { recursive: true })
  fs.appendFileSync(
    path.join(directory, ".deveco", "goals", "plugin.log"),
    `${new Date().toISOString()} devecocode-goal-plugin loaded\n`,
  )
  return GoalPlugin(ctx as Parameters<typeof GoalPlugin>[0], loadPluginOptions(directory))
}

export default { id: "devecocode-goal-plugin", server: DevecocodeGoalPlugin }
