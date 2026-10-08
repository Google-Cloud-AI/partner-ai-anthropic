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

// A Claude Code mod that copies each OpenTelemetry event record into
// BigQuery, one table per event type, in the layout a Cloud Logging sink
// writes. README.md describes the options, the row format and the limits.

import {
  MAX_BATCH_BYTES,
  MAX_BATCH_ROWS,
  MAX_ROW_BYTES,
  MAX_VALUE_BYTES,
  backoffMs,
  fitToTable,
  insertAllBody,
  jsonBytes,
  outcomeOf,
  resourceAttributesOf,
  rowOf,
  sessionFieldsOf,
  tableNameOf,
  takeBatch,
  truncated,
  wantsHostname,
} from './rows.mjs'

const LOG_PREFIX = 'bigquery-telemetry: '
const METADATA_TOKEN_URL =
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
const METADATA_EMAIL_URL =
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'
const TOKENINFO_URL = 'https://oauth2.googleapis.com/tokeninfo'
// How long a failed lookup of the credentials' email address is kept before
// it is tried again.
const EMAIL_RETRY_MS = 10 * 60 * 1000
// With on_auth_failure "block", how long a prompt waits for a token before
// it is refused.
const AUTH_CHECK_TIMEOUT_MS = 25_000
// While credentials are the problem, retries come at least this often, so the
// warning clears soon after the developer signs in.
const AUTH_RETRY_MAX_MS = 30_000
// gcloud doesn't say when its token expires and may print one it cached
// earlier, so reuse it for 10 minutes at most, and get a new one on a 401.
const GCLOUD_TOKEN_REUSE_MS = 10 * 60 * 1000
// How long a table's columns, read with tables.get, are trusted before
// they are read again (setup.sh may have added some).
const TABLE_FIELDS_REUSE_MS = 10 * 60 * 1000
// Batches sent at once, usually each for its own table.
const MAX_PARALLEL_SENDS = 8
// Cap on rows held in memory while BigQuery can't be reached.
const MAX_QUEUE_BYTES = 16 * 1024 * 1024
// Cap on the rows one session keeps in the store. All sessions share the
// mod's store, which holds 4 MiB in total.
const MAX_SPOOL_BYTES = 1024 * 1024
const SPOOL_PREFIX = 'unsent:'
// A session that just ended may still be sending the rows it saved, so
// other sessions leave saved rows alone until they are this old. A running
// session waiting to retry can own older ones; taking those can duplicate rows.
const SPOOL_MIN_AGE_MS = 30_000

let config
const state = {
  queue: [], // items { table, insertId, json, bytes } waiting to be sent
  queuedBytes: 0,
  inFlight: [], // the rows being sent now
  context: undefined, // promise of what every row needs from the session
  token: undefined, // { value, expiresAt }
  tokenRequest: undefined, // promise of the token being fetched now, shared by every caller
  email: undefined, // { value, readAt }: the credentials' email address, '' if unknown
  emailRequest: undefined, // promise of the lookup running now, shared by every caller
  tables: new Map(), // table name -> { fields, readAt }: its columns, from tables.get
  tableReads: new Map(), // table name -> promise of the tables.get running now
  prefetched: new Set(), // tables whose columns enqueue() has already asked for
  failures: 0, // failed attempts in a row
  retryAt: 0, // no attempt before this time (ms since the epoch)
  flushing: undefined, // promise of the running drain
  timerStarted: false, // whether the flush timer runs; it outlives a session id
  disabled: '', // why the mod stopped sending, when it did
  ended: false, // the process is exiting
  spoolKey: SPOOL_PREFIX + crypto.randomUUID(), // this process's key in the store
  spooled: false, // whether the store holds rows under spoolKey
  spoolWrites: Promise.resolve(true), // the latest write of saved rows; they run one at a time
  taken: [], // [{ key, ids }]: other sessions' keys to delete once these rows are sent
  warned: new Set(),
  // Why rows can't be written: { kind: 'credentials' | 'permission', reason },
  // shown above the prompt until a send succeeds.
  authProblem: undefined,
  toasted: new Set(), // kinds of authProblem already announced with a toast
}

