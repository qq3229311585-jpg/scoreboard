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
