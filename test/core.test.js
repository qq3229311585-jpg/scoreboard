import { describe, it, expect } from 'vitest';
import { checkRally, earlyFinishRally, normalizeWatchRecord } from '../src/core.js';

// ══════════════════════════════════════════
// checkRally
// ══════════════════════════════════════════
describe('checkRally', () => {
  const badminton = { ptWin: 21, ptDeuce: 20, ptMax: 30 };
  const tabletennis = { ptWin: 11, ptDeuce: 10, ptMax: null };

  it('未到胜分 → -1', () => {
    expect(checkRally(0, 0, badminton)).toBe(-1);
    expect(checkRally(20, 19, badminton)).toBe(-1);
    expect(checkRally(10, 9, tabletennis)).toBe(-1);
  });

  it('先到胜分且领先 ≥2 → 胜', () => {
    expect(checkRally(21, 19, badminton)).toBe(0);
    expect(checkRally(19, 21, badminton)).toBe(1);
    expect(checkRally(11, 9, tabletennis)).toBe(0);
    expect(checkRally(9, 11, tabletennis)).toBe(1);
  });

  it('到胜分但领先仅 1 → -1（平局继续）', () => {
    expect(checkRally(21, 20, badminton)).toBe(-1);
    expect(checkRally(20, 21, badminton)).toBe(-1);
    expect(checkRally(11, 10, tabletennis)).toBe(-1);
  });

  it('平局延伸直到领先 2 → 胜', () => {
    expect(checkRally(25, 23, badminton)).toBe(0);
    expect(checkRally(23, 25, badminton)).toBe(1);
    expect(checkRally(14, 12, tabletennis)).toBe(0);
  });

  it('羽毛球 30 分封顶 → 强制胜', () => {
    expect(checkRally(30, 29, badminton)).toBe(0);
    expect(checkRally(29, 30, badminton)).toBe(1);
    // 30:30 在实际比赛中不会出现（计分逐一累加，先到 30 即结束）
  });

  it('乒乓球无上限 → 平局可无限延伸', () => {
    expect(checkRally(20, 19, tabletennis)).toBe(-1);
    expect(checkRally(30, 29, tabletennis)).toBe(-1);
    expect(checkRally(30, 28, tabletennis)).toBe(0);
  });
});

// ══════════════════════════════════════════
// earlyFinishRally
// ══════════════════════════════════════════
describe('earlyFinishRally', () => {
  const NOW = 1700000000000;

  it('当局领先 → 赢当局，再由局数决出冠军', () => {
    const state = {
      pts: [15, 10],
      sets: [1, 0],
      setScores: [[21, 15]],
      setTimes: [NOW - 600000, NOW - 300000],
      startTime: NOW - 600000,
    };
    const result = earlyFinishRally(state, NOW);
    expect(result).not.toBeNull();
    expect(result.winner).toBe(0);      // A 赢当局 → 2-0 总局 → A胜
    expect(result.sets).toEqual([2, 0]);
    expect(result.setScores).toHaveLength(2);
  });

  it('当局平分 + 局数领先 → 由当前局数决出', () => {
    const state = {
      pts: [5, 5],       // 当局平
      sets: [1, 0],      // A 局数领先
      setScores: [[21, 15]],
      setTimes: [NOW - 600000, NOW - 300000],
      startTime: NOW - 600000,
    };
    const result = earlyFinishRally(state, NOW);
    expect(result).not.toBeNull();
    expect(result.winner).toBe(0);
  });

  it('局数平 + 累计总分领先 → 由总分决出', () => {
    const state = {
      pts: [5, 5],
      sets: [1, 1],
      setScores: [[21, 15], [15, 21]],
      setTimes: [NOW - 1200000, NOW - 600000, NOW - 300000],
      startTime: NOW - 1200000,
    };
    const result = earlyFinishRally(state, NOW);
    // 累计 A=21+15+5=41, B=15+21+5=41 → 平分，返回 null
    expect(result).toBeNull();
  });

  it('完全平分（当局平、局数平、累计总分平）→ null', () => {
    const state = {
      pts: [0, 0],
      sets: [1, 1],
      setScores: [[21, 15], [15, 21]],
      setTimes: [],
      startTime: NOW - 1200000,
    };
    // cumA=36, cumB=36
    expect(earlyFinishRally(state, NOW)).toBeNull();
  });

  it('当局 B 领先 → B 赢当局', () => {
    const state = {
      pts: [10, 18],
      sets: [1, 1],
      setScores: [[21, 10], [10, 21]],
      setTimes: [],
      startTime: NOW - 1200000,
    };
    const result = earlyFinishRally(state, NOW);
    expect(result).not.toBeNull();
    expect(result.winner).toBe(1);
  });

  it('比赛第一局就提前结束（无历史 setScores）', () => {
    const state = {
      pts: [13, 8],
      sets: [0, 0],
      setScores: [],
      setTimes: [],
      startTime: NOW - 300000,
    };
    const result = earlyFinishRally(state, NOW);
    expect(result).not.toBeNull();
    expect(result.winner).toBe(0);
    expect(result.sets).toEqual([1, 0]);
  });
});

