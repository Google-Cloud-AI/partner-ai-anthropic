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

import { expect, mock, test } from 'claude-code/testing'

const options = { project: 'example-project', auth: 'gcloud', flush_interval_seconds: 5 }
const collectorRecord = (event: string, extra: Record<string, string | number> = {}) => ({
  to: 'collector' as const,
  event,
  loggedAt: '2026-01-02T03:04:05.678Z',
  attributes: { 'event.name': event, 'session.id': 'session-1', ...extra },
})

// The columns the fake BigQuery's tables have.
const string = (name: string) => ({ name, type: 'STRING', mode: 'NULLABLE' })
const tableFields = [
  { name: 'timestamp', type: 'TIMESTAMP' },
  { name: 'resource', type: 'RECORD', fields: [string('type'), { name: 'labels', type: 'RECORD', fields: ['project_id', 'location', 'namespace', 'job', 'task_id', 'node_id'].map(string) }] },
  { name: 'labels', type: 'RECORD', fields: ['event_name', 'session_id', 'cost_usd', 'model', 'user_email'].map(string) },
]

// Stubs for what the mod asks Claude Code for, with a fake BigQuery that
// answers each insertAll from `answers` (then 200 with no errors) and each
// tables.get with tableFields, or 404 for a table in missingTables.
function stubHost(
  on: any,
  answers: { status: number; text: string }[] = [],
  saved = new Map<string, unknown>(),
  { storeFull = false, tokenGate = Promise.resolve(), telemetryAnswer = { value: undefined } as object, missingTables = [] as string[], holdInsertsUntil = 0, hangTables = [] as string[], envDenied = false, fetchDenied = '', tokeninfo = { email: 'dev@example.com', email_verified: 'true' } as object, extraLabelsColumn = false, tokenFails = false } = {},
) {
  const requests: { url: string; headers: Record<string, string>; body: any; rows: any[] }[] = []
  const gets: string[] = []
  const lookups: { url: string; body?: string }[] = [] // tokeninfo and metadata email requests
  const runs: string[][] = []
  const uiLines: string[] = []
  const toasts: string[] = []
  let getsRefused = false // set with refuseGets(): tables.get can't reach BigQuery
  let tokenBroken = tokenFails // cleared with fixToken(), as if the developer signed in
  let tokenCalls = 0
  // With holdInsertsUntil, no insertAll is answered until that many are waiting.
  let releaseInserts = () => {}
  const insertsReleased = new Promise<void>((resolve) => (releaseInserts = resolve))
  on('env.get', () => (envDenied ? { deny: 'refused by a policy mod' } : { value: undefined }))
  on('session.version', () => ({ value: { version: '2.1.287', base: '2.1.287' } }))
  on('store.keys', () => ({ value: [...saved.keys()] }))
  on('store.get', ($: any, e: any) => ({ value: saved.get(e.key) }))
  on('store.set', ($: any, e: any) => {
    if (storeFull) return { deny: 'the store is over 4 MiB' }
    saved.set(e.key, e.value)
    return { value: undefined }
  })
  on('store.delete', ($: any, e: any) => {
    saved.delete(e.key)
    return { value: undefined }
  })
  on('process.run', async ($: any, e: any) => {
    runs.push(e.argv ?? e.command ?? e.args)
    if ((e.argv ?? e.command ?? e.args)?.[0] === 'hostname') return { value: { exitCode: 0, stdout: 'laptop-7\n', stderr: '' } }
    tokenCalls += 1
    const n = tokenCalls
    if (tokenBroken) {
      return { value: { exitCode: 1, stdout: '', stderr: 'WARNING: Could not open the configuration file: [/tmp/x/configurations/config_default].\nERROR: (gcloud.auth.application-default.print-access-token) Reauthentication failed.\nPlease run:\n\n  $ gcloud auth application-default login\n\nto obtain new credentials.\n' } }
    }
    await tokenGate
    return { value: { exitCode: 0, stdout: 'token-' + n + '\n', stderr: '' } }
  })
  on('ui.toast', ($: any, e: any) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.submit', ($: any, e: any) => ({ text: e.text }))
  on('ui.log', ($: any, e: any) => {
    uiLines.push(e.text ?? e.message ?? JSON.stringify(e))
    return { value: undefined }
  })
  on('http.fetch', async ($: any, e: any) => {
    if (fetchDenied) return { deny: fetchDenied }
    if (e.url === 'https://oauth2.googleapis.com/tokeninfo') {
      lookups.push({ url: e.url, body: e.init?.body })
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(tokeninfo) } }
    }
    if (e.url.endsWith('/service-accounts/default/email')) {
      lookups.push({ url: e.url })
      return { value: { status: 200, ok: true, headers: {}, text: 'writer@example-project.iam.gserviceaccount.com' } }
    }
    if (e.url.startsWith('http://metadata.google.internal/')) {
      tokenCalls += 1
      const text = JSON.stringify({ access_token: 'metadata-token-' + tokenCalls, expires_in: 3599 })
      return { value: { status: 200, ok: true, headers: {}, text } }
    }
    if ((e.init?.method ?? 'GET') === 'GET') {
      gets.push(e.url)
      if (getsRefused) return { deny: 'network unreachable' }
      const table = e.url.match(/\/tables\/([^/?]+)/)?.[1] ?? ''
      if (missingTables.includes(table)) return { value: { status: 404, ok: false, headers: {}, text: '{"error":{"message":"Not found: Table"}}' } }
      const fields = extraLabelsColumn
        ? tableFields.map((f) => (f.name === 'labels' ? { ...f, fields: [...(f as any).fields, string('extra_labels')] } : f))
        : tableFields
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ schema: { fields } }) } }
    }
    const body = JSON.parse(e.init.body)
    requests.push({ url: e.url, headers: e.init.headers, body, rows: body.rows })
    if (hangTables.some((t) => e.url.includes('/tables/' + t + '/'))) await new Promise(() => {})
    if (holdInsertsUntil > 0) {
      if (requests.length >= holdInsertsUntil) releaseInserts()
      await insertsReleased
    }
    const answer = answers.shift() ?? { status: 200, text: '{}' }
    return { value: { status: answer.status, ok: answer.status < 300, headers: {}, text: answer.text } }
  })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.end', ($: any, e: any) => ({ sessionId: e.sessionId }))
  on('telemetry.log', () => telemetryAnswer)
  return { requests, gets, lookups, runs, uiLines, toasts, saved, tokens: () => tokenCalls, refuseGets: () => (getsRefused = true), fixToken: () => (tokenBroken = false) }
}

