import { readFile, readdir, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'

const lock = JSON.parse(await readFile('package-lock.json', 'utf8'))
const supplementalNotices = await readFile('../THIRD_PARTY_NOTICES.md', 'utf8')
const sections = [
  'MyEditor includes the following open-source software.\nCopyright and license notices are reproduced from the installed packages.\n',
]
for (const [path, entry] of Object.entries(lock.packages)) {
  if (!path || entry.dev) continue
  const directory = resolve(path)
  let metadata
  try {
    metadata = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'))
  } catch {
    continue
  } // Optional packages for other platforms are not shipped.
  const files = (await readdir(directory)).filter((name) =>
    /^(licen[sc]e|copying|notice)(?:$|[.-])/i.test(name),
  )
  const legacyLicenses = Array.isArray(metadata.licenses)
    ? metadata.licenses
        .map((license) => license.type)
        .filter(Boolean)
        .join(' OR ')
    : ''
  const notices = []
  for (const file of files) {
    try {
      notices.push(await readFile(join(directory, file), 'utf8'))
    } catch {
      /* Not a text file. */
    }
  }
  sections.push(
    `${metadata.name} ${metadata.version}\nLicense: ${metadata.license || legacyLicenses || entry.license || 'See package notice'}\n${notices.join('\n')}`,
  )
}
sections.push(supplementalNotices)
await writeFile('dist/THIRD-PARTY-NOTICES.txt', sections.join('\n\n' + '='.repeat(72) + '\n\n'))
console.log(`Included ${sections.length - 2} dependency license notices.`)
