// Copyright 2026 The "Anthropic on Google Cloud" Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Helpers for the mod that make no mods API calls, so tests can call
// them directly: record to row, batching, and reading BigQuery's answers.

// Each record becomes a row in the layout a Cloud Logging sink writes to
// BigQuery when Claude Code's OpenTelemetry export goes through Google's
// Telemetry API: one table per event type, camelCase LogEntry columns, and
// labels as a RECORD of STRING fields. See "What a row contains" in README.md.
// https://docs.cloud.google.com/logging/docs/export/bigquery
// https://docs.cloud.google.com/stackdriver/docs/reference/telemetry/otlp-log-record-to-log-entry
// https://docs.cloud.google.com/stackdriver/docs/reference/telemetry/otlp-attribute-to-logging-resource

// Cloud Logging's limits for an entry made from an OTLP record: 256 KiB per
// entry (the mod drops a bigger row), 512 B per attribute key and 64 KiB per value.
export const MAX_ROW_BYTES = 256 * 1024
const MAX_KEY_BYTES = 512
export const MAX_VALUE_BYTES = 64 * 1024
// A BigQuery field name that a sink writes is at most 128 characters.
const MAX_FIELD_NAME = 128

// insertAll takes at most 50,000 rows and 10 MB in one request. A batch is at
// most 500 rows and 3 MiB, or one row of at most 256 KiB, well under both.
export const MAX_BATCH_ROWS = 500
export const MAX_BATCH_BYTES = 3 * 1024 * 1024

// Attributes each resource label is read from, first non-empty wins; else ''.
// The names are those Google's OTLP-to-resource mapping uses for generic_task.
const RESOURCE_LABEL_KEYS = {
  location: ['location', 'cloud.availability_zone', 'cloud.region'],
  namespace: ['namespace', 'service.namespace'],
  job: ['job', 'service.name'],
  task_id: ['task_id', 'service.instance.id'],
}

const encoder = new TextEncoder()

/** Size of a value's JSON text in bytes (UTF-8). */
export function jsonBytes(value) {
  return encoder.encode(JSON.stringify(value)).length
}

/**
 * The resource attributes Claude Code sends that a mod can know. Later ones
 * win: service.name "claude-code", then OTEL_RESOURCE_ATTRIBUTES, then
 * OTEL_SERVICE_NAME.
 */
export function resourceAttributesOf(otelResourceAttributes, otelServiceName) {
  const attributes = Object.create(null) // no prototype, so a __proto__ key is kept
  attributes['service.name'] = 'claude-code'
  Object.assign(attributes, envAttributesOf(otelResourceAttributes ?? ''))
  if (otelServiceName) attributes['service.name'] = otelServiceName
  return attributes
}

// OTEL_RESOURCE_ATTRIBUTES ("k1=v1,k2=v2"): pairs without a key are skipped,
// quotes around a value are dropped, and percent-encoding is decoded where valid.
function envAttributesOf(text) {
  const attributes = Object.create(null)
  for (const pair of text.split(',')) {
    const at = pair.indexOf('=')
    const key = at < 0 ? '' : pair.slice(0, at).trim()
    if (!key) continue
    const value = pair.slice(at + 1).trim().replace(/^"|"$/g, '')
    try {
      attributes[key] = decodeURIComponent(value)
    } catch {
      attributes[key] = value
    }
  }
  return attributes
}

/**
 * Whether the mod needs the machine's hostname for task_id: no attribute
 * names the task.
 */
export function wantsHostname(attributes) {
  return !RESOURCE_LABEL_KEYS.task_id.some((key) => attributes[key])
}

/**
 * The monitored resource { type, labels }: always generic_task, with
 * project_id the given project, job the service name (claude-code unless
 * OTEL_SERVICE_NAME says otherwise), task_id the service.instance.id
 * attribute or else hostname, and location and namespace from their
 * attributes. A label with no value is ''. See "The resource" in README.md.
 */
export function resourceOf(attributes, project, hostname = '') {
  const first = (keys) => keys.map((key) => attributes[key]).find((value) => value) ?? ''
  const labels = { project_id: project }
  for (const [name, keys] of Object.entries(RESOURCE_LABEL_KEYS)) labels[name] = first(keys)
  if (!labels.task_id) labels.task_id = hostname
  return { type: 'generic_task', labels }
}

/**
 * A label value: lists (and any other object) as compact JSON text, as
 * Google documents for lists. Numbers
 * and booleans as JavaScript writes them ("34", "0.000188", "1e-7", "true"):
 * not confirmed against a real Telemetry API export.
 */
