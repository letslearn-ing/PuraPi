// Pi TUI 侧的 Markdown 渲染基准，与 PuraPiMarkdownCostTests 使用同一份文档。
//
// 用法：node scripts/tui-markdown-bench.mjs
// 需要本机已安装 pi；路径通过 `npm root -g` 解析，不写死 Homebrew 前缀。
import { execSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

function resolveMarkdownModule() {
  const globalRoot = execSync('npm root -g', { encoding: 'utf8' }).trim();
  const candidate = join(
    globalRoot,
    '@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/dist/components/markdown.js'
  );
  if (!existsSync(candidate)) {
    console.error(`找不到 pi-tui 的 markdown 组件：${candidate}`);
    console.error('请确认已全局安装 @earendil-works/pi-coding-agent。');
    process.exit(1);
  }
  return candidate;
}

const { Markdown } = await import(resolveMarkdownModule());

// 最小主题：只做恒等变换，避免把 ANSI 上色成本算进来。
// PuraPi 侧同样不含终端转义序列生成，这样两边比较的是布局与换行本身。
const identity = (s) => s;
const theme = new Proxy({}, { get: () => identity });

const WIDTH = 100;

function makeDoc(paragraphs) {
  const parts = [];
  for (let i = 0; i < paragraphs; i++) {
    parts.push(`## 小节 ${i}`);
    parts.push(`这是一段包含 \`inline code\` 与 **强调** 的正文，用于触发真实的行内解析与换行测量。序号 ${i}。`);
    parts.push('- 列表项一\n- 列表项二\n- 列表项三');
    parts.push('```swift\nlet value = compute(index: ' + i + ')\nprint(value)\n```');
  }
  return parts.join('\n\n');
}

function timeOnce(text, label) {
  // 每次新建组件，避免命中内部缓存——PuraPi 侧也是首次渲染
  const start = process.hrtime.bigint();
  const c = new Markdown(text, 0, 0, theme, identity);
  const lines = c.render(WIDTH);
  const ms = Number(process.hrtime.bigint() - start) / 1e6;
  return { ms, lines: lines.length };
}

for (const n of [10, 40, 100, 250]) {
  const text = makeDoc(n);
  // 预热 JIT
  for (let i = 0; i < 3; i++) timeOnce(text);
  const runs = [];
  for (let i = 0; i < 5; i++) runs.push(timeOnce(text));
  runs.sort((a, b) => a.ms - b.ms);
  const median = runs[2];
  console.log(`TUI paragraphs=${n} chars=${text.length} median=${median.ms.toFixed(1)}ms lines=${median.lines}`);
}
