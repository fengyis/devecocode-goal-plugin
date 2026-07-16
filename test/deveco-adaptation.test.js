import test from "node:test"
import assert from "node:assert/strict"
import { join } from "node:path"
import { GoalPlugin, testInternals } from "../template/.deveco/plugin/devecocode-goal-plugin/goal-plugin.js"
import { createOpenCodeSessionApi } from "../template/.deveco/plugin/devecocode-goal-plugin/opencode-session-api.js"

const { resolveStateFilePath, currentGoal } = testInternals

test("项目默认状态路径落在 .deveco 下", () => {
  assert.equal(
    resolveStateFilePath({ cwd: "/proj", env: {} }),
    join("/proj", ".deveco", "goals", "state.json"),
  )
})

test("DEVECO_GOAL_STATE_PATH 优先于 OPENCODE_GOAL_STATE_PATH", () => {
  assert.equal(
    resolveStateFilePath({
      cwd: "/proj",
      env: { DEVECO_GOAL_STATE_PATH: "/a/state.json", OPENCODE_GOAL_STATE_PATH: "/b/state.json" },
    }),
    "/a/state.json",
  )
})

test("OPENCODE_GOAL_STATE_PATH 仍作为回退被承认", () => {
  assert.equal(
    resolveStateFilePath({ cwd: "/proj", env: { OPENCODE_GOAL_STATE_PATH: "/b/state.json" } }),
    "/b/state.json",
  )
})

function recordingClient() {
  const calls = []
  const record = (operation) => async (input) => {
    calls.push({ operation, input })
    return { data: { id: "s1" } }
  }
  return {
    calls,
    session: {
      create: record("create"),
      prompt: record("prompt"),
      promptAsync: record("promptAsync"),
      get: record("get"),
      messages: record("messages"),
      update: record("update"),
      delete: record("delete"),
      abort: record("abort"),
    },
  }
}

test("legacy 形状在配置 directory 时注入 query.directory", async () => {
  const client = recordingClient()
  const api = createOpenCodeSessionApi(client, { preferredShape: "legacy", directory: "/proj" })
  await api.prompt("s1", { parts: [] })
  assert.deepEqual(client.calls[0].input.path, { id: "s1" })
  assert.deepEqual(client.calls[0].input.query, { directory: "/proj" })
})

test("createChild 在 legacy 形状下也注入 query.directory", async () => {
  const client = recordingClient()
  const api = createOpenCodeSessionApi(client, { preferredShape: "legacy", directory: "/proj" })
  await api.createChild("parent", { title: "audit" })
  assert.deepEqual(client.calls[0].input.query, { directory: "/proj" })
})

test("不配置 directory 时 legacy 形状与上游一致（无 query 注入）", async () => {
  const client = recordingClient()
  const api = createOpenCodeSessionApi(client, { preferredShape: "legacy" })
  await api.prompt("s1", { parts: [] })
  assert.equal(client.calls[0].input.query, undefined)
})

test("flat 形状从不注入 query.directory", async () => {
  const client = recordingClient()
  const api = createOpenCodeSessionApi(client, { preferredShape: "flat", directory: "/proj" })
  await api.get("s1")
  assert.equal(client.calls[0].input.query, undefined)
})

test("messages 的 legacy 形状把 directory 合并进已有 query", async () => {
  const client = recordingClient()
  const api = createOpenCodeSessionApi(client, { preferredShape: "legacy", directory: "/proj" })
  await api.messages("s1", { limit: 5 })
  assert.deepEqual(client.calls[0].input.query, { limit: 5, directory: "/proj" })
})

// deveco renders `/goal $ARGUMENTS` command templates before persisting the
// resulting chat message, so the message that lands in chat.message is the
// bare argument text with no `/goal ` prefix (see docs/probe-notes.md 问题 1).
// The upstream `text.startsWith("/goal ")` exemption never matches that
// message, so without the fix below the goal the command just created is
// immediately paused as "user intervention".
function goalMessagePart(text) {
  return { type: "text", text }
}

async function buildGoalHooks(overrides = {}) {
  const client = {
    session: {
      messages: async () => ({ data: [] }),
      promptAsync: async () => ({}),
      abort: async () => ({}),
    },
  }
  return GoalPlugin({ client }, { persistState: false, minDelayMs: 1, ...overrides })
}

test("deveco 命令展开消息（同 sessionID、同文本、无 /goal 前缀）不触发 pause", async () => {
  const hooks = await buildGoalHooks()
  const sessionID = "session-deveco-1"
  await hooks["command.execute.before"](
    { command: "goal", sessionID, arguments: "make X" },
    { parts: [] },
  )
  await hooks["chat.message"](
    { sessionID },
    { message: { role: "user" }, parts: [goalMessagePart("make X")] },
  )
  assert.equal(currentGoal(sessionID).stopped, false)
})

test("真人新消息（不同文本）仍然触发 pause", async () => {
  const hooks = await buildGoalHooks()
  const sessionID = "session-deveco-2"
  await hooks["command.execute.before"](
    { command: "goal", sessionID, arguments: "make X" },
    { parts: [] },
  )
  await hooks["chat.message"](
    { sessionID },
    { message: { role: "user" }, parts: [goalMessagePart("actually do Y instead")] },
  )
  const goal = currentGoal(sessionID)
  assert.equal(goal.stopped, true)
  assert.equal(goal.stopReason, "user intervention")
})

test("同文本一次性豁免：第二条相同文本的消息触发 pause", async () => {
  const hooks = await buildGoalHooks()
  const sessionID = "session-deveco-3"
  await hooks["command.execute.before"](
    { command: "goal", sessionID, arguments: "make X" },
    { parts: [] },
  )
  await hooks["chat.message"](
    { sessionID },
    { message: { role: "user" }, parts: [goalMessagePart("make X")] },
  )
  assert.equal(currentGoal(sessionID).stopped, false)

  await hooks["chat.message"](
    { sessionID },
    { message: { role: "user" }, parts: [goalMessagePart("make X")] },
  )
  const goal = currentGoal(sessionID)
  assert.equal(goal.stopped, true)
  assert.equal(goal.stopReason, "user intervention")
})
