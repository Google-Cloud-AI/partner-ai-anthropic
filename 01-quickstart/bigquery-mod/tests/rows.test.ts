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

import { expect, test } from 'claude-code/testing'

import {
  fieldNameOf,
  fitToTable,
  jsonBytes,
  labelValueOf,
  outcomeOf,
  resourceAttributesOf,
  resourceOf,
  rowOf,
  sessionFieldsOf,
  tableNameOf,
  takeBatch,
  truncated,
  wantsHostname,
} from '../hooks/rows.mjs'

const resource = resourceAttributesOf('gcp.project_id=example-project,cloud.region=us-east5,user.email=ada%40example.com', undefined)
const context = sessionFieldsOf(resource, 'bigquery-project', 'laptop-7')

// By default Claude Code copies the OTEL_RESOURCE_ATTRIBUTES keys onto each record.
const apiRequest = {
  to: 'collector',
  event: 'api_request',
  loggedAt: '2026-01-02T03:04:05.678Z',
  attributes: {
    'gcp.project_id': 'example-project',
    'cloud.region': 'us-east5',
    'user.email': 'ada@example.com',
    'session.id': 'session-1',
    'event.name': 'api_request',
    'event.sequence': 34,
    'workspace.host_paths': ['/a', '/b'],
    model: 'claude-example',
    cost_usd: 0.000188,
  },
}

test('a record becomes a row in its event\'s table, in the sink\'s layout', async () => {
  const { table, json } = rowOf(apiRequest, context, 'id-1', '2026-01-02T03:04:06.000Z')
  expect(table).toBe('api_request')
  expect(json).toEqual({
    timestamp: '2026-01-02T03:04:05.678Z',
    receiveTimestamp: '2026-01-02T03:04:06.000Z',
    // The project comes from the options, not from a gcp.project_id attribute.
    logName: 'projects/bigquery-project/logs/api_request',
    resource: {
      type: 'generic_task',
      labels: { project_id: 'bigquery-project', task_id: 'laptop-7', location: 'us-east5', namespace: '', job: 'claude-code' },
    },
    severity: 'DEFAULT',
    textPayload: 'claude_code.api_request',
    // The record's attributes only, as strings, under the sink's field names.
    labels: {
      gcp_project_id: 'example-project',
      cloud_region: 'us-east5',
      user_email: 'ada@example.com',
      session_id: 'session-1',
      event_name: 'api_request',
      event_sequence: '34',
      workspace_host_paths: '["/a","/b"]',
      model: 'claude-example',
      cost_usd: '0.000188',
    },
    insertId: 'id-1',
  })
})

test('the log ID and table are always the event name', async () => {
  // Attributes Google's page ranks ahead of event.name don't rename the log.
  const entry = { ...apiRequest, attributes: { 'event.name': 'api_request', 'service.name': 'team-cli', 'log.name': 'audit' } }
  const { table, json } = rowOf(entry, context, 'id-2', '')
  expect(table).toBe('api_request')
  expect(json.logName).toBe('projects/bigquery-project/logs/api_request')
  expect(rowOf(apiRequest, context, 'id-3', '', 'test_').table).toBe('test_api_request')
  expect(tableNameOf('compute.googleapis.com/activity-log')).toBe('compute_googleapis_com_activity_log')
})

test('label keys get the field names a sink gives them', async () => {
  expect(fieldNameOf('session.id')).toBe('session_id')
  expect(fieldNameOf('User.Account_UUID')).toBe('user_account_uuid')
  expect(fieldNameOf('k8s-pod/app')).toBe('k8s_pod_app')
  expect(fieldNameOf('__proto__')).toBe('proto__')
  expect(fieldNameOf('...')).toBe('')
  expect(fieldNameOf('x'.repeat(200)).length).toBe(128)
  // Two keys that get the same name: the first one stays. A key with no name left is skipped.
  const { json } = rowOf({ ...apiRequest, attributes: { 'team.id': 'a', team_id: 'b', '...': 'c' } }, context, 'id-4', '')
  expect(json.labels).toEqual({ team_id: 'a' })
})