test('queued records go out on the timer, one insertAll per event table', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('user_prompt') as any)
  await $.telemetry.log(collectorRecord('api_request', { cost_usd: 0.5 }) as any)
  await $.telemetry.log(collectorRecord('api_request', { cost_usd: 0.25 }) as any)
  expect(host.requests.length).toBe(0)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  const base = 'https://bigquery.googleapis.com/bigquery/v2/projects/example-project/datasets/claude_code_telemetry/tables/'
  expect(host.requests.map((r) => r.url)).toEqual([base + 'user_prompt/insertAll', base + 'api_request/insertAll'])
  expect(host.gets).toEqual([base + 'user_prompt?fields=schema', base + 'api_request?fields=schema'])
  const request = host.requests[1]
  expect(request.headers.Authorization).toBe('Bearer token-1')
  expect(request.body.ignoreUnknownValues).toBe(true)
  expect(request.rows.map((r: any) => r.json.labels.cost_usd)).toEqual(['0.5', '0.25'])
  expect(request.rows[0].json.textPayload).toBe('claude_code.api_request')
  expect(request.rows[0].json.logName).toBe('projects/example-project/logs/api_request')
  // No more specific resource, so the hostname makes it a generic_task.
  expect(request.rows[0].json.resource).toEqual({
    type: 'generic_task',
    labels: { project_id: 'example-project', task_id: 'laptop-7', location: '', namespace: '', job: 'claude-code' },
  })
  expect(request.rows[0].insertId).toBe(request.rows[0].json.insertId)
})

test('on a table without labels.extra_labels, labels with no column are left out, with nothing shown in the transcript', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request', { 'team.id': 'data', cost_usd: 1 }) as any)
  await $.telemetry.log(collectorRecord('api_request', { 'team.id': 'data' }) as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  expect(host.requests[0].rows[0].json.labels).toEqual({ event_name: 'api_request', session_id: 'session-1', cost_usd: '1', user_email: 'dev@example.com' })
  expect(host.requests[0].rows[1].json.labels).toEqual({ event_name: 'api_request', session_id: 'session-1', user_email: 'dev@example.com' })
  expect(host.uiLines.some((l) => l.includes('team_id'))).toBe(false)
})