export function labelValueOf(value) {
  if (typeof value === 'string') return value
  if (typeof value === 'object' && value !== null) return JSON.stringify(value)
  return String(value)
}

/**
 * text cut to at most maxBytes of UTF-8, ending in "…" when cut, as Cloud
 * Logging marks a truncated label. Whether the ellipsis counts toward the
 * limit is not confirmed against a real Telemetry API export.
 */
export function truncated(text, maxBytes) {
  const bytes = encoder.encode(text)
  if (bytes.length <= maxBytes) return text
  const kept = new TextDecoder().decode(bytes.subarray(0, maxBytes - 3)) // "…" is 3 bytes
  return kept.replace(/\uFFFD$/, '') + '…' // drop a character cut in half
}

/**
 * The BigQuery field name a sink gives a label key: each character other
 * than a letter, digit or underscore becomes "_", leading underscores are
 * removed, and the name is lowercased and cut to 128 characters
 * ("session.id" becomes session_id). '' when nothing is left.
 */
export function fieldNameOf(key) {
  return key.replace(/[^A-Za-z0-9_]/gu, '_').replace(/^_+/, '').toLowerCase().slice(0, MAX_FIELD_NAME)
}

/**
 * The table a sink writes a log to: the prefix, then the log ID with every
 * character other than a letter, digit or underscore turned into "_" (Google
 * shows "-", "." and "/" becoming "_").
 */
export function tableNameOf(logId, prefix = '') {
  return prefix + logId.replace(/[^A-Za-z0-9_]/gu, '_')
}

/**
 * Fields every row of a session shares: logProject (the project option, used
 * in logName and resource.labels.project_id) and resource.
 */
export function sessionFieldsOf(resourceAttributes, project, hostname = '') {
  return { logProject: project, resource: resourceOf(resourceAttributes, project, hostname) }
}

/**
 * { table, json } for a telemetry.log event { event, attributes, loggedAt,
 * span? }. The log ID is always the event name. context is what
 * sessionFieldsOf returns; insertId must stay the same when the row is sent
 * again. trace, spanId and traceSampled are left out when not set.
 */
export function rowOf(entry, context, insertId, receivedAt, tablePrefix = '') {
  // The record's attributes and nothing else, as strings under their sink
  // field names. After cutting and renaming, the first of two equal names stays.
  const labels = Object.create(null)
  for (const [key, value] of Object.entries(entry.attributes ?? {})) {
    const name = fieldNameOf(truncated(key, MAX_KEY_BYTES))
    if (name && !(name in labels)) labels[name] = truncated(labelValueOf(value), MAX_VALUE_BYTES)
  }
  const logId = entry.event
  const span = entry.span
  const json = {
    timestamp: entry.loggedAt,
    receiveTimestamp: receivedAt,
    logName: 'projects/' + context.logProject + '/logs/' + encodeURIComponent(logId),
    resource: context.resource,
    severity: 'DEFAULT',
    textPayload: 'claude_code.' + entry.event,
    labels: { ...labels },
    insertId,
  }
  if (span) {
    // The bare 32-hex-digit trace ID: Google says "the value from the log
    // record's traceId field", with no example.
    json.trace = span.traceId
    json.spanId = span.spanId
    // Set only when the sampled bit is 1; "otherwise, it remains unset".
    if ((span.traceFlags & 1) === 1) json.traceSampled = true
  }
  return { table: tableNameOf(logId, tablePrefix), json }
}

// The labels field that holds, as one JSON object, every label the table
// has no field of its own for. setup.sh adds it to every table as a JSON
// field; insertAll takes a JSON field's value as JSON text.
export const EXTRA_LABELS_FIELD = 'extra_labels'

/**
 * json fitted to the table's columns (fields, from tables.get): labels the
 * table has no field for go into labels.extra_labels as JSON text, or are
 * dropped when the table lacks that field too; resource labels it lacks are
 * dropped. Also returns the names of the fields it dropped.
 */