test('OTEL_SERVICE_NAME names the job', async () => {
  const attributes = resourceAttributesOf('gcp.project_id=p', 'my-service')
  expect(sessionFieldsOf(attributes, 'f', 'laptop-7').resource.labels.job).toBe('my-service')
})

test('OTEL_RESOURCE_ATTRIBUTES is read forgivingly', async () => {
  const read = (text: string) => ({ ...resourceAttributesOf(text, undefined) })
  expect(read('gcp.project_id="p",team=a%20b')).toEqual({ 'service.name': 'claude-code', 'gcp.project_id': 'p', team: 'a b' })
  expect(read('constructor=x,toString=y')).toEqual({ 'service.name': 'claude-code', constructor: 'x', toString: 'y' })
  // A bad pair is skipped or kept as it is; it doesn't drop the others.
  expect(read('a=b=c,=x,novalue,team=data')).toEqual({ 'service.name': 'claude-code', a: 'b=c', team: 'data' })
  expect(read('team=data,x=%E0%A4%A,y=has space')).toEqual({ 'service.name': 'claude-code', team: 'data', x: '%E0%A4%A', y: 'has space' })
  expect(Object.keys(resourceAttributesOf('__proto__=x', undefined))).toEqual(['service.name', '__proto__'])
})

test('the resource is always generic_task, whatever the attributes say', async () => {
  // Attributes that would pick another type by Google's mapping don't here.
  const attributes = {
    'service.name': 'claude-code',
    'cloud.platform': 'gcp_compute_engine',
    'k8s.cluster.name': 'c',
    'gcp.resource_type': 'global',
    'gcp.project_id': 'other-project',
    'cloud.availability_zone': 'us-east5-a',
    'cloud.region': 'us-east5',
    'service.namespace': 'eng',
  }
  expect(resourceOf(attributes, 'p', 'laptop-7')).toEqual({
    type: 'generic_task',
    labels: { project_id: 'p', location: 'us-east5-a', namespace: 'eng', job: 'claude-code', task_id: 'laptop-7' },
  })
  // With no hostname (hostname_task_id off, or none found) task_id is empty.
  expect(resourceOf(attributes, 'p').labels.task_id).toBe('')
  // Characters outside the BMP become one underscore each, as in setup.sh.
  expect(fieldNameOf('a😀b')).toBe('a_b')
})

test('with no OTEL_RESOURCE_ATTRIBUTES, the project comes from the options and task_id from the hostname', async () => {
  const attributes = resourceAttributesOf(undefined, undefined)
  expect(wantsHostname(attributes)).toBe(true)
  expect(sessionFieldsOf(attributes, 'example-project', 'laptop-7')).toEqual({
    logProject: 'example-project',
    resource: {
      type: 'generic_task',
      labels: { project_id: 'example-project', task_id: 'laptop-7', location: '', namespace: '', job: 'claude-code' },
    },
  })
})

test('service.instance.id, when set, is the task_id instead of the hostname', async () => {
  const attributes = resourceAttributesOf('service.instance.id=dev-host-1', undefined)
  // service.instance.id already picks the resource, so the mod doesn't look up the hostname.
  expect(wantsHostname(attributes)).toBe(false)
  expect(sessionFieldsOf(attributes, 'example-project', 'other-host').resource.labels.task_id).toBe('dev-host-1')
})