test('batches for different tables are sent together at exit', { options }, async ($, on) => {
  const clock = mock.clock(on)
  // Each insertAll is answered only once all five are waiting, so this
  // finishes only if they are sent at the same time.
  const host = stubHost(on, [], new Map(), { holdInsertsUntil: 5 })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  for (const event of ['user_prompt', 'tool_decision', 'api_request', 'tool_result', 'assistant_response']) {
    await $.telemetry.log(collectorRecord(event) as any)
  }
  await $.session.end({ reason: 'other', sessionId: 'session-1' } as any)
  expect(host.requests.length).toBe(5)
  expect([...host.saved.keys()]).toEqual([])
})

test('at exit, rows whose table answered leave the store while a slow table\'s rows stay', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { hangTables: ['api_request'] })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('user_prompt') as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  const ending = $.session.end({ reason: 'other', sessionId: 'session-1' } as any)
  for (let i = 0; i < 20 && host.requests.length < 2; i++) await new Promise((resolve) => setTimeout(resolve, 5))
  await clock.advance(1000)
  await ending
  const saved = [...host.saved.values()] as any[]
  expect(saved.length).toBe(1)
  expect(saved[0].rows.map((r: any) => r.table)).toEqual(['api_request'])
})

test('a missing table is looked up once, not for every record', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { missingTables: ['new_event'] })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  for (let i = 0; i < 3; i++) await $.telemetry.log(collectorRecord('new_event') as any)
  await clock.advance(5000)
  await $.telemetry.log(collectorRecord('new_event') as any)
  await clock.advance(5000)
  expect(host.gets.length).toBe(1)
  expect(host.requests.length).toBe(0)
})

test('a table\'s columns are read once, not for every batch', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  expect(host.gets.length).toBe(1)
})

test('with hostname_task_id off, task_id is empty and hostname is never run', { options: { ...options, hostname_task_id: false } }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests[0].rows[0].json.resource).toEqual({
    type: 'generic_task',
    labels: { project_id: 'example-project', task_id: '', location: '', namespace: '', job: 'claude-code' },
  })
  expect(host.runs.some((argv) => argv?.[0] === 'hostname')).toBe(false)
})

test('a 500 keeps the rows, and the retry after the backoff sends the same insertIds', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [{ status: 500, text: '{"error":{"message":"backend"}}' }])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  await clock.advance(5000)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  expect(host.requests[1].rows[0].insertId).toBe(host.requests[0].rows[0].insertId)
})

test('a 401 fetches a new token and sends again at once', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [{ status: 401, text: '{"error":{"message":"Invalid Credentials"}}' }])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  expect(host.requests[1].headers.Authorization).toBe('Bearer token-2')
})

test('at exit, unsent rows are saved in the store', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [{ status: 503, text: '{}' }])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await $.session.end({ reason: 'other', sessionId: 'session-1' } as any)
  const keys = [...host.saved.keys()]
  expect(keys.length).toBe(1)
  expect(keys[0].startsWith('unsent:')).toBe(true)
  const rows = (host.saved.get(keys[0]) as any).rows
  expect(rows.length).toBe(1)
  expect(rows[0].table).toBe('api_request')
})

test('saved rows without a table or logName are dropped, and the rest go to the current prefix\'s table', { options }, async ($, on) => {
  const clock = mock.clock(on, { now: 100_000 })
  const saved = new Map<string, unknown>([
    ['unsent:old', { writtenAt: 0, rows: [
      { insertId: 'old-1', json: { insert_id: 'old-1' } },
      { table: 'old_api_request', insertId: 'new-1', json: { insertId: 'new-1', logName: 'projects/p/logs/api_request' } },
    ] }],
  ])
  const host = stubHost(on, [], saved)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await clock.advance(5000)
  expect(host.requests.map((r) => r.rows.map((x: any) => x.insertId))).toEqual([['new-1']])
  expect(host.requests[0].url.endsWith('/tables/api_request/insertAll')).toBe(true)
  expect([...saved.keys()]).toEqual([])
})

test('a new session sends rows an earlier session saved, once they are 30 seconds old', { options }, async ($, on) => {
  const clock = mock.clock(on, { now: 100_000 })
  const row = (id: string) => ({ table: 'api_request', insertId: id, json: { timestamp: '2026-01-02T03:04:05.678Z', logName: 'projects/p/logs/api_request', insertId: id } })
  const saved = new Map<string, unknown>([
    ['unsent:old:1', { writtenAt: 60_000, rows: [row('saved-1'), row('saved-2')] }],
    ['unsent:young:2', { writtenAt: 90_000, rows: [row('saved-3')] }],
  ])
  const host = stubHost(on, [], saved)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  expect(host.requests[0].rows.map((r: any) => r.insertId)).toEqual(['saved-1', 'saved-2'])
  expect([...saved.keys()]).toEqual(['unsent:young:2'])
})