// ══════════════════════════════════════════
// normalizeWatchRecord
// ══════════════════════════════════════════
describe('normalizeWatchRecord', () => {
  const validRecord = {
    id: 1700000000000,
    date: 1700000000000,
    sport: 'badminton',
    names: ['小明', '小红'],
    rules: { ptWin: 21, setWin: 2, totalSets: 3 },
    events: [],
    sets: [2, 1],
    setScores: [[21,15],[15,21],[21,18]],
    setTimes: [100, 200, 300, 400],
    winner: 0,
    duration: 3600000,
    heartRateTimeline: [{ timestamp: 100, bpm: 120 }],
    hrPlayerIdx: 0,
  };

  it('完整合法记录 → 原样保留关键字段', () => {
    const result = normalizeWatchRecord(validRecord);
    expect(result.id).toBe(validRecord.id);
    expect(result.sport).toBe('badminton');
    expect(result.winner).toBe(0);
    expect(result.names).toEqual(['小明', '小红']);
    expect(result._saved).toBe(true);
  });

  it('null / 非对象 → null', () => {
    expect(normalizeWatchRecord(null)).toBeNull();
    expect(normalizeWatchRecord('string')).toBeNull();
    expect(normalizeWatchRecord(42)).toBeNull();
  });

  it('缺少 names → 填默认值', () => {
    const r = normalizeWatchRecord({ ...validRecord, names: [] });
    expect(r.names).toEqual(['我方', '对手']);
  });

  it('非数组字段 → 填空数组', () => {
    const r = normalizeWatchRecord({ ...validRecord, events: null, setScores: undefined });
    expect(r.events).toEqual([]);
    expect(r.setScores).toEqual([]);
  });

  it('winner 非整数 → null', () => {
    expect(normalizeWatchRecord({ ...validRecord, winner: '0' }).winner).toBeNull();
    expect(normalizeWatchRecord({ ...validRecord, winner: null }).winner).toBeNull();
  });

  it('活跃档案名字匹配 → 绑定 hrProfileId', () => {
    const ap = { id: 'profile-1', name: '小明', hrEnabled: true };
    const r = normalizeWatchRecord({ ...validRecord, hrProfileId: undefined }, ap);
    expect(r.hrProfileId).toBe('profile-1');
  });

  it('活跃档案名字不匹配 → hrProfileId 为 null', () => {
    const ap = { id: 'profile-1', name: '张三', hrEnabled: true };
    const r = normalizeWatchRecord({ ...validRecord, hrProfileId: undefined }, ap);
    expect(r.hrProfileId).toBeNull();
  });

  it('档案未启用 HR → hrProfileId 为 null', () => {
    const ap = { id: 'profile-1', name: '小明', hrEnabled: false };
    const r = normalizeWatchRecord({ ...validRecord, hrProfileId: undefined }, ap);
    expect(r.hrProfileId).toBeNull();
  });

  it('record 自带 hrProfileId → 优先使用', () => {
    const ap = { id: 'profile-1', name: '小明', hrEnabled: true };
    const r = normalizeWatchRecord({ ...validRecord, hrProfileId: 'override-id' }, ap);
    expect(r.hrProfileId).toBe('override-id');
  });
});
