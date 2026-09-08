#!/usr/bin/env node

import { execFile as execFileCallback } from 'node:child_process'
import { createHash } from 'node:crypto'
import { lstat, readFile, readdir, writeFile, mkdtemp, rm } from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

import { verifyDiskImage } from './create_dmg.mjs'

const execFile = promisify(execFileCallback)

async function pathExists(targetPath) {
  try {
    await lstat(targetPath)
    return true
  } catch (error) {
    if (error?.code === 'ENOENT') return false
    throw error
  }
}

export async function logicalFileBytes(targetPath) {
  if (!(await pathExists(targetPath))) return 0

  const targetStat = await lstat(targetPath)
  if (targetStat.isSymbolicLink()) return 0
  if (targetStat.isFile()) return targetStat.size
  if (!targetStat.isDirectory()) return 0

  let total = 0
  const entries = await readdir(targetPath, { withFileTypes: true })
  for (const entry of entries) {
    total += await logicalFileBytes(path.join(targetPath, entry.name))
  }
  return total
}

export function parseLinkeditBytes(sizeOutput) {
  const match = sizeOutput.match(/^Segment __LINKEDIT:\s+(\d+)$/m)
  if (!match) throw new Error('Mach-O size output has no __LINKEDIT segment')
  return Number(match[1])
}

export function countSymbols(nmOutput) {
  const lines = nmOutput.split('\n').filter((line) => line.length > 0)
  return {
    total: lines.length,
    nonExternal: lines.filter((line) => line.includes('(non-external)')).length,
  }
}

export function evaluateBudgets(metrics, limits) {
  const checks = {}
  let passed = true

  for (const [metric, limit] of Object.entries(limits)) {
    if (!Number.isSafeInteger(limit) || limit < 0) {
      throw new Error(`Budget for ${metric} must be a non-negative integer`)
    }
    if (!Number.isSafeInteger(metrics[metric]) || metrics[metric] < 0) {
      throw new Error(`Metric ${metric} is missing or is not a non-negative integer`)
    }

    const actual = metrics[metric]
    const withinBudget = actual <= limit
    checks[metric] = { actual, limit, passed: withinBudget }
    passed &&= withinBudget
  }

  return { passed, checks }
}

async function run(command, argumentsList, options = {}) {
  const result = await execFile(command, argumentsList, {
    cwd: options.cwd,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
  return result.stdout.trim()
}

async function runOptional(command, argumentsList, options = {}) {
  try {
    return await run(command, argumentsList, options)
  } catch {
    return null
  }
}

async function plistValue(infoPlist, key) {
  return run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', infoPlist])
}

async function sha256(targetPath) {
  const contents = await readFile(targetPath)
  return createHash('sha256').update(contents).digest('hex')
}

async function collectOrdinaryFiles(targetPath, projectRoot, files) {
  if (!(await pathExists(targetPath))) return
  const targetStat = await lstat(targetPath)
  if (targetStat.isSymbolicLink()) return
  if (targetStat.isFile()) {
    files.push(path.relative(projectRoot, targetPath))
    return
  }
  if (!targetStat.isDirectory()) return

  const entries = await readdir(targetPath, { withFileTypes: true })
  for (const entry of entries) {
    await collectOrdinaryFiles(path.join(targetPath, entry.name), projectRoot, files)
  }
}

export async function sourceFingerprint(projectRootPath) {
  const projectRoot = path.resolve(projectRootPath)
  const buildInputs = [
    'Package.swift',
    'THIRD_PARTY_NOTICES.md',
    'Sources',
    'Resources',
    'EditorWeb/package.json',
    'EditorWeb/package-lock.json',
    'EditorWeb/index.html',
    'EditorWeb/vite.config.js',
    'EditorWeb/src',
    'EditorWeb/scripts',
    'script/build_and_run.sh',
    'script/swiftpm.sh',
    'script/MakeIcon.swift',
    'script/release',
  ]
  const files = []
  for (const input of buildInputs) {
    await collectOrdinaryFiles(path.join(projectRoot, input), projectRoot, files)
  }

  const digest = createHash('sha256')
  for (const relativePath of files.sort()) {
    digest.update(relativePath)
    digest.update('\0')
    digest.update(await readFile(path.join(projectRoot, relativePath)))
    digest.update('\0')
  }
  return digest.digest('hex')
}

function parseArguments(argumentsList) {
  const options = {
    bundle: null,
    archive: null,
    dmg: null,
    dsymArchive: null,
    previousBuilds: null,
    budget: null,
    output: null,
    projectRoot: null,
  }

  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index]
    switch (argument) {
      case '--bundle':
        options.bundle = argumentsList[++index]
        break
      case '--archive':
        options.archive = argumentsList[++index]
        break
      case '--dmg':
        options.dmg = argumentsList[++index]
        break
      case '--dsym-archive':
        options.dsymArchive = argumentsList[++index]
        break
      case '--previous-builds':
        options.previousBuilds = argumentsList[++index]
        break
      case '--budget':
        options.budget = argumentsList[++index]
        break
      case '--output':
        options.output = argumentsList[++index]
        break
      case '--project-root':
        options.projectRoot = argumentsList[++index]
        break
      default:
        throw new Error(`Unknown argument: ${argument}`)
    }
  }

  for (const required of ['bundle', 'archive', 'dmg', 'budget', 'output', 'projectRoot']) {
    if (!options[required])
      throw new Error(
        `Missing required --${required.replaceAll(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)} argument`,
      )
  }
  return options
}

