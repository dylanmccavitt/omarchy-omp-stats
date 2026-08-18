function number(value) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : 0
}

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, number(value)))
}

function parse(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null

  var end = text.lastIndexOf("}")
  var start = text.indexOf("{")
  if (start < 0 || end < start) throw new Error("OMP returned no JSON object")

  var report = null
  var parseError = null
  while (start >= 0 && start <= end) {
    try {
      report = JSON.parse(text.slice(start, end + 1))
      break
    } catch (error) {
      parseError = error
      start = text.indexOf("{", start + 1)
    }
  }
  if (!report) throw parseError || new Error("OMP returned invalid JSON")
  if (typeof report !== "object" || !report.overall || typeof report.overall !== "object")
    throw new Error("OMP returned an invalid stats report")

  if (!Array.isArray(report.byModel)) report.byModel = []
  if (!Array.isArray(report.byFolder)) report.byFolder = []
  if (!Array.isArray(report.byAgentType)) report.byAgentType = []
  if (!Array.isArray(report.timeSeries)) report.timeSeries = []
  if (!Array.isArray(report.modelSeries)) report.modelSeries = []
  if (!Array.isArray(report.modelPerformanceSeries)) report.modelPerformanceSeries = []
  return report
}

function trimFixed(value, digits) {
  return number(value).toFixed(digits).replace(/\.0+$/, "")
}

function formatCount(value) {
  var n = Math.max(0, number(value))
  if (n >= 1000000000000) return trimFixed(n / 1000000000000, 1) + "T"
  if (n >= 1000000000) return trimFixed(n / 1000000000, 1) + "B"
  if (n >= 1000000) return trimFixed(n / 1000000, 1) + "M"
  if (n >= 1000) return trimFixed(n / 1000, 1) + "K"
  return String(Math.round(n))
}

function formatCost(value) {
  var n = Math.max(0, number(value))
  if (n >= 1000) return "$" + trimFixed(n / 1000, 1) + "K"
  return "$" + n.toFixed(2)
}

function formatCompactCost(value) {
  var n = Math.max(0, number(value))
  if (n >= 1000) return "$" + trimFixed(n / 1000, 1) + "K"
  if (n >= 100) return "$" + String(Math.round(n))
  if (n >= 10) return "$" + trimFixed(n, 1)
  return "$" + trimFixed(n, 2)
}

function barMetric(report, mode, vertical, errorText) {
  var normalized = String(mode || "Requests and cost").toLowerCase()
  if (normalized === "logo only") return ""
  if (!report || !report.overall)
    return String(errorText || "") !== "" ? "!" : "…"

  var requests = formatCount(report.overall.totalRequests)
  var cost = formatCompactCost(report.overall.totalCost)
  if (normalized === "requests") return requests
  if (normalized === "cost") return cost
  return vertical ? requests : requests + " · " + cost
}

function formatPercent(value) {
  return (clamp(value, 0, 1) * 100).toFixed(1) + "%"
}

function formatDuration(value) {
  var ms = Math.max(0, number(value))
  if (ms < 1000) return Math.round(ms) + "ms"
  if (ms < 60000) return trimFixed(ms / 1000, 1) + "s"
  if (ms < 3600000) return trimFixed(ms / 60000, 1) + "m"
  return trimFixed(ms / 3600000, 1) + "h"
}

function formatDurationPrecise(value) {
  var ms = Math.max(0, number(value))
  if (ms < 1000) return Math.round(ms) + "ms"
  if (ms < 60000) return trimFixed(ms / 1000, 2) + "s"
  if (ms < 3600000) return trimFixed(ms / 60000, 2) + "m"
  return trimFixed(ms / 3600000, 2) + "h"
}

function formatRate(value) {
  return trimFixed(Math.max(0, number(value)), 1)
}

function conversationTokens(overall) {
  if (!overall) return 0
  return number(overall.totalInputTokens)
    + number(overall.totalOutputTokens)
    + number(overall.totalCacheReadTokens)
    + number(overall.totalCacheWriteTokens)
}

function rowTokens(row) {
  if (!row) return 0
  return number(row.totalInputTokens)
    + number(row.totalOutputTokens)
    + number(row.totalCacheReadTokens)
    + number(row.totalCacheWriteTokens)
}

function relativeTime(timestamp, now) {
  var then = number(timestamp)
  if (then <= 0) return "no requests yet"
  var delta = Math.max(0, number(now) - then)
  if (delta < 60000) return "just now"
  if (delta < 3600000) return Math.floor(delta / 60000) + "m ago"
  if (delta < 86400000) return Math.floor(delta / 3600000) + "h ago"
  return Math.floor(delta / 86400000) + "d ago"
}

