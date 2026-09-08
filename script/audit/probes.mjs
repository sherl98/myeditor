// Read-only audit probes. Writes only this audit's evidence file and temporary extracts.
import { readFile, writeFile, mkdtemp, readdir, stat, mkdir } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import os from 'node:os'
import { performance } from 'node:perf_hooks'
import { parseMarkdown, extractOutline } from '../../EditorWeb/src/markdown/markdown.js'
import {
  logicalFileBytes,
  sourceFingerprint,
  countSymbols,
  parseLinkeditBytes,
} from '../release/generate_release_manifest.mjs'

const root = fileURLToPath(new URL('../../', import.meta.url))
const run = (cmd, args) =>
  execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
const hash = async (file) =>
  createHash('sha256')
    .update(await readFile(file))
    .digest('hex')
const bundle = path.join(root, 'dist/MyEditor.app')
const binary = path.join(bundle, 'Contents/MacOS/MyEditor')
const manifest = JSON.parse(
  await readFile(path.join(root, 'dist/MyEditor.release-manifest.json'), 'utf8'),
)
const extracted = await mkdtemp(path.join(os.tmpdir(), 'myeditor-review-20260905-'))
run('/usr/bin/ditto', ['-x', '-k', path.join(root, 'dist/MyEditor.zip'), extracted])
run('/usr/bin/ditto', ['-x', '-k', path.join(root, 'dist/MyEditor.dSYM.zip'), extracted])
run('/usr/bin/codesign', ['--verify', '--strict', path.join(extracted, 'MyEditor.app')])
const currentFingerprint = await sourceFingerprint(root)
const archiveHash = await hash(path.join(root, 'dist/MyEditor.zip'))
const executableHash = await hash(binary)
const dsymHash = await hash(path.join(root, 'dist/MyEditor.dSYM.zip'))
const fileHashes = async (directory) => {
  const result = {}
  async function visit(current) {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name)
      if (entry.isDirectory()) await visit(full)
      else if (entry.isFile()) result[path.relative(directory, full)] = await hash(full)
    }
  }
  await visit(directory)
  return Object.fromEntries(Object.entries(result).sort())
}
const evidence = {
  capturedAt: new Date().toISOString(),
  environment: {
    node: process.version,
    macOS: run('/usr/bin/sw_vers', ['-productVersion']),
    arch: os.arch(),
  },
  buildIdentifier: manifest.product.buildIdentifier,
  currentFingerprint,
  sourceMatchesRelease: currentFingerprint === manifest.source.embeddedFingerprint,
  package: {
    appLogicalBytes: await logicalFileBytes(bundle),
    archiveBytes: (await stat(path.join(root, 'dist/MyEditor.zip'))).size,
    editorHTMLBytes: (await stat(path.join(bundle, 'Contents/Resources/EditorWeb/index.html')))
      .size,
    executableBytes: (await stat(binary)).size,
    linkeditBytes: parseLinkeditBytes(run('/usr/bin/size', ['-m', binary])),
    nonExternalSymbols: countSymbols(run('/usr/bin/nm', ['-a', '-m', binary])).nonExternal,
    previousBuildsLogicalBytes: await logicalFileBytes(path.join(root, '.cache/previous-builds')),
    archiveHash,
    executableHash,
    dsymHash,
    archiveMatchesManifest: archiveHash === manifest.artifacts.archiveSHA256,
    executableMatchesManifest: executableHash === manifest.artifacts.executableSHA256,
    dsymMatchesManifest: dsymHash === manifest.artifacts.dSYMArchiveSHA256,
    extractedSignaturePassed: true,
    extractedFilesMatchBundle:
      JSON.stringify(await fileHashes(bundle)) ===
      JSON.stringify(await fileHashes(path.join(extracted, 'MyEditor.app'))),
    binaryUUID: run('/usr/bin/dwarfdump', ['--uuid', binary]).split(' ')[1],
    dsymUUID: run('/usr/bin/dwarfdump', ['--uuid', path.join(extracted, 'MyEditor.dSYM')]).split(
      ' ',
    )[1],
  },
}
const commonmarkExample204 = '[foo]\n\n[foo]: first\n[foo]: second\n'
const parsed = parseMarkdown(commonmarkExample204)
const actualURL = parsed.children[0].children[0].url
evidence.duplicateReferences = {
  input: commonmarkExample204,
  expectedURL: 'first',
  actualURL,
  conformsToCommonMark: actualURL === 'first',
}
// Tests the actual navigation function against the DOM contract of its fallback
// wrapper (a div, not a textarea). This is not a real WKWebView UI test.
const { runtime } = await import('../../EditorWeb/src/bridge/engineBridge.js')
globalThis.window = { addEventListener() {} }
globalThis.document = { querySelector: () => ({ tagName: 'DIV' }) }
const { navigate } = await import('../../EditorWeb/src/editor/scrolling.js')
Object.assign(runtime, {
  fallback: true,
  outline: [{ id: 'heading-probe', offset: 0 }],
  source: '# Probe',
})
const { registerSourceView } = await import('../../EditorWeb/src/search/searchPresentation.js')
let navigatedOffset = null
const unregister = registerSourceView('fallback', {
  highlight() {},
  navigate(offset) {
    navigatedOffset = offset
  },
})
try {
  navigate('heading-probe')
  evidence.fallbackNavigation = {
    threw: false,
    navigatedOffset,
    adapterUsed: navigatedOffset === 0,
  }
} catch (error) {
  evidence.fallbackNavigation = {
    threw: true,
    message: error.message,
    method: 'actual navigate function with a div-shaped DOM test double',
  }
}
unregister()
// Isolated Node/V8 timings, NOT WKWebView keystroke or end-to-end latency.
const { largeManuscript } = await import('../../Fixtures/large-manuscript.mjs')
const novel = largeManuscript()
evidence.fixtureSHA256 = createHash('sha256').update(novel).digest('hex')
evidence.outlineMicrobenchmark = []
for (const [label, source] of [
  ['novel', novel],
  ['novel-3x', novel.repeat(3)],
]) {
  let previous = extractOutline(source)
  const samples = []
  for (let i = 0; i < 5; i++) {
    const started = performance.now()
    previous = extractOutline(source + '\n', previous)
    samples.push(performance.now() - started)
  }
  const sorted = [...samples].sort((a, b) => a - b)
  evidence.outlineMicrobenchmark.push({
    label,
    utf8Bytes: Buffer.byteLength(source),
    headings: previous.length,
    samplesMs: samples,
    medianMs: sorted[2],
    maxMs: sorted[4],
  })
}
const referenceRoot = process.env.MARKEDIT_REFERENCE_ROOT
try {
  const official = JSON.parse(await readFile(path.join(referenceRoot, 'release.json'), 'utf8'))
  const referenceZIP = path.join(referenceRoot, 'UpdateArchive-arm64.zip')
  const asset = official.assets.find((a) => a.name === 'UpdateArchive-arm64.zip')
  evidence.markEdit = {
    release: official.tag_name,
    publishedAt: official.published_at,
    apiZIPBytes: asset.size,
    downloadedZIPBytes: (await stat(referenceZIP)).size,
    zipHashMatchesOfficialDigest: 'sha256:' + (await hash(referenceZIP)) === asset.digest,
    appLogicalBytes: await logicalFileBytes(path.join(referenceRoot, 'release/MarkEdit.app')),
    zipReductionPercent: (1 - evidence.package.archiveBytes / asset.size) * 100,
  }
} catch (error) {
  evidence.markEdit = { unavailable: error.message }
}
const output = path.join(
  root,
  '.cache/validation',
  manifest.product.buildIdentifier,
  'audit-' + Date.now(),
)
await mkdir(output, { recursive: true })
await writeFile(path.join(output, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n')
console.log(JSON.stringify(evidence, null, 2))