test('a 429 waits for the backoff instead of retrying at once', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [{ status: 429, text: '{"error":{"message":"slow down"}}' }])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  expect(host.requests[1].rows[0].insertId).toBe(host.requests[0].rows[0].insertId)
})

test('a missing table drops its batch once, and other tables still get their rows', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { missingTables: ['new_event'] })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('new_event') as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  await clock.advance(5000)
  await clock.advance(5000)
  expect(host.requests.map((r) => r.url.split('/tables/')[1])).toEqual(['api_request/insertAll'])
  expect(host.uiLines.filter((l) => l.includes("1 row(s) won't be sent: the table example-project:claude_code_telemetry.new_event doesn't exist. Check the project, dataset and table_prefix options.")).length).toBe(1)
})

test('an insertAll answered 404 drops the batch once and does not retry it', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [{ status: 404, text: '{"error":{"message":"Not found: Table"}}' }])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  await clock.advance(5000)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
})

test('auth metadata takes its token from the metadata server', { options: { ...options, auth: 'metadata' } }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  expect(host.requests[0].headers.Authorization).toBe('Bearer metadata-token-1')
})

for (const apiBase of ['https://example.com', 'http://127.0.0.1:9050']) {
  test('a token is never sent to ' + apiBase, { options: { ...options, api_base: apiBase } }, async ($, on) => {
    const clock = mock.clock(on)
    const host = stubHost(on)
    await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
    await $.telemetry.log(collectorRecord('api_request') as any)
    await clock.advance(5000)
    expect(host.requests.length).toBe(0)
    expect(host.tokens()).toBe(0)
  })
}

test('saved rows never go to a non-Google api_base, even when the session\'s settings can\'t be read', { options: { ...options, api_base: 'https://example.com' } }, async ($, on) => {
  const clock = mock.clock(on, { now: 100_000 })
  const row = { table: 'api_request', insertId: 'saved-1', json: { logName: 'projects/p/logs/api_request', insertId: 'saved-1' } }
  const saved = new Map<string, unknown>([['unsent:old', { writtenAt: 0, rows: [row] }]])
  const host = stubHost(on, [], saved, { envDenied: true })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await clock.advance(5000)
  await clock.advance(5000)
  expect(host.requests.length).toBe(0)
  expect(host.gets.length).toBe(0)
  expect(host.tokens()).toBe(0)
  expect(host.uiLines.some((l) => l.includes('"api_base" option must be'))).toBe(true)
})

test('when Claude Code refuses every request, the mod stops and keeps the rows saved for a later session', { options }, async ($, on) => {
  const clock = mock.clock(on)
  // Claude Code's refusal reads "$.http.fetch: refused: <why>"; a stub's deny text follows "$.http.fetch: ".
  const host = stubHost(on, [], new Map(), { fetchDenied: 'refused: nonessential network traffic is disabled for this session' })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  await clock.advance(5000)
  const saved = [...host.saved.values()] as any[]
  expect(saved.length).toBe(1)
  expect(saved[0].rows.map((r: any) => r.table)).toEqual(['api_request'])
  expect(host.uiLines).toEqual([
    'no rows will be sent to BigQuery: Claude Code refused the request to BigQuery: nonessential network traffic is disabled for this session.',
  ])
})

test('credentials rejected twice keep the rows for a later retry', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const denied = { status: 401, text: '{"error":{"message":"Invalid Credentials"}}' }
  const host = stubHost(on, [denied, denied])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  await clock.advance(5000)
  expect(host.requests.length).toBe(3)
  expect(host.requests[2].rows[0].insertId).toBe(host.requests[0].rows[0].insertId)
})

test('a row over 256 KiB is dropped without holding up the rows after it', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  // Each value is cut to 64 KiB, so five of them make a row over 256 KiB.
  const big = Object.fromEntries([1, 2, 3, 4, 5].map((n) => ['body_' + n, 'x'.repeat(70_000)]))
  await $.telemetry.log(collectorRecord('api_request_body', big) as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  expect(host.requests[0].rows.map((r: any) => r.json.textPayload)).toEqual(['claude_code.api_request'])
})