test('long label values and keys are cut, ending in an ellipsis', async () => {
  const bytes = (s: string) => new TextEncoder().encode(s).length
  expect(truncated('short', 10)).toBe('short')
  expect(truncated('abcdefghijkl', 10)).toBe('abcdefg…')
  // A character is never cut in half: "é" is 2 bytes and the emoji 4.
  expect(truncated('éééééé', 10)).toBe('ééé…')
  expect(truncated('a😀😀', 8)).toBe('a😀…')
  expect(truncated('a😀😀', 7)).toBe('a…')
  const { json } = rowOf({ ...apiRequest, attributes: { prompt: 'x'.repeat(70_000) } }, context, 'id-5', '')
  expect(bytes(json.labels.prompt)).toBe(64 * 1024)
  expect(json.labels.prompt.endsWith('…')).toBe(true)
})

test('label values are strings', async () => {
  expect(labelValueOf(0.000188)).toBe('0.000188')
  expect(labelValueOf(12)).toBe('12')
  expect(labelValueOf(true)).toBe('true')
  expect(labelValueOf(['a', 'b'])).toBe('["a","b"]')
  expect(labelValueOf({ a: 1 })).toBe('{"a":1}')
})

test('a span fills trace with the bare trace ID, and traceSampled only when sampled', async () => {
  const traceId = '0af7651916cd43dd8448eb211c80319c'
  const sampled = rowOf({ ...apiRequest, span: { traceId, spanId: 'b7ad6b7169203331', traceFlags: 1 } }, context, 'id-6', '').json
  expect(sampled.trace).toBe(traceId)
  expect(sampled.spanId).toBe('b7ad6b7169203331')
  expect(sampled.traceSampled).toBe(true)
  const unsampled = rowOf({ ...apiRequest, span: { traceId, spanId: 'b7ad6b7169203331', traceFlags: 0 } }, context, 'id-7', '').json
  expect('traceSampled' in unsampled).toBe(false)
  expect('trace' in rowOf(apiRequest, context, 'id-8', '').json).toBe(false)
})

test('a row keeps only the labels its table has columns for, and names the rest', async () => {
  const fields = [
    { name: 'resource', type: 'RECORD', fields: [{ name: 'type', type: 'STRING' }, { name: 'labels', type: 'RECORD', fields: [{ name: 'project_id', type: 'STRING' }] }] },
    { name: 'labels', type: 'RECORD', fields: [{ name: 'model', type: 'STRING' }, { name: 'session_id', type: 'STRING' }] },
  ]
  const { json } = rowOf(apiRequest, context, 'id-9', '')
  const fitted = fitToTable(json, fields)
  expect(fitted.json.labels).toEqual({ session_id: 'session-1', model: 'claude-example' })
  expect(fitted.json.resource).toEqual({ type: 'generic_task', labels: { project_id: 'bigquery-project' } })
  expect(fitted.json.insertId).toBe('id-9')
  expect(fitted.dropped).toEqual([
    'labels.gcp_project_id', 'labels.cloud_region', 'labels.user_email', 'labels.event_name',
    'labels.event_sequence', 'labels.workspace_host_paths', 'labels.cost_usd',
    'resource.labels.location', 'resource.labels.namespace', 'resource.labels.job', 'resource.labels.task_id',
  ])
})

test('labels the table has no field for go into labels.extra_labels when it has one', async () => {
  const fields = [
    { name: 'resource', type: 'RECORD', fields: [{ name: 'type', type: 'STRING' }, { name: 'labels', type: 'RECORD', fields: [{ name: 'project_id', type: 'STRING' }] }] },
    { name: 'labels', type: 'RECORD', fields: [{ name: 'model', type: 'STRING' }, { name: 'extra_labels', type: 'STRING' }] },
  ]
  const record = { ...apiRequest, attributes: { model: 'claude-example', ttft_ms: 412, 'new.attr': 'x', extra_labels: 'clash' } }
  const fitted = fitToTable(rowOf(record, context, 'id-11', '').json, fields)
  expect(fitted.json.labels.model).toBe('claude-example')
  // Any attribute without its own field, whatever its name; nothing is dropped.
  expect(JSON.parse(fitted.json.labels.extra_labels)).toEqual({ ttft_ms: '412', new_attr: 'x', extra_labels: 'clash' })
  expect(fitted.dropped.filter((d: string) => d.startsWith('labels.'))).toEqual([])
  // No leftover attributes: no extra_labels value at all.
  const plain = fitToTable(rowOf({ ...apiRequest, attributes: { model: 'm' } }, context, 'id-12', '').json, fields)
  expect('extra_labels' in plain.json.labels).toBe(false)
})

