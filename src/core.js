/**
 * 纯业务逻辑 — 不依赖 DOM / localStorage / 全局变量。
 * mobile-web/index.html 内有对应的内联版本（函数名相同），
 * 两处需保持一致。待 #8 重构完成后将合并为单一来源。
 */

/**
 * 羽毛球 / 乒乓球局胜负判断。
 * @param {number} a  玩家 A 当前分
 * @param {number} b  玩家 B 当前分
 * @param {object} cfg  { ptWin, ptDeuce, ptMax }
 * @returns {0|1|-1}  0=A胜, 1=B胜, -1=未决
 */
export function checkRally(a, b, { ptWin, ptDeuce, ptMax }) {
  if (a < ptWin && b < ptWin) return -1;
  if (ptMax != null && (a >= ptMax || b >= ptMax)) return a > b ? 0 : 1;
  if (a >= ptWin && a - b >= 2) return 0;
  if (b >= ptWin && b - a >= 2) return 1;
  return -1;
}

/**
 * 提前结束羽毛球/乒乓球比赛时的胜者判断（纯函数版，不读全局 S/CFG）。
 * @param {{
 *   pts: [number,number],
 *   sets: [number,number],
 *   setScores: [number,number][],
 *   setTimes: number[],
 *   startTime: number
 * }} state
 * @param {number} now  当前时间戳 ms（可注入，方便测试）
 * @returns {{ winner: 0|1, sets: [number,number], setScores: [number,number][], setTimes: number[] } | null}
 *          null 表示完全平分，无法结束
 */
export function earlyFinishRally(state, now = Date.now()) {
  const { pts, sets, setScores = [], setTimes = [], startTime } = state;
  let newSets = [...sets];
  let newSetScores = [...setScores];
  let newSetTimes = setTimes.length ? [...setTimes] : [startTime];

  const [ptA, ptB] = pts;
  if (ptA !== ptB) {
    const sw = ptA > ptB ? 0 : 1;
    newSetScores.push([ptA, ptB]);
    newSetTimes.push(now);
    newSets[sw]++;
  }

  const [sA, sB] = newSets;
  if (sA !== sB) {
    return { winner: sA > sB ? 0 : 1, sets: newSets, setScores: newSetScores, setTimes: newSetTimes };
  }

  // 局数仍平：用累计总得分决出
  const cumA = newSetScores.reduce((acc, [a]) => acc + a, 0);
  const cumB = newSetScores.reduce((acc, [, b]) => acc + b, 0);
  if (cumA !== cumB) {
    return { winner: cumA > cumB ? 0 : 1, sets: newSets, setScores: newSetScores, setTimes: newSetTimes };
  }

  return null; // 完全平分
}

/**
 * 标准化手表回传的比赛记录。
 * @param {object} record  手表发来的原始 record 对象
 * @param {object|null} activeProfile  当前活跃档案（{ id, name, hrEnabled }），无则传 null
 * @returns {object|null}
 */
export function normalizeWatchRecord(record, activeProfile = null) {
  if (!record || typeof record !== 'object') return null;
  const ap = activeProfile;
  return {
    id: record.id || Date.now(),
    date: record.date || Date.now(),
    sport: record.sport || 'badminton',
    names: Array.isArray(record.names) && record.names.length >= 2
      ? record.names : ['我方', '对手'],
    rules: record.rules || { ptWin: 21, setWin: 1, totalSets: 1 },
    events: Array.isArray(record.events) ? record.events : [],
    sets: Array.isArray(record.sets) ? record.sets : [],
    setScores: Array.isArray(record.setScores) ? record.setScores : [],
    setTimes: Array.isArray(record.setTimes) ? record.setTimes : [],
    winner: Number.isInteger(record.winner) ? record.winner : null,
    duration: Number(record.duration || 0),
    heartRateTimeline: Array.isArray(record.heartRateTimeline) ? record.heartRateTimeline : [],
    hrPlayerIdx: Number.isInteger(record.hrPlayerIdx) ? record.hrPlayerIdx : 0,
    hrProfileId: record.hrProfileId ?? (
      ap?.hrEnabled && Array.isArray(record.names) && record.names.includes(ap.name)
        ? ap.id : null
    ),
    _saved: true,
  };
}