async function verifyArchives(bundle, archive, dsymArchive) {
  if (!dsymArchive) throw new Error('A release requires a dSYM archive')
  const directory = await mkdtemp(path.join(os.tmpdir(), 'MyEditor-release-verify-'))
  try {
    await run('/usr/bin/ditto', ['-x', '-k', archive, directory])
    await run('/usr/bin/ditto', ['-x', '-k', path.resolve(dsymArchive), directory])
    const extracted = path.join(directory, 'MyEditor.app')
    await run('/usr/bin/codesign', ['--verify', '--strict', extracted])
    const files = []
    const extractedFiles = []
    await collectOrdinaryFiles(bundle, bundle, files)
    await collectOrdinaryFiles(extracted, extracted, extractedFiles)
    if (JSON.stringify(files.sort()) !== JSON.stringify(extractedFiles.sort()))
      throw new Error('Archive file list differs from bundle')
    for (const file of files) {
      if ((await sha256(path.join(bundle, file))) !== (await sha256(path.join(extracted, file))))
        throw new Error(`Archive content mismatch: ${file}`)
    }
    const binaryUUID = (
      await run('/usr/bin/dwarfdump', ['--uuid', path.join(extracted, 'Contents/MacOS/MyEditor')])
    ).split(/\s+/)[1]
    const dsymUUID = (
      await run('/usr/bin/dwarfdump', ['--uuid', path.join(directory, 'MyEditor.dSYM')])
    ).split(/\s+/)[1]
    if (!binaryUUID || binaryUUID !== dsymUUID) throw new Error('Archived dSYM UUID mismatch')
    return { extractedSignaturePassed: true, extractedFilesMatchBundle: true, binaryUUID, dsymUUID }
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

async function createManifest(options) {
  const projectRoot = path.resolve(options.projectRoot)
  const bundle = path.resolve(options.bundle)
  const archive = path.resolve(options.archive)
  const executable = path.join(bundle, 'Contents', 'MacOS', 'MyEditor')
  const editorHTML = path.join(bundle, 'Contents', 'Resources', 'EditorWeb', 'index.html')
  const infoPlist = path.join(bundle, 'Contents', 'Info.plist')

  const [
    version,
    build,
    bundleIdentifier,
    buildIdentifier,
    embeddedCommit,
    embeddedDirty,
    embeddedFingerprint,
    sizeOutput,
    nmOutput,
    gitCommit,
    gitStatus,
  ] = await Promise.all([
    plistValue(infoPlist, 'CFBundleShortVersionString'),
    plistValue(infoPlist, 'CFBundleVersion'),
    plistValue(infoPlist, 'CFBundleIdentifier'),
    plistValue(infoPlist, 'MyEditorBuildIdentifier'),
    plistValue(infoPlist, 'MyEditorGitCommit'),
    plistValue(infoPlist, 'MyEditorGitDirty'),
    plistValue(infoPlist, 'MyEditorSourceFingerprint'),
    run('/usr/bin/size', ['-m', executable]),
    run('/usr/bin/nm', ['-a', '-m', executable]),
    runOptional('/usr/bin/git', ['rev-parse', 'HEAD'], { cwd: projectRoot }),
    run('/usr/bin/git', ['status', '--porcelain'], { cwd: projectRoot }),
  ])

  const symbols = countSymbols(nmOutput)
  const metrics = {
    appLogicalBytes: await logicalFileBytes(bundle),
    archiveBytes: (await lstat(archive)).size,
    dmgBytes: (await lstat(path.resolve(options.dmg))).size,
    editorHTMLBytes: (await lstat(editorHTML)).size,
    executableBytes: (await lstat(executable)).size,
    linkeditBytes: parseLinkeditBytes(sizeOutput),
    nonExternalSymbols: symbols.nonExternal,
    previousBuildsLogicalBytes: options.previousBuilds
      ? await logicalFileBytes(path.resolve(options.previousBuilds))
      : 0,
  }

  const budgetDocument = JSON.parse(await readFile(path.resolve(options.budget), 'utf8'))
  const budget = evaluateBudgets(metrics, budgetDocument.limits)
  const sourceCommit = gitCommit ?? 'uncommitted'
  const sourceDirty = gitStatus.length > 0
  const inspectedFingerprint = await sourceFingerprint(projectRoot)

  const verification = await verifyArchives(bundle, archive, options.dsymArchive)
  const manifest = {
    schemaVersion: 3,
    generatedAt: new Date().toISOString(),
    product: {
      name: 'MyEditor',
      version,
      build,
      bundleIdentifier,
      buildIdentifier,
      architecture: 'arm64',
      configuration: 'release',
    },
    source: {
      embeddedCommit,
      embeddedDirty: embeddedDirty === 'true',
      embeddedFingerprint,
      inspectedCommit: sourceCommit,
      inspectedDirty: sourceDirty,
      inspectedFingerprint,
      matchesEmbeddedState:
        embeddedCommit === sourceCommit &&
        (embeddedDirty === 'true') === sourceDirty &&
        embeddedFingerprint === inspectedFingerprint,
    },
    verification: {
      ...verification,
      dmg: await verifyDiskImage(bundle, path.resolve(options.dmg)),
    },
    distribution: { signing: 'ad-hoc', notarized: false },
    artifacts: {
      archiveSHA256: await sha256(archive),
      dmgSHA256: await sha256(path.resolve(options.dmg)),
      executableSHA256: await sha256(executable),
      dSYMArchiveSHA256:
        options.dsymArchive && (await pathExists(path.resolve(options.dsymArchive)))
          ? await sha256(path.resolve(options.dsymArchive))
          : null,
      totalSymbols: symbols.total,
    },
    metrics,
    budget: {
      name: budgetDocument.name,
      configurationSHA256: await sha256(path.resolve(options.budget)),
      passed: budget.passed,
      checks: budget.checks,
    },
  }

  await writeFile(path.resolve(options.output), `${JSON.stringify(manifest, null, 2)}\n`)
  return manifest
}

async function main() {
  if (process.argv[2] === '--source-fingerprint') {
    if (!process.argv[3]) throw new Error('Missing project root for --source-fingerprint')
    console.log(await sourceFingerprint(process.argv[3]))
    return
  }
  const options = parseArguments(process.argv.slice(2))
  const manifest = await createManifest(options)
  const result = manifest.budget.passed ? 'passed' : 'FAILED'
  console.log(
    `Release size budget ${result}: app ${manifest.metrics.appLogicalBytes} B, ZIP ${manifest.metrics.archiveBytes} B, executable ${manifest.metrics.executableBytes} B.`,
  )

  if (!manifest.source.matchesEmbeddedState) {
    throw new Error('Source state changed after the build identity was embedded')
  }
  if (!manifest.budget.passed) {
    const failures = Object.entries(manifest.budget.checks)
      .filter(([, check]) => !check.passed)
      .map(([metric, check]) => `${metric}=${check.actual} > ${check.limit}`)
      .join(', ')
    throw new Error(`Release size budget exceeded: ${failures}`)
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`Release manifest failed: ${error.message}`)
    process.exitCode = 1
  })
}
