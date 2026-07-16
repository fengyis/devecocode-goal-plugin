import test from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import os from "node:os"
import { fileURLToPath } from "node:url"

const lessonDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const goalSh = path.join(lessonDir, "goal.sh")

function run(args) {
  return execFileSync("bash", [goalSh, ...args], { encoding: "utf-8" })
}

test("init 装好插件文件并 merge deveco.json", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "goal-init-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  run(["init", dir])
  assert.ok(fs.existsSync(path.join(dir, ".deveco/plugin/devecocode-goal-plugin.ts")))
  assert.ok(fs.existsSync(path.join(dir, ".deveco/plugin/devecocode-goal-plugin/goal-plugin.js")))
  assert.ok(fs.existsSync(path.join(dir, ".deveco/plugin/devecocode-goal-plugin/LICENSE")))
  const config = JSON.parse(fs.readFileSync(path.join(dir, "deveco.json"), "utf-8"))
  assert.equal(config.command.goal.template, "$ARGUMENTS")
})

test("init 不覆盖本地改动，--update 才覆盖", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "goal-update-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  run(["init", dir])
  const entry = path.join(dir, ".deveco/plugin/devecocode-goal-plugin.ts")
  fs.appendFileSync(entry, "\n// local edit\n")
  run(["init", dir])
  assert.match(fs.readFileSync(entry, "utf-8"), /local edit/)
  run(["init", dir, "--update"])
  assert.doesNotMatch(fs.readFileSync(entry, "utf-8"), /local edit/)
})

test("init 保留 deveco.json 已有字段", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "goal-merge-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, "deveco.json"), JSON.stringify({ model: "deepseek/deepseek-chat" }))
  run(["init", dir])
  const config = JSON.parse(fs.readFileSync(path.join(dir, "deveco.json"), "utf-8"))
  assert.equal(config.model, "deepseek/deepseek-chat")
  assert.equal(config.command.goal.template, "$ARGUMENTS")
})

test("status 在无状态文件时给出提示而不报错", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "goal-status-"))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  run(["init", dir])
  const out = run(["status", dir])
  assert.match(out, /还没有目标状态/)
})
