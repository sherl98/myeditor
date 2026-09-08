import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, rm, rename, readdir } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { publishRelease, releaseFiles } from '../../script/release/publish_release.mjs'

async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor publication '))
  t.after(() => rm(root, { recursive: true, force: true }))
  const options = {
    staging: path.join(root, 'staged'),
    destination: path.join(root, 'dist'),
    backups: path.join(root, 'backups'),
  }
  for (const dir of [options.staging, options.destination]) {
    await mkdir(dir)
    for (const name of releaseFiles)
      await writeFile(path.join(dir, name), dir === options.staging ? 'new' : 'old')
  }
  return options
}

test('publishes all four artifacts and retains the previous generation', async (t) => {
  const options = await fixture(t)
  await publishRelease(options)
  for (const name of releaseFiles)
    assert.equal(await readFile(path.join(options.destination, name), 'utf8'), 'new')
  assert.equal((await readdir(options.backups)).length, 4)
})
test('failed promotion restores the entire previous generation', async (t) => {
  const options = await fixture(t)
  await assert.rejects(
    publishRelease(options, async (from, to) => {
      if (from === options.staging) throw new Error('Injected promotion failure')
      await rename(from, to)
    }),
    /Injected/,
  )
  for (const name of releaseFiles)
    assert.equal(await readFile(path.join(options.destination, name), 'utf8'), 'old')
})
test('incomplete staging never touches the current release', async (t) => {
  const options = await fixture(t)
  await rm(path.join(options.staging, 'MyEditor.dSYM.zip'))
  await assert.rejects(publishRelease(options), /Incomplete/)
  assert.equal(await readFile(path.join(options.destination, 'MyEditor.zip'), 'utf8'), 'old')
})

test('Finder metadata in the prior release does not leave a partial backup', async (t) => {
  const options = await fixture(t)
  await writeFile(path.join(options.destination, '.DS_Store'), 'Finder metadata')
  await publishRelease(options)
  assert.equal((await readdir(options.backups)).length, 4)
})
