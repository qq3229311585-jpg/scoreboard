import { describe, it, expect } from 'vitest';
import {
  checkRally, earlyFinishRally, normalizeWatchRecord,
  tiebreakResult, tiebreakServer, nextGameFirstServer, badmintonPtMax,
  changeEndsDue, parseHistoryArray,
} from '../src/core.js';

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

// ══════════════════════════════════════════
// 网球抢七（ITF：7 分且领先 2；首发 1 分，之后每人连发 2 分；盘末接发方下盘先发）
// ══════════════════════════════════════════
describe('tiebreakResult', () => {
  it('未分胜负 → null', () => {
    expect(tiebreakResult([6, 6], [6, 6])).toBeNull();
    expect(tiebreakResult([7, 6], [6, 6])).toBeNull();
    expect(tiebreakResult([0, 0], [6, 6])).toBeNull();
  });

  it('7:5 获胜时胜方局数 +1（局分应记 7-6，而不是 6-6）', () => {
    const r = tiebreakResult([7, 5], [6, 6]);
    expect(r).toEqual({ winner: 0, games: [7, 6] });
    expect(tiebreakResult([3, 7], [6, 6])).toEqual({ winner: 1, games: [6, 7] });
  });

  it('抢七拉锯到 9:7 / 12:10 才分胜负', () => {
    expect(tiebreakResult([8, 7], [6, 6])).toBeNull();
    expect(tiebreakResult([9, 7], [6, 6])).toEqual({ winner: 0, games: [7, 6] });
    expect(tiebreakResult([10, 12], [6, 6])).toEqual({ winner: 1, games: [6, 7] });
  });

  it('不修改入参', () => {
    const games = [6, 6];
    tiebreakResult([7, 0], games);
    expect(games).toEqual([6, 6]);
  });
});

describe('tiebreakServer', () => {
  it('首分发球方发 1 分，随后每人连发 2 分', () => {
    // 总分 0..8 → 发球方（first=0）
    const seq = [0, 1, 2, 3, 4, 5, 6, 7, 8].map((t) => tiebreakServer(0, t));
    expect(seq).toEqual([0, 1, 1, 0, 0, 1, 1, 0, 0]);
  });

  it('first=1 时镜像', () => {
    expect([0, 1, 2, 3].map((t) => tiebreakServer(1, t))).toEqual([1, 0, 0, 1]);
  });
});

// ══════════════════════════════════════════
// 下一局先发球
// ══════════════════════════════════════════
describe('nextGameFirstServer', () => {
  it('羽毛球：上一局胜者先发', () => {
    expect(nextGameFirstServer('badminton', 1, 0)).toBe(1);
    expect(nextGameFirstServer('badminton', 0, 1)).toBe(0);
  });

  it('乒乓球：每局轮换先发，与上一局胜负无关（ITTF 2.13）', () => {
    // 上一局先发方 0，不论谁赢，下一局都由 1 先发
    expect(nextGameFirstServer('tabletennis', 0, 0)).toBe(1);
    expect(nextGameFirstServer('tabletennis', 1, 0)).toBe(1);
    // 上一局先发方 1，不论谁赢，下一局都由 0 先发
    expect(nextGameFirstServer('tabletennis', 0, 1)).toBe(0);
    expect(nextGameFirstServer('tabletennis', 1, 1)).toBe(0);
  });
});

// ══════════════════════════════════════════
// 羽毛球封顶分
// ══════════════════════════════════════════
describe('badmintonPtMax', () => {
  it('21 分制封顶 30（BWF）', () => {
    expect(badmintonPtMax(21)).toBe(30);
  });
  it('15 分制（BWF 3×15）封顶 21', () => {
    expect(badmintonPtMax(15)).toBe(21);
  });
  it('其他自定义胜分沿用 +9', () => {
    expect(badmintonPtMax(11)).toBe(20);
    expect(badmintonPtMax(25)).toBe(34);
  });
});

// ══════════════════════════════════════════
// 换边提示
// ══════════════════════════════════════════
describe('changeEndsDue', () => {
  const bad = { sport: 'badminton', ptWin: 21, setWin: 2 };
  const tt = { sport: 'tabletennis', ptWin: 11, setWin: 3 };
  const ten = { sport: 'tennis' };

  it('羽毛球：仅决胜局，一方先到 11 分时提示', () => {
    expect(changeEndsDue(bad, { pts: [11, 7], sets: [1, 1] })).toBe(true);
    expect(changeEndsDue(bad, { pts: [7, 11], sets: [1, 1] })).toBe(true);
    expect(changeEndsDue(bad, { pts: [12, 7], sets: [1, 1] })).toBe(false);
    expect(changeEndsDue(bad, { pts: [11, 7], sets: [1, 0] })).toBe(false); // 非决胜局
    expect(changeEndsDue(bad, { pts: [11, 11], sets: [1, 1] })).toBe(false); // 已过触发点
  });

  it('乒乓球：仅决胜局，一方先到 5 分时提示', () => {
    expect(changeEndsDue(tt, { pts: [5, 2], sets: [2, 2] })).toBe(true);
    expect(changeEndsDue(tt, { pts: [5, 2], sets: [2, 1] })).toBe(false);
    expect(changeEndsDue(tt, { pts: [6, 2], sets: [2, 2] })).toBe(false);
  });

  it('网球：每个奇数局结束（点数 0:0）提示；抢七每 6 分提示', () => {
    expect(changeEndsDue(ten, { games: [1, 0], pts: [0, 0], tb: false })).toBe(true);
    expect(changeEndsDue(ten, { games: [2, 1], pts: [0, 0], tb: false })).toBe(true);
    expect(changeEndsDue(ten, { games: [1, 1], pts: [0, 0], tb: false })).toBe(false);
    expect(changeEndsDue(ten, { games: [1, 0], pts: [15, 0], tb: false })).toBe(false);
    expect(changeEndsDue(ten, { games: [0, 0], pts: [0, 0], tb: false })).toBe(false);
    expect(changeEndsDue(ten, { games: [6, 6], pts: [0, 0], tb: true, tbPts: [3, 3] })).toBe(true);
    expect(changeEndsDue(ten, { games: [6, 6], pts: [0, 0], tb: true, tbPts: [3, 2] })).toBe(false);
    expect(changeEndsDue(ten, { games: [6, 6], pts: [0, 0], tb: true, tbPts: [0, 0] })).toBe(false);
  });

  it('篮球不提示', () => {
    expect(changeEndsDue({ sport: 'basketball' }, { score: [10, 8], quarter: 2 })).toBe(false);
  });
});

// ══════════════════════════════════════════
// 历史记录容错
// ══════════════════════════════════════════
describe('parseHistoryArray', () => {
  it('合法数组原样返回', () => {
    expect(parseHistoryArray('[{"id":1}]')).toEqual({ list: [{ id: 1 }], corrupt: false });
  });
  it('空值 → 空数组，不算损坏', () => {
    expect(parseHistoryArray(null)).toEqual({ list: [], corrupt: false });
    expect(parseHistoryArray('')).toEqual({ list: [], corrupt: false });
  });
  it('非法 JSON / 非数组 → 空数组并标记损坏（调用方应先备份原文再覆盖）', () => {
    expect(parseHistoryArray('{oops')).toEqual({ list: [], corrupt: true });
    expect(parseHistoryArray('{"a":1}')).toEqual({ list: [], corrupt: true });
  });
});
