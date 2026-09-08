import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
const [plist, directory] = process.argv.slice(2)
const value = (key) =>
  execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], {
    encoding: 'utf8',
  }).trim()
const hash = (data) => createHash('sha256').update(data).digest('hex')
await writeFile(
  path.join(directory, 'context.json'),
  JSON.stringify(
    {
      schemaVersion: 1,
      buildIdentifier: value('MyEditorBuildIdentifier'),
      sourceFingerprint: value('MyEditorSourceFingerprint'),
      fixtureSHA256: hash(await readFile(path.join(directory, 'large-manuscript.md'))),
      timestamp: new Date().toISOString(),
      environment: {
        macOS: execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim(),
        arch: os.arch(),
        node: process.version,
      },
      metricsScope:
        'Runtime memory measurements cover the native process only; WebKit child processes are not included.',
    },
    null,
    2,
  ) + '\n',
)
