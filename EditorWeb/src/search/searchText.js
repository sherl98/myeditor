// Search offsets always refer to the original UTF-16 string, including emoji.
export function literalMatches(text, query) {
  if (!query || /[\r\n]/.test(query)) return []
  const expression = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu')
  return Array.from(text.matchAll(expression), (match) => ({
    from: match.index,
    to: match.index + match[0].length,
    text: match[0],
  }))
}

export function replaceRanges(text, ranges, replacement) {
  let result = text
  for (const range of [...ranges].sort((a, b) => b.from - a.from)) {
    result = result.slice(0, range.from) + replacement + result.slice(range.to)
  }
  return result
}

// Apply a range to formatted text runs without serializing/reimporting Markdown.
// The replacement inherits the first run's formatting; unaffected runs survive.
export function editsForRuns(parts, from, to, replacement) {
  return parts
    .filter((part) => part.end > from && part.start < to)
    .map((part, index) => ({
      ...part,
      from: Math.max(0, from - part.start),
      to: Math.min(part.text.length, to - part.start),
      replacement: index === 0 ? replacement : '',
    }))
}
