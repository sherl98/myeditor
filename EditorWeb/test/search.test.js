import test from 'node:test'
import assert from 'node:assert/strict'
import { literalMatches, replaceRanges, editsForRuns } from '../src/search/searchText.js'

test('literal Unicode search keeps offsets and ignores letter case without interpreting syntax', () => {
  const text = '👩🏽‍💻小猫 ABC abc a+b a.b [猫]'
  assert.equal(literalMatches(text, 'abc').length, 2)
  const chinese = literalMatches(text, '小猫')
  assert.equal(text.slice(chinese[0].from, chinese[0].to), '小猫')
  assert.equal(literalMatches(text, 'a+b').length, 1)
  assert.equal(literalMatches(text, 'a.b').length, 1)
  assert.equal(literalMatches(text, '[猫]').length, 1)
  assert.deepEqual(literalMatches(text, ''), [])
  assert.deepEqual(literalMatches(text, '小\n猫'), [])
})

test('replace-all uses a snapshot, supports deletion, and inserts dollar signs literally', () => {
  const ranges = literalMatches('猫猫 猫', '猫')
  assert.equal(replaceRanges('猫猫 猫', ranges, '猫猫'), '猫猫猫猫 猫猫')
  assert.equal(replaceRanges('猫猫 猫', ranges, '$&'), '$&$& $&')
  assert.equal(replaceRanges('猫猫 猫', ranges, ''), ' ')
})

test('a match crossing inline formatting retains untouched prefixes and suffixes', () => {
  const parts = [
    { key: 'plain', start: 0, end: 2, text: '一小' },
    { key: 'bold', start: 2, end: 4, text: '猫二' },
  ]
  const edits = editsForRuns(parts, 1, 3, '新名字')
  const changed = parts.map((part) => {
    const edit = edits.find((edit) => edit.key === part.key)
    return part.text.slice(0, edit.from) + edit.replacement + part.text.slice(edit.to)
  })
  assert.deepEqual(changed, ['一新名字', '二'])
})