test('batches hold one table\'s rows and stop at the row and byte limits, but always take one row', async () => {
  const queue = [1, 2, 3, 4, 5, 6].map((n) => ({ table: n === 2 ? 'b' : 'a', insertId: String(n), json: {}, bytes: 100 }))
  expect(takeBatch(queue, 2, 1000).map((i) => i.insertId)).toEqual(['1', '3'])
  expect(takeBatch(queue, 10, 1000).map((i) => i.insertId)).toEqual(['2'])
  expect(takeBatch(queue, 10, 150).map((i) => i.insertId)).toEqual(['4'])
  expect(takeBatch(queue, 10, 50).map((i) => i.insertId)).toEqual(['5'])
  expect(queue.map((i) => i.insertId)).toEqual(['6'])
  expect(takeBatch([], 10, 50)).toEqual([])
})

test('a row is measured as the JSON that is sent', async () => {
  const { json } = rowOf({ ...apiRequest, attributes: { body: 'x'.repeat(60_000) } }, context, 'id-10', '')
  expect(jsonBytes(json)).toBeGreaterThan(60_000)
  expect(jsonBytes(json)).toBeLessThan(61_000)
})

const batch = ['a', 'b', 'c'].map((id) => ({ table: 't', insertId: id, json: {}, bytes: 1 }))

test('stopped rows are sent again and invalid rows are dropped', async () => {
  const body = JSON.stringify({
    insertErrors: [
      { index: 0, errors: [{ reason: 'stopped', message: '' }] },
      { index: 1, errors: [{ reason: 'invalid', location: 'labels', message: 'bad value' }] },
      { index: 2, errors: [{ reason: 'stopped', message: '' }] },
    ],
  })
  const outcome = outcomeOf(batch, 200, body)
  expect(outcome.sent).toEqual([])
  expect(outcome.retry.map((i) => i.insertId)).toEqual(['a', 'c'])
  expect(outcome.dropped.map((i) => i.insertId)).toEqual(['b'])
  expect(outcome.reason).toBe('invalid (labels): bad value')
})

test('a 200 with no insertErrors sends every row', async () => {
  expect(outcomeOf(batch, 200, '{}').sent.length).toBe(3)
})

test('server errors and rate limits wait and retry the whole batch', async () => {
  for (const status of [401, 429, 500, 503]) {
    const outcome = outcomeOf(batch, status, '{"error":{"message":"try later"}}')
    expect(outcome.retryLater).toBe(true)
    expect(outcome.retry.length).toBe(3)
  }
  const quota = '{"error":{"message":"quota","errors":[{"reason":"quotaExceeded"}]}}'
  expect(outcomeOf(batch, 403, quota).retryLater).toBe(true)
})

test('a 403 waits and retries, since a permission can be granted later', async () => {
  const denied = '{"error":{"message":"Access Denied: Table p:d.t","errors":[{"reason":"accessDenied"}]}}'
  const outcome = outcomeOf(batch, 403, denied)
  expect(outcome.retryLater).toBe(true)
  expect(outcome.retry.length).toBe(3)
  expect(outcome.dropped.length).toBe(0)
  expect(outcome.reason).toBe('HTTP 403: Access Denied: Table p:d.t')
})

test('other client errors drop the batch with the reason', async () => {
  const outcome = outcomeOf(batch, 404, '{"error":{"message":"Not found: Table p:d.t"}}')
  expect(outcome.dropped.length).toBe(3)
  expect(outcome.retryLater).toBe(false)
  expect(outcome.reason).toBe('HTTP 404: Not found: Table p:d.t')
})