// ─────────────────────────────────────────────────────────
// 以下函数在 mobile-web/index.html 内有同名内联版本，改动需两处同步。
// ─────────────────────────────────────────────────────────

/**
 * 网球抢七判定（ITF：先到 7 分且领先 2 分）+ 局数结算。
 * 抢七获胜等于赢下第 13 局，所以胜方局数要 +1（记 7-6），否则局分会错记成 6-6。
 * @param {[number,number]} tbPts  抢七比分
 * @param {[number,number]} games  当前盘内局数（通常 [6,6]）
 * @returns {{winner:0|1, games:[number,number]}|null} null=尚未分出胜负
 */
export function tiebreakResult(tbPts, games) {
  const [a, b] = tbPts;
  if ((a >= 7 || b >= 7) && Math.abs(a - b) >= 2) {
    const winner = a > b ? 0 : 1;
    const g = [...games];
    g[winner]++;
    return { winner, games: g };
  }
  return null;
}

/**
 * 抢七当前发球方：首发方发 1 分，之后双方轮流各发 2 分（ITF）。
 * 同时也是"盘末接发方下盘先发"的依据：下一盘先发 = 1 - firstServer。
 * @param {0|1} firstServer 抢七首分发球方
 * @param {number} totalPts 抢七已打总分
 */
export function tiebreakServer(firstServer, totalPts) {
  return (firstServer + Math.ceil(totalPts / 2)) % 2;
}

/**
 * 下一局的先发球方。
 * 羽毛球：上一局胜者先发（BWF）。
 * 乒乓球：每局轮换先发，与胜负无关（ITTF 2.13：上一局先发方下一局先接发）。
 * @param {'badminton'|'tabletennis'} sport
 * @param {0|1} winner 上一局胜者
 * @param {0|1} prevFirstServer 上一局先发方
 */
export function nextGameFirstServer(sport, winner, prevFirstServer) {
  return sport === 'tabletennis' ? 1 - prevFirstServer : winner;
}

/**
 * 羽毛球封顶分。21 分制封顶 30（BWF）；BWF 3×15 新制（15 分，封顶 21）；
 * 其余自定义胜分沿用 +9。
 */
export function badmintonPtMax(ptWin) {
  if (ptWin === 15) return 21;
  return ptWin + 9;
}

/**
 * 是否该提示"换边"（仅提示，不自动换）。
 * 羽毛球：决胜局一方先到 ceil(胜分/2)（21 分制=11）；
 * 乒乓球：决胜局一方先到 floor(胜分/2)（11 分制=5）；
 * 网球：每个奇数局结束（点数 0:0）；抢七每 6 分。
 * @param {{sport:string, ptWin?:number, setWin?:number}} cfg
 * @param {object} st 比赛状态（pts/sets/games/tb/tbPts）
 */
export function changeEndsDue(cfg, st) {
  if (!st) return false;
  const { sport } = cfg;
  if (sport === 'badminton' || sport === 'tabletennis') {
    const need = cfg.setWin - 1;
    if (!(st.sets && st.sets[0] === need && st.sets[1] === need)) return false;
    const target = sport === 'badminton' ? Math.ceil(cfg.ptWin / 2) : Math.floor(cfg.ptWin / 2);
    const [a, b] = st.pts;
    return Math.max(a, b) === target && Math.min(a, b) < target;
  }
  if (sport === 'tennis') {
    if (st.tb) {
      const tot = st.tbPts[0] + st.tbPts[1];
      return tot > 0 && tot % 6 === 0;
    }
    const g = st.games[0] + st.games[1];
    return g % 2 === 1 && st.pts[0] === 0 && st.pts[1] === 0;
  }
  return false;
}

/**
 * 解析 localStorage 里的历史记录。损坏（非法 JSON/非数组）时返回空数组并标记 corrupt，
 * 调用方在覆盖写回前应先把原文备份，避免一次存档把"读不出来但可能可修复"的数据彻底覆盖。
 * @param {string|null} raw
 * @returns {{list:any[], corrupt:boolean}}
 */
export function parseHistoryArray(raw) {
  if (raw == null || raw === '') return { list: [], corrupt: false };
  try {
    const v = JSON.parse(raw);
    if (Array.isArray(v)) return { list: v, corrupt: false };
    return { list: [], corrupt: true };
  } catch (e) {
    return { list: [], corrupt: true };
  }
}