export function register(on, options) {
  config = configOf(options)
  state.disabled = problemOf(config)

  on('session.start', async ($, e, next) => {
    if (state.disabled) await warnOnce($, 'disabled', 'no rows will be sent to BigQuery: ' + state.disabled)
    try {
      await contextOf($)
    } catch (error) {
      await warnOnce($, 'start', "could not read the session's settings; trying again with the next record: " + messageOf(error))
    }
    if (!state.disabled) {
      // session.start can fire again in the same process (after /clear or a
      // resume), and the first timer still runs then.
      if (!state.timerStarted) {
        state.timerStarted = true
        $.clock.every(config.intervalMs, () => {
          void flush($)
        })
      }
      // Get a token now, so that one is at hand at exit, and the email
      // address it belongs to.
      void tokenOf($)
        .then(() => emailOf($))
        .catch(() => {})
      await replaySpool($)
    }
    return next(e)
  })

  // Always pass the record on with next(e), and first: refusing or holding
  // it would also affect the OpenTelemetry export the organization may run.
  on('telemetry.log', { to: 'collector' }, async ($, e, next) => {
    const result = await next(e)
    // If a later hook refused the record, the export doesn't get it, so neither does BigQuery.
    if (result?.deny !== undefined) return result
    try {
      await enqueue($, e)
    } catch (error) {
      await warnOnce($, 'enqueue', 'could not queue a record, so it will not be sent: ' + messageOf(error))
    }
    return result
  })

  // While rows can't be written for lack of credentials or permission, a
  // line above the prompt says why and how to fix it.
  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    if (!state.authProblem || e.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return authBand(Box, Text)
  })

  // With on_auth_failure "block", a prompt is refused while there are no
  // working Google credentials, so that no session runs unrecorded. A crash
  // here refuses the prompt too.
  on('prompt.submit', async ($, e, next) => {
    // A prompt while rows can't be written is a good moment to try again: the
    // developer may have just signed in.
    if (state.authProblem && !state.disabled) {
      state.retryAt = 0
      void flush($)
    }
    if (config.onAuthFailure !== 'block') return next(e)
    const problem = await blockingProblem($)
    if (problem) return { drop: problem }
    return next(e)
  }).catch(($, e, next) =>
    next.called ? next(e) : { drop: 'bigquery-telemetry could not check the Google credentials, so the prompt was not sent.' },
  )

  on('session.end', async ($, e, next) => {
    try {
      if (e.reason === 'clear' || e.reason === 'resume') {
        // The process goes on under a new session id, and the timer keeps
        // sending; this just sends what is queued now.
        void flush($)
      } else {
        await finish($, next.budget)
      }
    } catch (error) {
      console.warn(LOG_PREFIX + 'could not save or send rows at exit: ' + messageOf(error))
    }
    return next(e)
  })
}

function configOf(options) {
  const o = options ?? {}
  const text = (value, fallback) => {
    const s = typeof value === 'string' ? value.trim() : ''
    return s === '' ? fallback : s
  }
  const project = text(o.project, '')
  const seconds = Number(o.flush_interval_seconds)
  return {
    project,
    dataset: text(o.dataset, 'claude_code_telemetry'),
    tablePrefix: text(o.table_prefix, ''),
    hostnameTaskId: o.hostname_task_id !== false && o.hostname_task_id !== 'false',
    emailFromCredentials: o.email_from_credentials !== false && o.email_from_credentials !== 'false',
    auth: text(o.auth, 'adc'),
    onAuthFailure: text(o.on_auth_failure, 'warn').toLowerCase(),
    quotaProject: text(o.quota_project, ''),
    intervalMs: (Number.isFinite(seconds) && seconds >= 1 ? Math.min(seconds, 300) : 5) * 1000,
    apiBase: text(o.api_base, 'https://bigquery.googleapis.com').replace(/\/+$/, ''),
  }
}

// Why the options can't work, or '' if they can. Checked before anything is
// sent, so that a token never goes anywhere but Google.
function problemOf(c) {
  if (!c.project) {
    return 'the "project" option is not set. Set it in pluginConfigs in your user or managed ' +
      'settings; Claude Code does not read plugin options from project settings.'
  }
  if (!['warn', 'block'].includes(c.onAuthFailure)) {
    return 'the "on_auth_failure" option is "' + c.onAuthFailure + '", but it must be warn or block.'
  }
  if (!['adc', 'gcloud', 'metadata', 'none'].includes(c.auth)) {
    return 'the "auth" option is "' + c.auth + '", but it must be adc, gcloud, metadata or none.'
  }
  if (c.auth !== 'none' && !isGoogleApi(c.apiBase)) {
    return 'the "api_base" option must be an https://*.googleapis.com URL unless "auth" is none, ' +
      'so that a Google token is never sent anywhere else.'
  }
  if (!isUrl(c.apiBase)) return 'the "api_base" option is not an http or https URL.'
  if (!/^[A-Za-z0-9_]*$/.test(c.tablePrefix)) {
    return 'the "table_prefix" option may contain only letters, digits and underscores, as in setup.sh.'
  }
  return ''
}

// What every row needs from the session, read once.
function contextOf($) {
  if (!state.context) {
    state.context = loadContext($).catch((error) => {
      state.context = undefined
      throw error
    })
  }
  return state.context
}

