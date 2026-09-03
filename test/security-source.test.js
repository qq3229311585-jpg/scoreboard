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
