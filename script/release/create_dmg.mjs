import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import {
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  readlink,
  rm,
  symlink,
  writeFile,
} from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const execute = promisify(execFile)
const run = (command, args) => execute(command, args, { maxBuffer: 8 * 1024 * 1024 })

async function inventory(root, relative = '') {
  const result = []
  for (const name of (await readdir(path.join(root, relative))).sort()) {
    const item = path.join(relative, name)
    const full = path.join(root, item)
    const info = await lstat(full)
    if (info.isSymbolicLink()) result.push([item, 'link', await readlink(full)])
    else if (info.isDirectory()) {
      result.push([item, 'directory'])
      result.push(...(await inventory(root, item)))
    } else if (info.isFile()) {
      result.push([
        item,
        'file',
        info.mode & 0o777,
        createHash('sha256')
          .update(await readFile(full))
          .digest('hex'),
      ])
    } else throw new Error(`Unsupported bundle entry: ${item}`)
  }
  return result
}

export async function verifyDiskImage(bundle, image, executeCommand = run) {
  await executeCommand('/usr/bin/hdiutil', ['verify', image])
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'MyEditor-dmg-verify-'))
  const mount = path.join(temporary, 'volume')
  await mkdir(mount)
  let attached = false
  try {
    await executeCommand('/usr/bin/hdiutil', [
      'attach',
      image,
      '-readonly',
      '-nobrowse',
      '-mountpoint',
      mount,
    ])
    attached = true
    if ((await readlink(path.join(mount, 'Applications'))) !== '/Applications')
      throw new Error('DMG Applications shortcut has the wrong destination')
    const extracted = path.join(mount, 'MyEditor.app')
    const info = await lstat(extracted)
    if (!info.isDirectory() || info.isSymbolicLink())
      throw new Error('DMG has no ordinary MyEditor.app bundle')
    await executeCommand('/usr/bin/codesign', ['--verify', '--strict', extracted])
    if (JSON.stringify(await inventory(bundle)) !== JSON.stringify(await inventory(extracted)))
      throw new Error('DMG application differs from the staged bundle')
    return {
      imageChecksumPassed: true,
      applicationMatchesBundle: true,
      applicationSignaturePassed: true,
      applicationsShortcutPassed: true,
    }
  } finally {
    // Never recursively delete a directory while an image is still mounted.
    // If detach fails, preserve it and stop publication so it can be inspected.
    if (attached) {
      try {
        await executeCommand('/usr/bin/hdiutil', ['detach', mount])
      } catch (cause) {
        const error = new Error(`Could not detach DMG at ${mount}; temporary files retained`, {
          cause,
        })
        error.code = 'DMG_DETACH_FAILED'
        throw error
      }
    }
    await rm(temporary, { recursive: true, force: true })
  }
}

export async function createDiskImage(bundlePath, outputPath) {
  const bundle = path.resolve(bundlePath)
  const output = path.resolve(outputPath)
  const info = await lstat(bundle)
  if (!info.isDirectory() || info.isSymbolicLink() || path.basename(bundle) !== 'MyEditor.app')
    throw new Error('Expected an ordinary MyEditor.app directory')
  if (path.extname(output) !== '.dmg') throw new Error('Output must end in .dmg')
  if (output.startsWith(bundle + path.sep)) throw new Error('DMG output cannot be inside the app')
  await run('/usr/bin/codesign', ['--verify', '--strict', bundle])
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'MyEditor-dmg-build-'))
  let retainTemporary = false
  try {
    const source = path.join(temporary, 'source')
    await mkdir(source)
    await run('/usr/bin/ditto', [
      '--norsrc',
      '--noextattr',
      '--noacl',
      bundle,
      path.join(source, 'MyEditor.app'),
    ])
    await symlink('/Applications', path.join(source, 'Applications'))
    await writeFile(
      path.join(source, '安装说明.txt'),
      'MyEditor\n\n将 MyEditor.app 拖入 Applications 文件夹，然后推出此磁盘映像。\n从“应用程序”文件夹启动 MyEditor。\n\n需要 Apple Silicon Mac 和 macOS 26 或更新版本。\n\nDrag MyEditor.app into Applications, then eject this disk image.\nLaunch MyEditor from your Applications folder.\nRequires Apple Silicon and macOS 26 or later.\n',
    )
    const image = path.join(temporary, 'MyEditor.dmg')
    await run('/usr/bin/hdiutil', [
      'create',
      '-volname',
      'MyEditor',
      '-srcfolder',
      source,
      '-fs',
      'HFS+',
      '-format',
      'UDZO',
      image,
    ])
    const verification = await verifyDiskImage(bundle, image)
    await mkdir(path.dirname(output), { recursive: true })
    // An existing release is never overwritten by a standalone packaging run.
    await copyFile(image, output, constants.COPYFILE_EXCL)
    return verification
  } catch (error) {
    retainTemporary = error.code === 'DMG_DETACH_FAILED'
    throw error
  } finally {
    if (!retainTemporary) await rm(temporary, { recursive: true, force: true })
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [bundle, output, ...extra] = process.argv.slice(2)
  if (!bundle || !output || extra.length) {
    console.error('Usage: node script/release/create_dmg.mjs MyEditor.app OUTPUT.dmg')
    process.exitCode = 2
  } else {
    createDiskImage(bundle, output)
      .then(() => console.log(`Verified DMG: ${output}`))
      .catch((error) => {
        console.error(`DMG packaging failed: ${error.message}`)
        process.exitCode = 1
      })
  }
}