async function loadContext($) {
  const resourceAttributes = await $.env.get('OTEL_RESOURCE_ATTRIBUTES')
  const serviceName = await $.env.get('OTEL_SERVICE_NAME')
  const nonessentialOff = await $.env.get('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')

  if (nonessentialOff && !state.disabled) {
    await disable(
      $,
      'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set, which makes Claude Code refuse every ' +
        "network request from a mod. Unset it to send rows (DISABLE_TELEMETRY doesn't block the mod).",
    )
  }
  const attributes = resourceAttributesOf(resourceAttributes, serviceName)
  const hostname = config.hostnameTaskId && !state.disabled && wantsHostname(attributes) ? await hostnameOf($) : ''
  return sessionFieldsOf(attributes, config.project, hostname)
}

// The machine's hostname, for the resource's task_id, or '' if it can't be found.
async function hostnameOf($) {
  try {
    const run = await $.process.run(['hostname'], { timeoutMs: 5_000 })
    const name = run.exitCode === 0 ? run.stdout.trim() : ''
    if (name) return name
  } catch {
    // Fall back to the environment below.
  }
  return ((await $.env.get('HOSTNAME')) || (await $.env.get('COMPUTERNAME')) || '').trim()
}

async function enqueue($, e) {
  if (state.disabled) return
  const context = await contextOf($)
  if (state.disabled) return
  const { table, json } = rowOf(e, context, crypto.randomUUID(), new Date().toISOString(), config.tablePrefix)
  const bytes = jsonBytes(json)
  if (bytes > MAX_ROW_BYTES) {
    await warnOnce(
      $,
      'too-big:' + e.event,
      'a record of type ' + e.event + ' (about ' + Math.ceil(bytes / 1024) + ' KiB) was not sent: the mod drops records over ' +
        MAX_ROW_BYTES / 1024 + " KiB, Cloud Logging's limit for one log entry. Records this large usually come from " +
        'OTEL_LOG_USER_PROMPTS, OTEL_LOG_ASSISTANT_RESPONSES, OTEL_LOG_TOOL_DETAILS or OTEL_LOG_RAW_API_BODIES; ' +
        "unset them if that content doesn't need to reach BigQuery.",
    )
    return
  }
  // Only this process's rows get its credentials' email address, and only
  // when the record carries none of its own.
  const wantsEmail = config.emailFromCredentials && !json.labels.user_email
  pushBack([{ table, insertId: json.insertId, json, bytes, wantsEmail }])
  // Read a new table's columns now, once, so that sending at exit needn't wait for it.
  if (!state.prefetched.has(table)) {
    state.prefetched.add(table)
    void fieldsOf($, table).catch(() => {})
  }
  while (state.queuedBytes > MAX_QUEUE_BYTES && state.queue.length > 1) {
    const oldest = state.queue.shift()
    state.queuedBytes -= oldest.bytes
    await warnOnce(
      $,
      'full',
      "over 16 MiB of rows is waiting because BigQuery hasn't accepted any for a while, so the oldest rows are being dropped.",
    )
  }
  if (state.ended) {
    // A record that arrives after session.end: save it with the rest.
    await spool($)
  } else if (state.queue.length >= MAX_BATCH_ROWS || state.queuedBytes >= MAX_BATCH_BYTES) {
    void flush($)
  }
}

function pushBack(items) {
  for (const item of items) {
    state.queue.push(item)
    state.queuedBytes += item.bytes
  }
}

function pushFront(items) {
  state.queue.unshift(...items)
  for (const item of items) state.queuedBytes += item.bytes
}

// Starts sending what is queued, unless a send is already running. The
// returned promise never rejects.
function flush($) {
  if (!state.flushing) {
    state.flushing = drain($)
      .catch((error) =>
        console.warn(LOG_PREFIX + 'sending stopped on an unexpected error and resumes at the next interval: ' + messageOf(error)),
      )
      .finally(() => {
        state.flushing = undefined
      })
  }
  return state.flushing
}

async function drain($) {
  while (state.queue.length > 0 && !state.disabled && (await $.clock.now()) >= state.retryAt) {
    // Each kind of event has its own table, so batches go out together, up
    // to 8 at once: at exit, one round trip covers that many tables.
    const batches = []
    while (state.queue.length > 0 && batches.length < MAX_PARALLEL_SENDS) batches.push(takeBatch(state.queue))
    for (const item of batches.flat()) state.queuedBytes -= item.bytes
    state.inFlight = batches.flat()
    const outcomes = await Promise.all(
      batches.map(async (batch) => {
        const outcome = await sendOrFail($, batch)
        // Settle each batch as soon as it is answered, so that the saved copies
        // stay in step with what is still unsent even if the process exits now.
        state.inFlight = state.inFlight.filter((item) => !batch.includes(item))
        pushFront(outcome.retry)
        if (state.ended || state.spooled) await spool($)
        if (state.taken.length > 0) {
          try {
            await releaseTaken($, [...outcome.sent, ...outcome.dropped])
          } catch (error) {
            // The other session's key stays; its rows may be sent again later.
            console.warn(LOG_PREFIX + 'could not remove rows another session saved: ' + messageOf(error))
          }
        }
        return outcome
      }),
    )
    const egress = outcomes.find((o) => o.egressRefused)
    if (egress) {
      await disable($, 'Claude Code refused the request to BigQuery: ' + egress.reason + '.')
      return
    }
    const failed = outcomes.some(isFailure)
    let waitMs = failed ? backoffMs(state.failures + 1) : 0
    if (state.authProblem?.kind === 'credentials') waitMs = Math.min(waitMs, AUTH_RETRY_MAX_MS)
    for (const outcome of outcomes) await report($, outcome, waitMs)
    state.failures = failed ? state.failures + 1 : 0
    state.retryAt = failed ? (await $.clock.now()) + waitMs : 0
    if (state.failures > 0) return
  }
}