test('when this session cannot save rows it took over, the old key goes once they are sent', { options }, async ($, on) => {
  const clock = mock.clock(on, { now: 100_000 })
  const row = (id: string) => ({ table: 'api_request', insertId: id, json: { timestamp: '2026-01-02T03:04:05.678Z', logName: 'projects/p/logs/api_request', insertId: id } })
  const saved = new Map<string, unknown>([['unsent:old:1', { writtenAt: 0, rows: [row('saved-1')] }]])
  const host = stubHost(on, [{ status: 503, text: '{}' }], saved, { storeFull: true })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(1)
  expect([...saved.keys()]).toEqual(['unsent:old:1'])
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  expect([...saved.keys()]).toEqual([])
})

test('a session takes over saved rows only up to 1 MiB', { options }, async ($, on) => {
  const clock = mock.clock(on, { now: 100_000 })
  const big = (id: string) => ({ table: 'api_request', insertId: id, json: { logName: 'projects/p/logs/api_request', insertId: id, labels: { model: 'x'.repeat(600_000) } } })
  const saved = new Map<string, unknown>([
    ['unsent:a', { writtenAt: 0, rows: [big('a-1')] }],
    ['unsent:b', { writtenAt: 0, rows: [big('b-1')] }],
  ])
  const host = stubHost(on, [{ status: 503, text: '{}' }], saved)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await clock.advance(5000)
  expect(host.requests[0].rows.map((r: any) => r.insertId)).toEqual(['a-1'])
  expect(saved.has('unsent:a')).toBe(false)
  expect(saved.has('unsent:b')).toBe(true)
})

test('the first send waits for the token the session start is already fetching', { options }, async ($, on) => {
  const clock = mock.clock(on)
  let release = () => {}
  const host = stubHost(on, [], new Map(), { tokenGate: new Promise<void>((resolve) => (release = resolve)) })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(0)
  release()
  await clock.advance(5000)
  expect(host.tokens()).toBe(1)
  expect(host.requests.length).toBe(1)
  expect(host.requests[0].headers.Authorization).toBe('Bearer token-1')
})

test('a record a later hook refuses is not sent', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { telemetryAnswer: { deny: 'refused by a later hook' } })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any).catch(() => {})
  await clock.advance(5000)
  expect(host.requests.length).toBe(0)
})

test('rows get the email address of the credentials, unless the record carries its own', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await $.telemetry.log(collectorRecord('api_request', { 'user.email': 'ada@example.com' }) as any)
  await clock.advance(5000)
  expect(host.requests[0].rows.map((r: any) => r.json.labels.user_email)).toEqual(['dev@example.com', 'ada@example.com'])
  // Looked up once, with the token in the body rather than the URL.
  expect(host.lookups).toEqual([{ url: 'https://oauth2.googleapis.com/tokeninfo', body: 'access_token=token-1' }])
})

test('with email_from_credentials off, no address is looked up or added', { options: { ...options, email_from_credentials: false } }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests[0].rows[0].json.labels.user_email).toBeUndefined()
  expect(host.lookups).toEqual([])
})

test('auth metadata takes the email address from the metadata server', { options: { ...options, auth: 'metadata' } }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests[0].rows[0].json.labels.user_email).toBe('writer@example-project.iam.gserviceaccount.com')
  expect(host.lookups.map((l) => l.url)).toEqual(['http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'])
})

test('a token without the email scope sends rows without an address, once warned', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { tokeninfo: { scope: 'https://www.googleapis.com/auth/cloud-platform' } })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.map((r) => r.rows[0].json.labels.user_email)).toEqual([undefined, undefined])
  expect(host.lookups.length).toBe(1)
  expect(host.uiLines.filter((l) => l.includes("could not find the credentials' email address")).length).toBe(1)
})

test('the email address is never written to the store with unsent rows', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [{ status: 503, text: '{}' }])
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests[0].rows[0].json.labels.user_email).toBe('dev@example.com')
  await $.session.end({ reason: 'other', sessionId: 'session-1' } as any)
  expect(JSON.stringify([...host.saved.values()])).not.toContain('dev@example.com')
})

