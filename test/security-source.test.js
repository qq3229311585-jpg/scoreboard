import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const activeHtml = readFileSync(new URL('../index.html', import.meta.url), 'utf8');

describe('history HTML output safety', () => {
  it('escapes imported text before inserting it into HTML', () => {
    expect(activeHtml).toMatch(/function escapeHtml\(value\)/);
    expect(activeHtml).toMatch(/function normalizeImportedMatch\(record\)/);
    expect(activeHtml).toContain('Number.isSafeInteger(id)');
    expect(activeHtml).toContain('${escapeHtml(r.names[0])}');
    expect(activeHtml).toContain('${escapeHtml(r.names[1])}');
    expect(activeHtml).toContain('${escapeHtml(SPORT_LABELS[r.sport]||r.sport)}');
    expect(activeHtml).toContain('incoming.map(normalizeImportedMatch)');
  });
});

// 手表结束比赛 → watchMatchFinished/consumePendingWatchMatches → persistWatchMatchRecord，
// 或手机本地结束 → showWin → saveMatch：这些路径上手机端没人看着，模态 alert 会卡住 WebView JS 线程，
// 必须用非阻塞提示条（showNotice）。
function functionBody(src, name) {
  const start = src.indexOf(`function ${name}(`);
  expect(start).toBeGreaterThan(-1);
  const open = src.indexOf('{', src.indexOf(')', start));
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

describe('no modal alert on unattended save paths', () => {
  for (const fn of ['saveMatch', 'maybeWarnHistoryNearLimit', 'persistWatchMatchRecord', 'showWin']) {
    it(`${fn} 内不得出现 alert(`, () => {
      expect(functionBody(activeHtml, fn)).not.toMatch(/\balert\s*\(/);
    });
  }
  it('存档失败使用 showNotice', () => {
    expect(functionBody(activeHtml, 'saveMatch')).toContain('showNotice(');
  });
});