// send(), with a failure before BigQuery answered turned into an outcome.
async function sendOrFail($, batch) {
  try {
    return await send($, batch)
  } catch (error) {
    const message = messageOf(error)
    // Claude Code refuses every request from the mod.
    const egress = message.match(/\$\.http\.fetch: refused: (.*)$/)
    if (egress) return { sent: [], retry: batch, dropped: [], reason: egress[1], egressRefused: true }
    // Claude Code refused this one request, for example for its size.
    if (/\$\.http\.fetch: \S+ refused: /.test(message)) {
      return { sent: [], retry: [], dropped: batch, reason: message, retryLater: false, refusedByClaudeCode: true }
    }
    // The token or the request failed before BigQuery answered.
    return { sent: [], retry: batch, dropped: [], reason: message, retryLater: true }
  }
}

// Whether an outcome calls for a backoff before the next attempt.
function isFailure(outcome) {
  return outcome.retryLater || (outcome.sent.length === 0 && outcome.dropped.length === 0)
}

// Warns about rows an outcome dropped, or will send again after waitMs.
async function report($, outcome, waitMs) {
  if (outcome.dropped.length > 0) {
    await warnOnce(
      $,
      'dropped:' + outcome.reason,
      (outcome.refusedByClaudeCode
        ? 'Claude Code refused the request for ' + outcome.dropped.length + " row(s), so they won't be sent: "
        : outcome.missingTable
          ? outcome.dropped.length + " row(s) won't be sent: "
          : 'BigQuery refused ' + outcome.dropped.length + " row(s), so they won't be sent: ") + outcome.reason,
    )
  }
  if (isFailure(outcome)) {
    await warnOnce(
      $,
      'retry:' + outcome.reason,
      'could not send rows to BigQuery; trying again in about ' + Math.ceil(waitMs / 1000) + ' s: ' + outcome.reason,
    )
  }
}

// Sends a batch, all for one table, after removing the labels that table
// has no column for.
async function send($, batch) {
  const table = batch[0].table
  const fields = await fieldsOf($, table)
  if (fields === 'missing') {
    return {
      sent: [], retry: [], dropped: batch, retryLater: false, missingTable: true,
      reason: 'the table ' + config.project + ':' + config.dataset + '.' + table + " doesn't exist. Check the " +
        'project, dataset and table_prefix options. If they are right, this is a kind of event setup.sh made no ' +
        'table for: add it to event-labels.json and run setup.sh again.',
    }
  }
  if (fields) {
    for (const item of batch) {
      const fitted = fitToTable(item.json, fields)
      item.json = fitted.json
      for (const name of fitted.dropped) {
        // Debug log only: this can happen in every session until setup.sh is run again.
        if (!state.warned.has('column:' + table + '.' + name)) {
          state.warned.add('column:' + table + '.' + name)
          console.warn(
            LOG_PREFIX + 'the table ' + table + ' has no column ' + name +
              (name.startsWith('labels.') ? ' and no labels.extra_labels' : '') +
              ", so that value isn't sent. Run setup.sh again to add the missing columns.",
          )
        }
      }
    }
  }
  // The credentials' email address goes only into the request, never into
  // item.json, so it is never written to the store with unsent rows.
  const email = batch.some((item) => item.wantsEmail) ? await emailOf($) : ''
  const toSend = batch.map((item) => withEmail(item, email, fields))
  const response = await call($, 'POST', tableUrlOf(table) + '/insertAll', insertAllBody(toSend))
  if (response.status === 403) {
    await noteAuthProblem($, 'permission', outcomeOf(batch, response.status, response.text).reason)
  } else if (response.ok) {
    await clearAuthProblem($)
  }
  return outcomeOf(batch, response.status, response.text)
}

