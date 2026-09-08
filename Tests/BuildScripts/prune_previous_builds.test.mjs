import assert from 'node:assert/strict'
import { access, mkdir, mkdtemp, readdir, rm, utimes, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  applyRetentionPlan,
  createRetentionPlan,
} from '../../script/release/prune_previous_builds.mjs'

const generationIds = [
  '00000000-0000-4000-8000-000000000001',
  '00000000-0000-4000-8000-000000000002',
  '00000000-0000-4000-8000-000000000003',
  '00000000-0000-4000-8000-000000000004',
  '00000000-0000-4000-8000-000000000005',
]

async function makeFixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor retention tests '))
  const directory = path.join(root, '.cache', 'previous-builds')
  await mkdir(directory, { recursive: true })
  t.after(() => rm(root, { recursive: true, force: true }))
  return directory
}

async function addCompleteGeneration(
  directory,
  generationId,
  modifiedAt,
  prefix = 'MyEditor',
  includeReleaseMetadata = false,
) {
  const appName = `${prefix}-${generationId}.app.backup`
  const zipName = `${prefix}-${generationId}.zip`
  const dsymName = `${prefix}-${generationId}.dSYM.zip`
  const manifestName = `${prefix}-${generationId}.release-manifest.json`
  const appPath = path.join(directory, appName)
  const zipPath = path.join(directory, zipName)

  await mkdir(appPath)
  await writeFile(zipPath, 'test archive')
  await utimes(appPath, modifiedAt, modifiedAt)
  await utimes(zipPath, modifiedAt, modifiedAt)
  if (includeReleaseMetadata) {
    await writeFile(path.join(directory, dsymName), 'debug symbols')
    await writeFile(path.join(directory, manifestName), '{}')
    await utimes(path.join(directory, dsymName), modifiedAt, modifiedAt)
    await utimes(path.join(directory, manifestName), modifiedAt, modifiedAt)
  }
  return {
    appName,
    zipName,
    dsymName: includeReleaseMetadata ? dsymName : null,
    manifestName: includeReleaseMetadata ? manifestName : null,
  }
}

test('keeps the newest three complete generations and removes stale artifacts', async (t) => {
  const directory = await makeFixture(t)
  const generations = []

  for (let index = 0; index < generationIds.length; index += 1) {
    generations.push(
      await addCompleteGeneration(
        directory,
        generationIds[index],
        new Date(`2026-09-0${index + 1}T12:00:00Z`),
        index === 4 ? 'MyEditor Copy With Spaces' : 'MyEditor',
        true,
      ),
    )
  }

  const incompleteName = `MyEditor-incomplete-${generationIds[0].replace(/1$/, 'A')}.app.backup`
  await mkdir(path.join(directory, incompleteName))
  await writeFile(path.join(directory, 'MyEditor-build7-pre-resign.zip'), 'legacy')
  await writeFile(path.join(directory, 'notes with spaces.txt'), 'keep me')

  const beforePreview = await readdir(directory)
  const plan = await createRetentionPlan(directory, 3)
  assert.deepEqual(plan.keptGenerationIds, generationIds.slice(2).reverse())
  assert.equal(plan.removals.length, 10)
  assert.deepEqual(await readdir(directory), beforePreview)

  await applyRetentionPlan(plan)
  const remaining = new Set(await readdir(directory))

  for (const generation of generations.slice(2)) {
    assert(remaining.has(generation.appName))
    assert(remaining.has(generation.zipName))
    assert(remaining.has(generation.dsymName))
    assert(remaining.has(generation.manifestName))
  }
  for (const generation of generations.slice(0, 2)) {
    assert(!remaining.has(generation.appName))
    assert(!remaining.has(generation.zipName))
    assert(!remaining.has(generation.dsymName))
    assert(!remaining.has(generation.manifestName))
  }
  assert(!remaining.has(incompleteName))
  assert(!remaining.has('MyEditor-build7-pre-resign.zip'))
  assert(remaining.has('notes with spaces.txt'))
})

test('keeps all complete generations when fewer than the limit exist', async (t) => {
  const directory = await makeFixture(t)
  const first = await addCompleteGeneration(
    directory,
    generationIds[0],
    new Date('2026-09-01T12:00:00Z'),
  )
  const second = await addCompleteGeneration(
    directory,
    generationIds[1],
    new Date('2026-09-02T12:00:00Z'),
  )
  const incompleteName = `MyEditor-${generationIds[2]}.app.backup`
  await mkdir(path.join(directory, incompleteName))

  const plan = await createRetentionPlan(directory, 3)
  assert.deepEqual(plan.keptGenerationIds, generationIds.slice(0, 2).reverse())
  assert.deepEqual(
    plan.removals.map((artifact) => artifact.name),
    [incompleteName],
  )

  await applyRetentionPlan(plan)
  const remaining = new Set(await readdir(directory))
  for (const name of [first.appName, first.zipName, second.appName, second.zipName]) {
    assert(remaining.has(name))
  }
})

test('does not remove anything when no complete generation exists', async (t) => {
  const directory = await makeFixture(t)
  const incompleteName = `MyEditor-${generationIds[0]}.app.backup`
  await mkdir(path.join(directory, incompleteName))
  await writeFile(path.join(directory, 'legacy.zip'), 'legacy')

  const plan = await createRetentionPlan(directory, 3)
  assert.equal(plan.skippedReason, 'no complete App/ZIP backup generation was found')
  assert.deepEqual(plan.removals, [])

  await applyRetentionPlan(plan)
  await access(path.join(directory, incompleteName))
  await access(path.join(directory, 'legacy.zip'))
})

test('rejects directories outside .cache/previous-builds', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor unsafe retention test '))
  t.after(() => rm(root, { recursive: true, force: true }))

  await assert.rejects(
    createRetentionPlan(root, 3),
    /Refusing to prune outside a \.cache\/previous-builds directory/,
  )
})
