import { access, mkdir, readdir, rename, rm, stat } from 'node:fs/promises'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'

export const releaseFiles = [
  'MyEditor.app',
  'MyEditor.zip',
  'MyEditor.dmg',
  'MyEditor.dSYM.zip',
  'MyEditor.release-manifest.json',
]

// All validation occurs before this function. Swap the complete generation;
// restore the old directory if promotion fails. Never prune on failure.
export async function publishRelease(
  { staging, destination, backups, debug = false },
  move = rename,
) {
  const expected = debug ? ['MyEditor.app'] : releaseFiles
  const actual = (await readdir(staging)).sort()
  if (JSON.stringify(actual) !== JSON.stringify([...expected].sort()))
    throw new Error('Incomplete or unexpected staged generation')
  await mkdir(path.dirname(destination), { recursive: true })
  await mkdir(backups, { recursive: true })
  const id = randomUUID()
  const rollback = path.join(backups, `generation-${id}.backup`)
  let hadPrevious = false
  try {
    await access(destination)
    hadPrevious = true
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  if (hadPrevious) await move(destination, rollback)
  try {
    await move(staging, destination)
  } catch (error) {
    if (hadPrevious) await rename(rollback, destination)
    throw error
  }
  // Backup organization is best effort after successful promotion. Failure here
  // must not report the already-published generation as a failed promotion.
  if (hadPrevious && !debug) {
    try {
      for (const name of await readdir(rollback)) {
        if (name === '.DS_Store') {
          await rm(path.join(rollback, name))
          continue
        }
        const extension = name.startsWith('MyEditor.') ? name.slice('MyEditor.'.length) : null
        if (!extension) continue
        const suffix = extension === 'app' ? 'app.backup' : extension
        await rename(path.join(rollback, name), path.join(backups, `MyEditor-${id}.${suffix}`))
      }
      const { rmdir } = await import('node:fs/promises')
      await rmdir(rollback)
    } catch (error) {
      console.warn(`Previous generation remains recoverable at ${rollback}: ${error.message}`)
    }
  }
  if (debug) {
    // Retain one prior generated debug app; release backups use their own policy.
    const generations = []
    for (const entry of await readdir(backups, { withFileTypes: true })) {
      if (!entry.isDirectory() || !/^generation-[a-f0-9-]+\.backup$/.test(entry.name)) continue
      const full = path.join(backups, entry.name)
      generations.push({ full, time: (await stat(full)).mtimeMs })
    }
    generations.sort((a, b) => b.time - a.time)
    for (const entry of generations.slice(1)) await rm(entry.full, { recursive: true })
  }
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [staging, destination, backups, mode] = process.argv.slice(2)
  if (!staging || !destination || !backups)
    throw new Error('Usage: publish_release.mjs STAGING DESTINATION BACKUPS [debug]')
  await publishRelease({ staging, destination, backups, debug: mode === 'debug' })
}