// The item to send: with labels.user_email set to email when the item wants
// it, has none, and its table has that column (or its columns are unknown).
function withEmail(item, email, fields) {
  if (!email || !item.wantsEmail || item.json.labels?.user_email) return item
  const labelFields = fields?.find?.((f) => f.name === 'labels')?.fields
  if (labelFields && !labelFields.some((f) => f.name === 'user_email')) return item
  return { ...item, json: { ...item.json, labels: { ...item.json.labels, user_email: truncated(email, MAX_VALUE_BYTES) } } }
}

function tableUrlOf(table) {
  return (
    config.apiBase +
    '/bigquery/v2/projects/' + encodeURIComponent(config.project) +
    '/datasets/' + encodeURIComponent(config.dataset) +
    '/tables/' + encodeURIComponent(table)
  )
}

// The table's columns from tables.get, read at most every 10 minutes:
// 'missing' if the table doesn't exist, or undefined if BigQuery refused to
// show them (BigQuery then drops the values that have no column). Throws when
// the read should be tried again later (401, 408, 429, 5xx, network).
async function fieldsOf($, table) {
  const now = await $.clock.now()
  const known = state.tables.get(table)
  if (known && now - known.readAt < TABLE_FIELDS_REUSE_MS) return known.fields
  if (!state.tableReads.has(table)) {
    state.tableReads.set(table, readFields($, table, now).finally(() => state.tableReads.delete(table)))
  }
  return state.tableReads.get(table)
}

async function readFields($, table, now) {
  const response = await call($, 'GET', tableUrlOf(table) + '?fields=schema')
  if (response.status === 404) {
    state.tables.set(table, { fields: 'missing', readAt: now })
    return 'missing'
  }
  if (response.status === 401 || response.status === 408 || response.status === 429 || response.status >= 500) {
    throw new Error('could not read the columns of ' + table + ': HTTP ' + response.status)
  }
  let fields
  try {
    fields = response.ok ? JSON.parse(response.text).schema?.fields : undefined
  } catch {
    fields = undefined
  }
  if (!Array.isArray(fields)) {
    state.tables.set(table, { fields: undefined, readAt: now })
    await warnOnce(
      $,
      'fields',
      'could not read the columns of ' + table + ' (HTTP ' + response.status + '), so values the table has no column for ' +
        'are dropped by BigQuery without a warning. Writers need bigquery.tables.get as well as bigquery.tables.updateData.',
    )
    return undefined
  }
  state.tables.set(table, { fields, readAt: now })
  return fields
}

// A request to BigQuery with the token, sent once more with a new token after a 401.
async function call($, method, url, body) {
  let { response, token } = await fetchWithToken($, method, url, body)
  if (response.status === 401 && config.auth !== 'none') {
    // The token may have expired early: get a new one and try once more. Only
    // the token this request used is thrown away, so that requests answered
    // 401 at the same time share one new token.
    if (state.token?.value === token) state.token = undefined
    ;({ response } = await fetchWithToken($, method, url, body))
    if (response.status === 401) {
      await noteAuthProblem($, 'credentials', 'BigQuery rejected the credentials (HTTP 401) even after getting a new token')
    }
  }
  if (response.ok && state.authProblem?.kind === 'credentials') await clearAuthProblem($)
  return response
}

async function fetchWithToken($, method, url, body) {
  const headers = {}
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  const token = await tokenOf($)
  if (token) {
    // problemOf() already refused such an api_base; this is a second check.
    if (!isGoogleApi(url)) throw new Error('refusing to send a Google token to ' + new URL(url).origin)
    headers.Authorization = 'Bearer ' + token
  }
  if (config.quotaProject) headers['x-goog-user-project'] = config.quotaProject
  const response = await $.http.fetch(url, body === undefined ? { method, headers } : { method, headers, body })
  return { response, token }
}

// An OAuth access token for BigQuery, or '' when auth is "none". Callers
// share one fetch while it runs, so gcloud never runs twice at once.
async function tokenOf($) {
  if (config.auth === 'none') return ''
  const now = await $.clock.now()
  if (state.token && state.token.expiresAt > now) return state.token.value
  if (!state.tokenRequest) {
    state.tokenRequest = newToken($, now)
      .catch(async (error) => {
        await noteAuthProblem($, 'credentials', messageOf(error))
        throw error
      })
      .finally(() => {
        state.tokenRequest = undefined
      })
  }
  return state.tokenRequest
}

