import fs from "node:fs/promises";
import path from "node:path";

const root = process.cwd();
const outDir = path.join(root, "mobile-web");
const files = ["index.html", "main.js", "manifest.json", "sw.js"];
const dirs = ["icons", "themes"];

await fs.rm(outDir, { recursive: true, force: true });
await fs.mkdir(outDir, { recursive: true });

for (const file of files) {
  await fs.copyFile(path.join(root, file), path.join(outDir, file));
}

for (const dir of dirs) {
  await fs.cp(path.join(root, dir), path.join(outDir, dir), { recursive: true });
}