function hourLabel(timestamp) {
  var date = new Date(number(timestamp))
  if (!isFinite(date.getTime())) return "—"
  var hours = String(date.getHours()).padStart(2, "0")
  var minutes = String(date.getMinutes()).padStart(2, "0")
  return hours + ":" + minutes
}

function modelKey(model, provider) {
  return String(model || "Unknown model") + "\u001f" + String(provider || "")
}

function modelRows(report) {
  var source = report && Array.isArray(report.byModel) ? report.byModel : []
  var series = report && Array.isArray(report.modelSeries) ? report.modelSeries.slice() : []
  var trends = {}
  var rows = []

  series.sort(function(a, b) { return number(a.timestamp) - number(b.timestamp) })
  for (var i = 0; i < series.length; i++) {
    var sample = series[i] || {}
    var sampleKey = modelKey(sample.model, sample.provider)
    if (!trends[sampleKey]) trends[sampleKey] = []
    trends[sampleKey].push({
      timestamp: number(sample.timestamp),
      label: hourLabel(sample.timestamp),
      requests: number(sample.requests)
    })
  }

  for (var trendKey in trends)
    if (trends[trendKey].length > 24) trends[trendKey] = trends[trendKey].slice(trends[trendKey].length - 24)

  for (var j = 0; j < source.length; j++) {
    var item = source[j] || {}
    var key = modelKey(item.model, item.provider)
    rows.push({
      key: key,
      name: String(item.model || "Unknown model"),
      provider: String(item.provider || ""),
      requests: number(item.totalRequests),
      cost: number(item.totalCost),
      tokens: rowTokens(item),
      errorRate: number(item.errorRate),
      cacheRate: number(item.cacheRate),
      cacheSavings: number(item.cacheSavings),
      avgDuration: number(item.avgDuration),
      avgTtft: number(item.avgTtft),
      avgTokensPerSecond: number(item.avgTokensPerSecond),
      trend: trends[key] || []
    })
  }

  rows.sort(function(a, b) {
    if (b.requests !== a.requests) return b.requests - a.requests
    return b.cost - a.cost
  })
  return rows
}

function folderName(path) {
  var value = String(path || "").replace(/[\\/]+$/, "")
  if (value === "") return "Unknown project"
  var parts = value.split(/[\\/]/)
  return parts[parts.length - 1] || value
}

function folderRows(report) {
  var source = report && Array.isArray(report.byFolder) ? report.byFolder : []
  var rows = []
  var maxCost = 0

  for (var i = 0; i < source.length; i++) {
    var item = source[i] || {}
    maxCost = Math.max(maxCost, number(item.totalCost))
    rows.push({
      name: folderName(item.folder),
      requests: number(item.totalRequests),
      cost: number(item.totalCost),
      tokens: rowTokens(item)
    })
  }

  rows.sort(function(a, b) { return b.cost - a.cost })
  for (var j = 0; j < rows.length; j++) rows[j].share = maxCost > 0 ? rows[j].cost / maxCost : 0
  return rows
}

function agentRows(report) {
  var source = report && Array.isArray(report.byAgentType) ? report.byAgentType : []
  var rows = []
  var maxTokens = 0

  for (var i = 0; i < source.length; i++) {
    var item = source[i] || {}
    var tokens = rowTokens(item)
    maxTokens = Math.max(maxTokens, tokens)
    rows.push({
      name: String(item.agentType || "unknown"),
      requests: number(item.totalRequests),
      cost: number(item.totalCost),
      tokens: tokens
    })
  }

  rows.sort(function(a, b) { return b.tokens - a.tokens })
  for (var j = 0; j < rows.length; j++) rows[j].share = maxTokens > 0 ? rows[j].tokens / maxTokens : 0
  return rows
}

function activityRows(report) {
  var source = report && Array.isArray(report.timeSeries) ? report.timeSeries.slice() : []
  source.sort(function(a, b) { return number(a.timestamp) - number(b.timestamp) })
  if (source.length > 12) source = source.slice(source.length - 12)

  var rows = []
  var peak = 0
  for (var i = 0; i < source.length; i++) peak = Math.max(peak, number(source[i].requests))
  for (var j = 0; j < source.length; j++) {
    var item = source[j] || {}
    rows.push({
      label: hourLabel(item.timestamp),
      requests: number(item.requests),
      errors: number(item.errors),
      tokens: number(item.tokens),
      cost: number(item.cost),
      share: peak > 0 ? number(item.requests) / peak : 0
    })
  }
  return rows
}