async function newToken($, now) {
  let value
  let lifetimeMs = GCLOUD_TOKEN_REUSE_MS
  if (config.auth === 'metadata') {
    const response = await $.http.fetch(METADATA_TOKEN_URL, { headers: { 'Metadata-Flavor': 'Google' } })
    if (!response.ok) throw new Error('the metadata server answered HTTP ' + response.status + ' when asked for an access token')
    const body = JSON.parse(response.text)
    value = body.access_token
    const expiresIn = Number(body.expires_in)
    // Reuse it until a minute before it expires; if the answer doesn't say, for 5 minutes.
    lifetimeMs = Number.isFinite(expiresIn) ? Math.max(0, (expiresIn - 60) * 1000) : 5 * 60 * 1000
  } else {
    const run =
      config.auth === 'gcloud'
        ? await $.process.run(['gcloud', 'auth', 'print-access-token'], { timeoutMs: 20_000 })
        : await $.process.run(['gcloud', 'auth', 'application-default', 'print-access-token'], { timeoutMs: 20_000 })
    if (run.exitCode !== 0) {
      throw new Error('gcloud could not print an access token (exit ' + run.exitCode + '): ' + errorLine(run.stderr))
    }
    value = run.stdout.trim()
  }
  if (!value) throw new Error('the ' + (config.auth === 'metadata' ? 'metadata server' : 'gcloud command') + ' returned no access token')
  state.token = { value, expiresAt: now + lifetimeMs }
  return value
}

// The email address of the account the credentials belong to, or '' when it
// is off, unknown, or can't be found. Looked up once per process; a failed
// lookup is tried again after 10 minutes, and one that failed only because
// there was no token, with the next send. Never throws.
async function emailOf($) {
  if (!config.emailFromCredentials || config.auth === 'none') return ''
  const now = await $.clock.now()
  if (state.email && (state.email.value || now - state.email.readAt < EMAIL_RETRY_MS)) return state.email.value
  if (!state.emailRequest) {
    state.emailRequest = lookUpEmail($)
      .then((value) => {
        state.email = { value, readAt: now }
        return value
      })
      .catch(async (error) => {
        // No token, or Claude Code refuses the mod's requests: send() reports
        // that already, and the lookup can run again.
        if (error?.noToken || /\$\.http\.fetch: refused: /.test(messageOf(error))) return ''
        state.email = { value: '', readAt: now }
        await warnOnce($, 'email', "could not find the credentials' email address, so rows without a user.email " +
          'attribute are sent without one: ' + messageOf(error))
        return ''
      })
      .finally(() => {
        state.emailRequest = undefined
      })
  }
  return state.emailRequest
}

async function lookUpEmail($) {
  if (config.auth === 'metadata') {
    const response = await $.http.fetch(METADATA_EMAIL_URL, { headers: { 'Metadata-Flavor': 'Google' } })
    if (!response.ok) throw new Error('the metadata server answered HTTP ' + response.status)
    return response.text.trim()
  }
  // Google's tokeninfo endpoint names the account a token was issued to, when
  // it has the email scope (gcloud's tokens have it by default). The token
  // goes in the body, not the URL.
  const token = await tokenOf($).catch((error) => {
    throw Object.assign(new Error(messageOf(error)), { noToken: true })
  })
  if (!isGoogleApi(TOKENINFO_URL)) throw new Error('refusing to send a Google token to ' + new URL(TOKENINFO_URL).origin)
  const response = await $.http.fetch(TOKENINFO_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'access_token=' + encodeURIComponent(token),
  })
  if (!response.ok) throw new Error('tokeninfo answered HTTP ' + response.status)
  const info = JSON.parse(response.text)
  if (!info.email) throw new Error("the token has no email scope, so tokeninfo doesn't name its account")
  if (String(info.email_verified) !== 'true') throw new Error('tokeninfo says the email address is not verified')
  return String(info.email)
}

// Called at exit. Saves unsent rows first, because Claude Code may stop
// the mod at any moment now, then sends them if a token is at hand, taking
// at most half of what is left of the shared exit budget, and at most 1 s.
async function finish($, budget) {
  state.ended = true
  if (state.disabled) return
  await spool($)
  if (state.queue.length === 0 && state.inFlight.length === 0) return
  const waitMs = Math.min((budget?.remainingMs ?? 0) / 2, 1000)
  const hasToken = config.auth === 'none' || (state.token && state.token.expiresAt > (await $.clock.now()))
  if (!hasToken || waitMs < 200) return
  state.retryAt = 0
  await Promise.race([flush($), $.clock.sleep(waitMs)])
}

// Writes the unsent rows (the batches being sent and the queue) under this
// process's key, or removes the key when nothing is left. Returns true only
// if every unsent row is now saved. Writes run one at a time, each saving
// what is unsent when it runs, so the last one always reflects the latest state.
function spool($) {
  const write = state.spoolWrites.then(() => writeSpool($))
  state.spoolWrites = write
  return write
}