export function fitToTable(json, fields) {
  const subfields = (record, name) => record?.find((f) => f.name === name)?.fields ?? []
  const labelNames = new Set(subfields(fields, 'labels').map((f) => f.name))
  const resourceNames = new Set(subfields(subfields(fields, 'resource'), 'labels').map((f) => f.name))
  const hasExtra = labelNames.delete(EXTRA_LABELS_FIELD)
  const dropped = []
  const labels = {}
  const extra = {}
  for (const [name, value] of Object.entries(json.labels ?? {})) {
    if (labelNames.has(name)) labels[name] = value
    else if (hasExtra) extra[name] = value
    else dropped.push('labels.' + name)
  }
  if (Object.keys(extra).length > 0) labels[EXTRA_LABELS_FIELD] = JSON.stringify(extra)
  const resourceLabels = {}
  for (const [name, value] of Object.entries(json.resource?.labels ?? {})) {
    if (resourceNames.has(name)) resourceLabels[name] = value
    else dropped.push('resource.labels.' + name)
  }
  return { json: { ...json, labels, resource: { ...json.resource, labels: resourceLabels } }, dropped }
}

/**
 * Removes and returns items { table, insertId, json, bytes } from the queue:
 * those for the first item's table, at most maxRows and maxBytes, but always
 * at least one.
 */
export function takeBatch(queue, maxRows = MAX_BATCH_ROWS, maxBytes = MAX_BATCH_BYTES) {
  if (queue.length === 0) return []
  const table = queue[0].table
  const taken = []
  let bytes = 0
  for (let i = 0; i < queue.length && taken.length < maxRows; ) {
    const item = queue[i]
    if (item.table !== table) {
      i++
      continue
    }
    if (bytes + item.bytes > maxBytes && taken.length > 0) break
    bytes += item.bytes
    taken.push(item)
    queue.splice(i, 1)
  }
  return taken
}

/** The insertAll request body for a batch. */
export function insertAllBody(batch) {
  return JSON.stringify({
    kind: 'bigquery#tableDataInsertAllRequest',
    skipInvalidRows: false,
    // A backstop: fields the table lacks are dropped rather than refusing
    // the row. The mod normally removes them first, and says which.
    ignoreUnknownValues: true,
    rows: batch.map((item) => ({ insertId: item.insertId, json: item.json })),
  })
}

// BigQuery error reasons that mean "try the same request again later".
// https://cloud.google.com/bigquery/docs/error-messages
const RETRYABLE_REASONS = new Set([
  'backendError',
  'internalError',
  'rateLimitExceeded',
  'quotaExceeded',
  'timeout',
  'stopped',
])

/**
 * Sorts a sent batch by BigQuery's answer into { sent, retry, dropped },
 * with the reason for any failure. retryLater is true when the retried
 * rows should wait for a backoff before the next attempt.
 */
export function outcomeOf(batch, status, text) {
  let body
  try {
    body = JSON.parse(text)
  } catch {
    body = undefined
  }

  if (status >= 200 && status < 300) {
    const errors = Array.isArray(body?.insertErrors) ? body.insertErrors : []
    if (errors.length === 0) return { sent: batch, retry: [], dropped: [], reason: '', retryLater: false }
    const failed = new Map()
    for (const error of errors) failed.set(error.index, error.errors ?? [])
    const sent = []
    const retry = []
    const dropped = []
    const reasons = new Set()
    batch.forEach((item, index) => {
      const rowErrors = failed.get(index)
      if (rowErrors === undefined) sent.push(item)
      else if (rowErrors.length > 0 && rowErrors.every((e) => RETRYABLE_REASONS.has(e.reason))) retry.push(item)
      else {
        dropped.push(item)
        for (const e of rowErrors) reasons.add(describeError(e))
      }
    })
    return { sent, retry, dropped, reason: [...reasons].join('; '), retryLater: false }
  }

  const error = body?.error
  const reasons = (error?.errors ?? []).map((e) => e.reason)
  const message = error?.message ?? (typeof text === 'string' ? text.slice(0, 200) : '')
  // 403 too: a missing permission can be granted later, so the rows wait
  // (with backoff, up to the in-memory limit) instead of being dropped.
  const isRetryable =
    status === 401 || status === 403 || status === 408 || status === 429 || status >= 500 ||
    reasons.some((r) => RETRYABLE_REASONS.has(r))
  if (isRetryable) {
    return { sent: [], retry: batch, dropped: [], reason: 'HTTP ' + status + ': ' + message, retryLater: true }
  }
  return { sent: [], retry: [], dropped: batch, reason: 'HTTP ' + status + ': ' + message, retryLater: false }
}

function describeError(error) {
  const where = error.location ? ' (' + error.location + ')' : ''
  return (error.reason ?? 'error') + where + ': ' + (error.message ?? '')
}

/** How long to wait before the next attempt after `failures` failures in a row. */
export function backoffMs(failures, random = Math.random()) {
  const base = Math.min(300_000, 2_000 * 2 ** Math.max(0, failures - 1))
  return Math.round(base * (0.5 + random / 2))
}
