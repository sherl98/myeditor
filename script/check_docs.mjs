import { readFile, readdir, access } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const root = fileURLToPath(new URL('../', import.meta.url))
const files = [path.join(root, 'README.md')]
async function collect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === 'archive') continue
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) await collect(full)
    else if (entry.name.endsWith('.md')) files.push(full)
  }
}
await collect(path.join(root, 'docs'))
const errors = []
for (const file of files) {
  const text = await readFile(file, 'utf8')
  for (const match of text.matchAll(/\]\(([^)]+)\)/g)) {
    let target = match[1].replace(/^<|>$/g, '')
    if (/^(https?:|#|mailto:)/.test(target)) continue
    target = decodeURIComponent(target.split('#')[0]).replace(/:\d+$/, '')
    if (path.isAbsolute(target)) {
      errors.push(`${path.relative(root, file)}: absolute link ${target}`)
      continue
    }
    try {
      await access(path.resolve(path.dirname(file), target))
    } catch {
      errors.push(`${path.relative(root, file)}: missing ${target}`)
    }
  }
}
if (errors.length) throw new Error(errors.join('\n'))
console.log(`PASS: relative links in ${files.length} current documents`)