async function writeSpool($) {
  const rows = []
  let bytes = 0
  let lost = 0
  for (const item of [...state.inFlight, ...state.queue]) {
    if (bytes + item.bytes > MAX_SPOOL_BYTES) {
      lost += 1
      continue
    }
    rows.push({ table: item.table, insertId: item.insertId, json: item.json })
    bytes += item.bytes
  }
  try {
    if (rows.length === 0) {
      if (state.spooled) await $.store.delete(state.spoolKey)
    } else {
      await $.store.set(state.spoolKey, { writtenAt: await $.clock.now(), rows })
    }
    state.spooled = rows.length > 0
  } catch (error) {
    console.warn(LOG_PREFIX + 'could not save unsent rows; they are lost if Claude Code exits before sending them: ' + messageOf(error))
    return false
  }
  if (lost > 0) {
    console.warn(
      LOG_PREFIX + lost + ' unsent row(s) were not saved because a session may save only 1 MiB; ' +
        'they are lost if Claude Code exits before sending them',
    )
  }
  return lost === 0
}

// Takes over rows that other sessions saved, whole keys at a time while
// they fit in this session's 1 MiB: queues them and saves them under this
// process's key, then removes the old keys; if that save fails, it removes
// each old key once its rows are sent. A key can belong to a running session
// waiting to retry; taking it can duplicate rows, which the spend views remove.
async function replaySpool($) {
  try {
    const now = await $.clock.now()
    const taken = []
    const rows = []
    let bytes = state.queuedBytes
    for (const key of await $.store.keys()) {
      if (!key.startsWith(SPOOL_PREFIX) || key === state.spoolKey) continue
      const saved = await $.store.get(key)
      if (saved && now - Number(saved.writtenAt ?? 0) < SPOOL_MIN_AGE_MS) continue
      const keyRows = []
      for (const r of Array.isArray(saved?.rows) ? saved.rows : []) {
        // A saved row goes to its event's table under the current table_prefix,
        // which may differ from the one it was saved with, so r.table is only
        // checked for being there. Anything else is dropped.
        const table = typeof r?.table === 'string' && r.json && typeof r.json === 'object' ? savedTableOf(r.json) : ''
        if (table && typeof r.insertId === 'string') {
          keyRows.push({ table, insertId: r.insertId, json: r.json, bytes: jsonBytes(r.json) })
        }
      }
      const keyBytes = keyRows.reduce((sum, r) => sum + r.bytes, 0)
      if (bytes + keyBytes > MAX_SPOOL_BYTES) continue
      bytes += keyBytes
      taken.push({ key, ids: new Set(keyRows.map((r) => r.insertId)) })
      rows.push(...keyRows)
    }
    if (taken.length === 0) return
    pushFront(rows)
    if (await spool($)) {
      for (const { key } of taken) await $.store.delete(key)
    } else {
      state.taken.push(...taken)
    }
  } catch (error) {
    await warnOnce($, 'replay', 'could not pick up rows that earlier sessions saved; they stay saved for a later session: ' + messageOf(error))
  }
}

// The table for a saved row, from the event name at the end of its logName.
function savedTableOf(json) {
  const match = typeof json.logName === 'string' ? json.logName.match(/\/logs\/([^/]+)$/) : null
  if (!match) return ''
  try {
    return tableNameOf(decodeURIComponent(match[1]), config.tablePrefix)
  } catch {
    return ''
  }
}

// Removes other sessions' keys whose rows have all been sent or dropped.
async function releaseTaken($, done) {
  for (const item of done) for (const t of state.taken) t.ids.delete(item.insertId)
  const finished = state.taken.filter((t) => t.ids.size === 0)
  state.taken = state.taken.filter((t) => t.ids.size > 0)
  for (const { key } of finished) await $.store.delete(key)
}

async function disable($, reason) {
  state.disabled = reason
  // Saves what is unsent, including rows taken over from other sessions,
  // for a later session that may be able to send it. Once that is saved,
  // the other sessions' keys holding the taken rows can go.
  if ((await spool($)) && state.taken.length > 0) {
    try {
      for (const { key } of state.taken) await $.store.delete(key)
      state.taken = []
    } catch (error) {
      console.warn(LOG_PREFIX + 'could not remove rows another session saved: ' + messageOf(error))
    }
  }
  state.queue = []
  state.queuedBytes = 0
  state.inFlight = []
  await warnOnce($, 'disabled', 'no rows will be sent to BigQuery: ' + reason)
}

// Records why rows can't be written, and redraws the band. The first time
// each kind of problem appears in this process, a toast says so too.
async function noteAuthProblem($, kind, reason) {
  if (config.auth === 'none') return
  const changed = state.authProblem?.kind !== kind || state.authProblem?.reason !== reason
  state.authProblem = { kind, reason }
  if (!changed) return
  redraw($)
  if (!state.toasted.has(kind)) {
    state.toasted.add(kind)
    try {
      await $.ui.toast('BigQuery telemetry. ' + problemSummary(), { timeoutMs: 15_000 })
    } catch {
      // Not every surface shows toasts; the band and the log still say it.
    }
  }
  await warnOnce($, 'auth:' + kind + ':' + reason, problemSummary() + ' (' + reason + ')')
}