function modelPreference(report, rows, maxPoints) {
  rows = Array.isArray(rows) ? rows : modelRows(report)
  var models = []
  var modelIndexes = {}
  var source = report && Array.isArray(report.modelSeries) ? report.modelSeries.slice() : []
  var grouped = {}

  for (var i = 0; i < rows.length; i++) {
    modelIndexes[rows[i].key] = models.length
    models.push({ key: rows[i].key, name: rows[i].name, provider: rows[i].provider })
  }

  source.sort(function(a, b) { return number(a.timestamp) - number(b.timestamp) })
  for (var j = 0; j < source.length; j++) {
    var item = source[j] || {}
    var key = modelKey(item.model, item.provider)
    if (modelIndexes[key] === undefined) {
      modelIndexes[key] = models.length
      models.push({
        key: key,
        name: String(item.model || "Unknown model"),
        provider: String(item.provider || "")
      })
    }

    var timestamp = number(item.timestamp)
    if (timestamp <= 0) continue
    if (!grouped[timestamp]) grouped[timestamp] = { timestamp: timestamp, total: 0, requests: {} }
    var requests = number(item.requests)
    grouped[timestamp].total += requests
    grouped[timestamp].requests[key] = number(grouped[timestamp].requests[key]) + requests
  }

  var timestamps = []
  for (var timestampKey in grouped) timestamps.push(number(timestampKey))
  timestamps.sort(function(a, b) { return a - b })
  var limit = Math.max(2, number(maxPoints) || 24)
  if (timestamps.length > limit) timestamps = timestamps.slice(timestamps.length - limit)

  var points = []
  for (var k = 0; k < timestamps.length; k++) {
    var bucket = grouped[timestamps[k]]
    var shares = []
    for (var modelIndex = 0; modelIndex < models.length; modelIndex++) {
      var modelRequests = number(bucket.requests[models[modelIndex].key])
      shares.push(bucket.total > 0 ? modelRequests / bucket.total : 0)
    }
    points.push({
      timestamp: bucket.timestamp,
      label: hourLabel(bucket.timestamp),
      total: bucket.total,
      shares: shares
    })
  }

  if (points.length === 0 && rows.length > 0) {
    var total = 0
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) total += rows[rowIndex].requests
    var fallbackShares = []
    for (var fallbackIndex = 0; fallbackIndex < rows.length; fallbackIndex++)
      fallbackShares.push(total > 0 ? rows[fallbackIndex].requests / total : 0)
    var fallbackTimestamp = report && report.overall ? number(report.overall.lastTimestamp) : 0
    points.push({
      timestamp: fallbackTimestamp,
      label: hourLabel(fallbackTimestamp),
      total: total,
      shares: fallbackShares
    })
  }

  return { models: models, points: points }
}

function modelPerformancePoints(report, key, maxPoints) {
  var source = report && Array.isArray(report.modelPerformanceSeries)
    ? report.modelPerformanceSeries.slice() : []
  source.sort(function(a, b) { return number(a.timestamp) - number(b.timestamp) })

  var points = []
  for (var i = 0; i < source.length; i++) {
    var item = source[i] || {}
    if (modelKey(item.model, item.provider) !== key) continue
    points.push({
      timestamp: number(item.timestamp),
      label: hourLabel(item.timestamp),
      requests: number(item.requests),
      ttft: number(item.avgTtft),
      rate: number(item.avgTokensPerSecond)
    })
  }

  var limit = Math.max(2, number(maxPoints) || 24)
  if (points.length > limit) points = points.slice(points.length - limit)
  return points
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    parse: parse,
    formatCount: formatCount,
    formatCost: formatCost,
    formatCompactCost: formatCompactCost,
    barMetric: barMetric,
    formatPercent: formatPercent,
    formatDuration: formatDuration,
    formatDurationPrecise: formatDurationPrecise,
    formatRate: formatRate,
    conversationTokens: conversationTokens,
    relativeTime: relativeTime,
    modelKey: modelKey,
    modelRows: modelRows,
    folderName: folderName,
    folderRows: folderRows,
    agentRows: agentRows,
    activityRows: activityRows,
    modelPreference: modelPreference,
    modelPerformancePoints: modelPerformancePoints
  }
}