test('labels with no column of their own go into labels.extra_labels, with no warning', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { extraLabelsColumn: true })
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request', { 'team.id': 'data', ttft_ms: 412, cost_usd: 1 }) as any)
  await clock.advance(5000)
  const labels = host.requests[0].rows[0].json.labels
  expect(labels.cost_usd).toBe('1')
  expect(JSON.parse(labels.extra_labels)).toEqual({ team_id: 'data', ttft_ms: '412' })
  expect(host.uiLines.some((l) => l.includes('extra_labels') || l.includes('team_id'))).toBe(false)
})

test('without working credentials, warn mode shows the fix once and lets prompts through', { options: { ...options, auth: 'adc' } }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { tokenFails: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  await clock.advance(5000)
  expect(host.toasts.length).toBe(1)
  expect(host.toasts[0]).toContain('gcloud auth application-default login')
  const result: any = await $.prompt.submit({ text: 'hello' } as any)
  expect(result.drop).toBeUndefined()
  expect(result.text).toBe('hello')
})

test('without working credentials, block mode refuses prompts with the fix (the option ignores case)', { options: { ...options, on_auth_failure: 'BLOCK' } }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { tokenFails: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  const result: any = await $.prompt.submit({ text: 'hello' } as any)
  expect(result.drop).toContain('prompts are blocked')
  expect(result.drop).toContain('gcloud auth login')
  expect(host.requests.length).toBe(0)
})

test('with working credentials, block mode lets prompts through', { options: { ...options, on_auth_failure: 'Block' } }, async ($, on) => {
  mock.clock(on)
  stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  const result: any = await $.prompt.submit({ text: 'hello' } as any)
  expect(result.drop).toBeUndefined()
  expect(result.text).toBe('hello')
})

test('a 403 warns with the missing permission but never blocks prompts', { options: { ...options, on_auth_failure: 'block' } }, async ($, on) => {
  const clock = mock.clock(on)
  const denied = { status: 403, text: '{"error":{"message":"Access Denied: Permission bigquery.tables.updateData denied"}}' }
  const host = stubHost(on, [denied])
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.toasts.some((t) => t.includes('bigquery.tables.updateData on example-project:claude_code_telemetry'))).toBe(true)
  const result: any = await $.prompt.submit({ text: 'hello' } as any)
  expect(result.drop).toBeUndefined()
})

test('an on_auth_failure that is neither warn nor block stops the mod with a message', { options: { ...options, on_auth_failure: 'enforce' } }, async ($, on) => {
  mock.clock(on)
  const host = stubHost(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  expect(host.uiLines.some((l) => l.includes('"on_auth_failure" option is "enforce"'))).toBe(true)
})

test('in block mode, after BigQuery rejects the credentials, a failed re-check refuses the prompt', { options: { ...options, on_auth_failure: 'block' } }, async ($, on) => {
  const clock = mock.clock(on)
  const rejected = { status: 401, text: '{"error":{"message":"Invalid Credentials"}}' }
  const host = stubHost(on, [rejected, rejected])
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  expect(host.requests.length).toBe(2)
  // tables.get for the re-check now can't reach BigQuery.
  host.refuseGets()
  const refused: any = await $.prompt.submit({ text: 'hello' } as any)
  expect(refused.drop).toContain('checking them again failed')
})

test('after signing in, the next prompt retries at once and rows go out', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { tokenFails: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  // Several failures in a row: the normal backoff would now be minutes long.
  for (let i = 0; i < 6; i++) await clock.advance(30_000)
  expect(host.requests.length).toBe(0)
  host.fixToken()
  await $.prompt.submit({ text: 'hello' } as any)
  await clock.advance(10)
  expect(host.requests.length).toBe(1)
})

test('while credentials fail, retries come at least every 30 s', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { tokenFails: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  for (let i = 0; i < 8; i++) await clock.advance(30_000)
  host.fixToken()
  await clock.advance(30_000)
  await clock.advance(5_000)
  expect(host.requests.length).toBe(1)
})

test('a failed gcloud command is reported by its ERROR line only', { options }, async ($, on) => {
  const clock = mock.clock(on)
  const host = stubHost(on, [], new Map(), { tokenFails: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
  await $.telemetry.log(collectorRecord('api_request') as any)
  await clock.advance(5000)
  const line = host.uiLines.find((l) => l.includes('could not print an access token'))
  expect(line).toContain('(exit 1): ERROR: (gcloud.auth.application-default.print-access-token) Reauthentication failed.')
  expect(line).not.toContain('Please run')
  expect(line).not.toContain('WARNING')
  expect(line).not.toContain('\n')
})
