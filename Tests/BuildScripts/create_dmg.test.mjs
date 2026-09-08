import assert from 'node:assert/strict'
import { access, chmod, cp, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { verifyDiskImage } from '../../script/release/create_dmg.mjs'

async function fixture(
  t,
  { corrupt = false, wrongShortcut = false, detachFails = false, invalidSignature = false } = {},
) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'MyEditor disk image tests '))
  const bundle = path.join(root, 'MyEditor.app')
  await mkdir(path.join(bundle, 'Contents', 'MacOS'), { recursive: true })
  const executable = path.join(bundle, 'Contents', 'MacOS', 'MyEditor')
  await writeFile(executable, 'synthetic executable')
  await chmod(executable, 0o755)
  let mount
  let detached = false
  t.after(async () => {
    await rm(root, { recursive: true, force: true })
    // This runner simulates an image mount using ordinary temporary files.
    if (mount) await rm(path.dirname(mount), { recursive: true, force: true })
  })
  const runner = async (command, args) => {
    if (command === '/usr/bin/codesign') {
      if (invalidSignature) throw new Error('Invalid signature')
      return
    }
    assert.equal(command, '/usr/bin/hdiutil')
    if (args[0] === 'attach') {
      mount = args[args.indexOf('-mountpoint') + 1]
      await cp(bundle, path.join(mount, 'MyEditor.app'), { recursive: true })
      await symlink(wrongShortcut ? '/tmp' : '/Applications', path.join(mount, 'Applications'))
      if (corrupt)
        await writeFile(
          path.join(mount, 'MyEditor.app', 'Contents', 'MacOS', 'MyEditor'),
          'corrupted',
        )
    } else if (args[0] === 'detach') {
      if (detachFails) throw new Error('Volume busy')
      detached = true
    } else assert.equal(args[0], 'verify')
  }
  return {
    bundle,
    runner,
    get mount() {
      return mount
    },
    get detached() {
      return detached
    },
  }
}

test('validates bundle contents, executable permissions and Applications shortcut', async (t) => {
  const f = await fixture(t)
  const result = await verifyDiskImage(f.bundle, '/synthetic.dmg', f.runner)
  assert(result.applicationMatchesBundle)
  assert(f.detached)
  await assert.rejects(access(f.mount), { code: 'ENOENT' })
})

for (const [name, options, message] of [
  ['changed application', { corrupt: true }, /differs/],
  ['wrong installation destination', { wrongShortcut: true }, /shortcut/],
  ['invalid code signature', { invalidSignature: true }, /Invalid signature/],
]) {
  test(`rejects ${name} and detaches the image`, async (t) => {
    const f = await fixture(t, options)
    await assert.rejects(verifyDiskImage(f.bundle, '/synthetic.dmg', f.runner), message)
    assert(f.detached)
    await assert.rejects(access(f.mount), { code: 'ENOENT' })
  })
}

test('failed detach preserves the mounted directory instead of recursively deleting it', async (t) => {
  const f = await fixture(t, { detachFails: true })
  await assert.rejects(verifyDiskImage(f.bundle, '/synthetic.dmg', f.runner), {
    code: 'DMG_DETACH_FAILED',
  })
  await access(path.join(f.mount, 'MyEditor.app', 'Contents', 'MacOS', 'MyEditor'))
})
