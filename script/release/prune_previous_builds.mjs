#!/usr/bin/env node

import { lstat, readdir, rm } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const generationPattern =
  /([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.(?:app\.backup|dSYM\.zip|release-manifest\.json|dmg|zip)$/i

function isBackupArtifact(entry) {
  return (
    (entry.isDirectory() && entry.name.endsWith('.app.backup')) ||
    (entry.isFile() &&
      (entry.name.endsWith('.zip') ||
        entry.name.endsWith('.dmg') ||
        entry.name.endsWith('.release-manifest.json')))
  )
}

function artifactType(name) {
  if (name.endsWith('.app.backup')) return 'app'
  if (name.endsWith('.dmg')) return 'dmg'
  if (name.endsWith('.dSYM.zip')) return 'dsym'
  if (name.endsWith('.release-manifest.json')) return 'manifest'
  return 'zip'
}

function assertSafeBackupDirectory(directory) {
  if (
    path.basename(directory) !== 'previous-builds' ||
    path.basename(path.dirname(directory)) !== '.cache'
  ) {
    throw new Error(`Refusing to prune outside a .cache/previous-builds directory: ${directory}`)
  }
}

export async function createRetentionPlan(directory, keepCount = 3) {
  if (!Number.isSafeInteger(keepCount) || keepCount < 1) {
    throw new Error(`keepCount must be a positive integer, received: ${keepCount}`)
  }

  const absoluteDirectory = path.resolve(directory)
  assertSafeBackupDirectory(absoluteDirectory)

  const directoryStat = await lstat(absoluteDirectory)
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    throw new Error(`Backup path is not a real directory: ${absoluteDirectory}`)
  }

  const directoryEntries = await readdir(absoluteDirectory, { withFileTypes: true })
  const artifacts = []

  for (const entry of directoryEntries) {
    if (!isBackupArtifact(entry)) continue

    const artifactPath = path.join(absoluteDirectory, entry.name)
    const artifactStat = await lstat(artifactPath)
    const match = entry.name.match(generationPattern)

    artifacts.push({
      name: entry.name,
      path: artifactPath,
      type: artifactType(entry.name),
      generationId: match ? match[1].toUpperCase() : null,
      modifiedAt: artifactStat.mtimeMs,
    })
  }

  const groups = new Map()
  for (const artifact of artifacts) {
    if (!artifact.generationId) continue

    const group = groups.get(artifact.generationId) ?? {
      generationId: artifact.generationId,
      artifacts: [],
      modifiedAt: 0,
      hasApp: false,
      hasZip: false,
    }

    group.artifacts.push(artifact)
    group.modifiedAt = Math.max(group.modifiedAt, artifact.modifiedAt)
    group.hasApp ||= artifact.type === 'app'
    group.hasZip ||= artifact.type === 'zip'
    groups.set(artifact.generationId, group)
  }

  const completeGroups = [...groups.values()]
    .filter((group) => group.hasApp && group.hasZip)
    .sort(
      (left, right) =>
        right.modifiedAt - left.modifiedAt || left.generationId.localeCompare(right.generationId),
    )

  // A successful normal build always contributes a complete App/ZIP pair.
  // If none exists, leave everything untouched instead of guessing what is safe.
  if (completeGroups.length === 0) {
    return {
      directory: absoluteDirectory,
      keepCount,
      keptGenerationIds: [],
      removals: [],
      skippedReason: 'no complete App/ZIP backup generation was found',
    }
  }

  const keptGenerationIds = completeGroups.slice(0, keepCount).map((group) => group.generationId)
  const keptGenerationSet = new Set(keptGenerationIds)
  const removals = artifacts.filter(
    (artifact) => !artifact.generationId || !keptGenerationSet.has(artifact.generationId),
  )

  return {
    directory: absoluteDirectory,
    keepCount,
    keptGenerationIds,
    removals,
    skippedReason: null,
  }
}

export async function applyRetentionPlan(plan) {
  assertSafeBackupDirectory(plan.directory)

  const directoryStat = await lstat(plan.directory)
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    throw new Error(`Backup path changed before pruning: ${plan.directory}`)
  }

  for (const artifact of plan.removals) {
    if (path.dirname(artifact.path) !== plan.directory) {
      throw new Error(`Refusing to remove a non-child path: ${artifact.path}`)
    }

    const artifactStat = await lstat(artifact.path)
    const expectedType = artifact.type === 'app' ? 'directory' : 'file'
    const typeMatches = artifact.type === 'app' ? artifactStat.isDirectory() : artifactStat.isFile()
    if (!typeMatches || artifactStat.isSymbolicLink()) {
      throw new Error(`Backup artifact is no longer a ${expectedType}: ${artifact.path}`)
    }

    await rm(artifact.path, { recursive: artifact.type === 'app', force: false })
  }

  return plan.removals.length
}

function parseArguments(argumentsList) {
  const options = { directory: null, keepCount: 3, apply: false }

  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index]
    switch (argument) {
      case '--directory':
        options.directory = argumentsList[++index]
        break
      case '--keep':
        options.keepCount = Number(argumentsList[++index])
        break
      case '--apply':
        options.apply = true
        break
      default:
        throw new Error(`Unknown argument: ${argument}`)
    }
  }

  if (!options.directory) {
    throw new Error('Missing required --directory argument')
  }
  return options
}

async function main() {
  const options = parseArguments(process.argv.slice(2))
  const plan = await createRetentionPlan(options.directory, options.keepCount)

  if (plan.skippedReason) {
    console.log(`Backup retention skipped: ${plan.skippedReason}.`)
    return
  }

  if (options.apply) {
    const removedCount = await applyRetentionPlan(plan)
    console.log(
      `Backup retention kept ${plan.keptGenerationIds.length} complete generations and removed ${removedCount} stale artifacts.`,
    )
  } else {
    console.log(
      `Backup retention preview: keep ${plan.keptGenerationIds.length} complete generations and remove ${plan.removals.length} stale artifacts.`,
    )
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`Backup retention failed: ${error.message}`)
    process.exitCode = 1
  })
}