async function clearAuthProblem($) {
  if (!state.authProblem) return
  state.authProblem = undefined
  redraw($)
}

function redraw($) {
  try {
    $.ui.invalidate('ui.render')
  } catch {
    // No drawing surface (claude -p, the SDK).
  }
}

// One sentence: what's wrong and how to fix it.
function problemSummary() {
  const p = state.authProblem
  if (!p) return ''
  if (p.kind === 'permission') {
    return 'Rows are not being written: missing BigQuery permission. Ask an admin to grant ' +
      'bigquery.tables.updateData on ' + config.project + ':' + config.dataset + '.'
  }
  const fix = {
    adc: 'run: gcloud auth application-default login',
    gcloud: 'run: gcloud auth login',
    metadata: "check this machine's attached service account",
  }[config.auth]
  return 'Rows are not being written: no working Google credentials. To fix, ' + fix + '.'
}

function authBand(Box, Text) {
  const waiting = state.queue.length + state.inFlight.length
  const blocking = config.onAuthFailure === 'block' && state.authProblem.kind === 'credentials'
  const parts = [
    Text({ color: blocking ? 'red' : 'yellow', bold: true, children: '⚠ BigQuery telemetry: ' }),
    Text({ children: problemSummary().replace(/^Rows are not being written: /, '') }),
  ]
  if (waiting > 0) parts.push(Text({ dimColor: true, children: '  ' + waiting + ' row(s) waiting' }))
  if (blocking) parts.push(Text({ color: 'red', children: '  Prompts are blocked until this is fixed.' }))
  return Box({ flexDirection: 'row', flexWrap: 'wrap', paddingX: 1, children: parts })
}

// With on_auth_failure "block": why a prompt can't go ahead, or '' if it can.
async function blockingProblem($) {
  if (state.disabled) return 'bigquery-telemetry: prompts are blocked because no rows can be sent to BigQuery: ' + state.disabled
  if (config.auth === 'none') return ''
  // Neither side of the race rejects, so whichever loses is simply ignored.
  const outcome = await Promise.race([
    tokenOf($).then(() => ({ ok: true }), (error) => ({ error })),
    $.clock.sleep(AUTH_CHECK_TIMEOUT_MS).then(() => ({ error: new Error('timed out getting a Google token') })),
  ])
  if (outcome.error) {
    if (!state.authProblem) await noteAuthProblem($, 'credentials', messageOf(outcome.error))
    return 'bigquery-telemetry: prompts are blocked until telemetry can be recorded. ' + problemSummary()
  }
  // A token was found. If BigQuery rejected the last one, check again before
  // letting the prompt through: a 401 here means the credentials are still bad.
  if (state.authProblem?.kind === 'credentials') {
    try {
      const response = await call($, 'GET', tableUrlOf(tableNameOf('user_prompt', config.tablePrefix)) + '?fields=schema')
      if (response.status === 401) {
        return 'bigquery-telemetry: prompts are blocked until telemetry can be recorded. ' + problemSummary()
      }
      await clearAuthProblem($)
    } catch (error) {
      // BigQuery rejected these credentials before and couldn't be reached to
      // check again: fail closed, as the gate is meant to.
      return 'bigquery-telemetry: prompts are blocked: BigQuery rejected the credentials earlier, and checking ' +
        'them again failed (' + messageOf(error) + '). ' + problemSummary()
    }
  }
  return ''
}

async function warn($, text) {
  console.warn(LOG_PREFIX + text)
  try {
    await $.ui.log(text) // Claude Code adds the mod's name
  } catch {
    // Some surfaces have no transcript to write to; the debug log has it.
  }
}

async function warnOnce($, key, text) {
  if (state.warned.has(key)) {
    console.warn(LOG_PREFIX + text)
    return
  }
  state.warned.add(key)
  await warn($, text)
}

function isUrl(text) {
  try {
    const url = new URL(text)
    return url.protocol === 'https:' || url.protocol === 'http:'
  } catch {
    return false
  }
}

function isGoogleApi(text) {
  try {
    const url = new URL(text)
    return url.protocol === 'https:' && (url.hostname === 'googleapis.com' || url.hostname.endsWith('.googleapis.com'))
  } catch {
    return false
  }
}

// One line from a command's error output, without control characters and at
// most 200 characters: gcloud's ERROR: line if there is one (it can follow
// WARNING: lines), else the first line. The rest (instructions, URLs) would
// garble a one-line warning.
function errorLine(text) {
  const lines = String(text ?? '').split(/\r?\n/).map((l) => l.trim()).filter((l) => l)
  const line = lines.find((l) => l.startsWith('ERROR:')) ?? lines[0] ?? ''
  const clean = line.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ')
  return clean.length > 200 ? clean.slice(0, 199) + '…' : clean
}

function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}
