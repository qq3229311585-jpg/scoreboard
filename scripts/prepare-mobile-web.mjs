// 同步 mobile-web 目录，让 Capacitor (iOS/Android) 拿到与 root 一致的资源。
//
// 方向约定：
//   index.html       — mobile-web 为唯一源（手机端是主要开发目标），反向同步到 root，
//                       供 Electron (Mac) 也能加载到最新内容。
//   其余 (main.js、manifest.json、sw.js、icons/、themes/) — root 为源，正向同步到 mobile-web。
//
// 这样开发者只编辑 mobile-web/index.html 即可，跑 `npm run prepare:mobile`
// 会把 index.html 反向同步到 root，并把其它资源刷新到 mobile-web。
import fs from "node:fs/promises";
import path from "node:path";

const root = process.cwd();
const outDir = path.join(root, "mobile-web");

// root → mobile-web
const filesRootToMobile = ["main.js", "manifest.json", "sw.js"];
const dirsRootToMobile = ["icons", "themes"];

// mobile-web → root
const filesMobileToRoot = ["index.html"];

await fs.mkdir(outDir, { recursive: true });

for (const file of filesRootToMobile) {
  const src = path.join(root, file);
  const dst = path.join(outDir, file);
  if (await exists(src)) {
    await fs.copyFile(src, dst);
  }
}

for (const dir of dirsRootToMobile) {
  const src = path.join(root, dir);
  const dst = path.join(outDir, dir);
  if (await exists(src)) {
    await fs.rm(dst, { recursive: true, force: true });
    await fs.cp(src, dst, { recursive: true });
  }
}

for (const file of filesMobileToRoot) {
  const src = path.join(outDir, file);
  const dst = path.join(root, file);
  if (await exists(src)) {
    await fs.copyFile(src, dst);
  }
}

async function exists(p) {
  try { await fs.access(p); return true; } catch { return false; }
}
