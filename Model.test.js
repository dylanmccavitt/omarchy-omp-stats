const assert = require("node:assert/strict")
const Model = require("./Model.js")

function modelRecord(model, requests, overrides = {}) {
  return {
    model,
    provider: "openai-codex",
    totalRequests: requests,
    totalCost: requests / 10,
    totalInputTokens: requests * 10,
    totalOutputTokens: requests * 2,
    totalCacheReadTokens: requests * 20,
    totalCacheWriteTokens: requests,
    errorRate: 0,
    cacheRate: 0.8,
    cacheSavings: 0.6,
    avgDuration: 4000,
    avgTtft: 1200,
    avgTokensPerSecond: 25,
    ...overrides
  }
}

const report = Model.parse([
  "Syncing session files...",
  JSON.stringify({
    overall: {
      totalRequests: 10,
      totalInputTokens: 100,
      totalOutputTokens: 20,
      totalCacheReadTokens: 200,
      totalCacheWriteTokens: 10,
      lastTimestamp: 2000
    },
    byModel: [modelRecord("beta", 4), modelRecord("alpha", 6)],
    byFolder: [
      { folder: "/work/a", totalRequests: 3, totalCost: 1.5, totalInputTokens: 30 },
      { folder: "/work/b", totalRequests: 1, totalCost: 0.5, totalInputTokens: 10 }
    ],
    byAgentType: [
      { agentType: "main", totalRequests: 3, totalInputTokens: 75 },
      { agentType: "subagent", totalRequests: 1, totalInputTokens: 25 }
    ],
    timeSeries: [
      { timestamp: 2000, requests: 6, errors: 1, tokens: 60, cost: 0.6 },
      { timestamp: 1000, requests: 4, errors: 0, tokens: 40, cost: 0.4 }
    ],
    modelSeries: [
      { timestamp: 1000, model: "alpha", provider: "openai-codex", requests: 3 },
      { timestamp: 1000, model: "beta", provider: "openai-codex", requests: 1 },
      { timestamp: 2000, model: "alpha", provider: "openai-codex", requests: 3 },
      { timestamp: 2000, model: "beta", provider: "openai-codex", requests: 3 }
    ],
    modelPerformanceSeries: [
      { timestamp: 2000, model: "alpha", provider: "openai-codex", requests: 3, avgTtft: 900, avgTokensPerSecond: 22 },
      { timestamp: 1000, model: "alpha", provider: "openai-codex", requests: 3, avgTtft: 1200, avgTokensPerSecond: 18 },
      { timestamp: 1000, model: "beta", provider: "openai-codex", requests: 1, avgTtft: 2000, avgTokensPerSecond: 12 }
    ]
  })
].join("\n"))

assert.equal(report.overall.totalRequests, 10)
assert.equal(Model.parse("  "), null)
assert.throws(() => Model.parse("not json"), /no JSON object/)
assert.throws(() => Model.parse("{}"), /invalid stats report/)

const rows = Model.modelRows(report)
assert.deepEqual(rows.map(row => row.name), ["alpha", "beta"])
assert.equal(rows[0].tokens, 198)
assert.deepEqual(rows[0].trend.map(point => point.requests), [3, 3])

const preference = Model.modelPreference(report, rows, 24)
assert.deepEqual(preference.models.map(model => model.name), ["alpha", "beta"])
assert.deepEqual(preference.points.map(point => point.shares), [
  [0.75, 0.25],
  [0.5, 0.5]
])

const fallbackReport = Model.parse(JSON.stringify({
  overall: { lastTimestamp: 3000 },
  byModel: [modelRecord("alpha", 3), modelRecord("beta", 1)]
}))
const fallbackRows = Model.modelRows(fallbackReport)
assert.deepEqual(Model.modelPreference(fallbackReport, fallbackRows, 24).points[0].shares, [0.75, 0.25])

const alphaPerformance = Model.modelPerformancePoints(report, rows[0].key, 24)
assert.deepEqual(alphaPerformance.map(point => [point.timestamp, point.ttft, point.rate]), [
  [1000, 1200, 18],
  [2000, 900, 22]
])

assert.deepEqual(Model.folderRows(report).map(row => [row.name, row.share]), [
  ["a", 1],
  ["b", 1 / 3]
])
assert.deepEqual(Model.agentRows(report).map(row => [row.name, row.share]), [
  ["main", 1],
  ["subagent", 1 / 3]
])
assert.deepEqual(Model.activityRows(report).map(row => row.requests), [4, 6])

assert.equal(Model.formatCount(1_250_000), "1.3M")
assert.equal(Model.formatCost(12.5), "$12.50")
assert.equal(Model.formatPercent(0.875), "87.5%")
assert.equal(Model.formatDurationPrecise(2166), "2.17s")
assert.equal(Model.conversationTokens(report.overall), 330)
assert.equal(Model.formatCompactCost(227.08), "$227")
assert.equal(Model.formatCompactCost(12.56), "$12.6")
assert.equal(Model.barMetric({ overall: { totalRequests: 1250, totalCost: 12.56 } },
  "Requests and cost", false, ""), "1.3K · $12.6")
assert.equal(Model.barMetric({ overall: { totalRequests: 1250, totalCost: 12.56 } },
  "Requests and cost", true, ""), "1.3K")
assert.equal(Model.barMetric({ overall: { totalRequests: 1250, totalCost: 12.56 } },
  "Cost", true, ""), "$12.6")
assert.equal(Model.barMetric(null, "Requests", false, ""), "…")
assert.equal(Model.barMetric(null, "Requests", false, "OMP failed"), "!")
assert.equal(Model.barMetric(report, "Logo only", false, ""), "")

console.log("OMP Stats model tests passed")
