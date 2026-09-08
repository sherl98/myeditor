import assert from 'node:assert/strict'
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  countSymbols,
  evaluateBudgets,
  logicalFileBytes,
  parseLinkeditBytes,
  sourceFingerprint,
} from '../../script/release/generate_release_manifest.mjs'

test('counts ordinary file bytes without following symbolic links', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor size manifest '))
  t.after(() => rm(root, { recursive: true, force: true }))

  await mkdir(path.join(root, 'nested'))
  await writeFile(path.join(root, 'first'), '1234')
  await writeFile(path.join(root, 'nested', 'second'), '123456')
  await symlink(path.join(root, 'first'), path.join(root, 'link'))

  assert.equal(await logicalFileBytes(root), 10)
})

test('parses Mach-O linkedit size and symbol visibility', () => {
  assert.equal(parseLinkeditBytes('Segment __TEXT: 786432\nSegment __LINKEDIT: 196608\n'), 196608)
  assert.deepEqual(
    countSymbols('000000 T _$s8MyEditor4mainyyF (external)\n000010 t helper (non-external)\n'),
    { total: 2, nonExternal: 1 },
  )
})

test('reports every budget check and fails on any overage', () => {
  assert.deepEqual(
    evaluateBudgets(
      { appLogicalBytes: 90, archiveBytes: 51 },
      { appLogicalBytes: 100, archiveBytes: 50 },
    ),
    {
      passed: false,
      checks: {
        appLogicalBytes: { actual: 90, limit: 100, passed: true },
        archiveBytes: { actual: 51, limit: 50, passed: false },
      },
    },
  )
})

test('source fingerprint changes with build inputs but ignores generated output', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor source fingerprint '))
  t.after(() => rm(root, { recursive: true, force: true }))

  await mkdir(path.join(root, 'Sources'), { recursive: true })
  await mkdir(path.join(root, 'dist'), { recursive: true })
  await writeFile(path.join(root, 'Package.swift'), 'first')
  await writeFile(path.join(root, 'Sources', 'App.swift'), 'app')
  const before = await sourceFingerprint(root)

  await writeFile(path.join(root, 'dist', 'generated'), 'ignored')
  assert.equal(await sourceFingerprint(root), before)

  await writeFile(path.join(root, 'Sources', 'App.swift'), 'changed')
  assert.notEqual(await sourceFingerprint(root), before)
})

test('fingerprint excludes audit evidence and tests but includes release tools', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor input boundaries '))
  t.after(() => rm(root, { recursive: true, force: true }))
  for (const name of ['script/audit', 'Tests', 'docs', 'script/release', 'Configurations'])
    await mkdir(path.join(root, name), { recursive: true })
  const initial = await sourceFingerprint(root)
  for (const name of [
    'script/audit/probe.mjs',
    'Tests/example.swift',
    'docs/result.json',
    'Configurations/release-size-budget.json',
  ])
    await writeFile(path.join(root, name), 'evidence')
  assert.equal(await sourceFingerprint(root), initial)
  await writeFile(path.join(root, 'script/release/publish_release.mjs'), 'publication')
  assert.notEqual(await sourceFingerprint(root), initial)
})
