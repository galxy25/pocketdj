#!/usr/bin/env node
// Render the Markdown legal documents into the static legal site (legal-site/), which
// scripts/legal-site-deploy.sh publishes to https://legal.pocket-dj.com (GREEN only).
//
//   node scripts/legal-site-build.mjs
//
// Generated pages (do not hand-edit their HTML; edit the .md and rebuild):
//   docs/legal/PRIVACY.md         → legal-site/privacy/index.html
//   docs/legal/DELETE-ACCOUNT.md  → legal-site/delete-account/index.html
// Hand-maintained pages: legal-site/{index,404}.html, terms/, dmca/, notices/.
//
// Rules: every HTML comment is stripped (maintainer notes and #TOUPDATE markers never ship),
// everything from "## Appendix B" down is dropped (internal appendices), "---" rules are
// dropped (the site's h2 already draws a rule), and the first "**Effective date: …**" line
// becomes the page's effective-date line. Requires pandoc (brew install pandoc).

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SITE = join(ROOT, 'legal-site');
const TEMPLATE = readFileSync(join(SITE, '_template.html'), 'utf8');

const PAGES = [
  { src: 'docs/legal/PRIVACY.md', out: 'privacy/index.html', title: 'Privacy Policy', toc: true, wideTable: 'Appendix A' },
  { src: 'docs/legal/DELETE-ACCOUNT.md', out: 'delete-account/index.html', title: 'Delete Your Account', toc: false },
];

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const textOf = (html) => html.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').trim();

function render(page) {
  let md = readFileSync(join(ROOT, page.src), 'utf8');
  md = md.replace(/<!--[\s\S]*?-->/g, '');
  const cut = md.indexOf('\n## Appendix B');
  if (cut >= 0) md = md.slice(0, cut);
  const eff = md.match(/^\*\*Effective date:\s*(.+?)\*\*\s*$/m);
  if (!eff) throw new Error(`${page.src}: no "**Effective date: …**" line`);
  md = md.replace(/^# .*$/m, '').replace(eff[0], '');
  md = md.split('\n').filter((l) => l.trim() !== '---').join('\n');
  if (/\{\{|\[Publisher\]|#TOUPDATE/.test(md)) throw new Error(`${page.src}: unresolved placeholder or marker in the public part`);

  let body = execFileSync('pandoc', ['-f', 'gfm', '-t', 'html5', '--wrap=none'], { input: md, encoding: 'utf8' });

  // Permalink anchors + TOC entries.
  const toc = [];
  body = body.replace(/<(h[23]) id="([^"]+)">([\s\S]*?)<\/\1>/g, (_, tag, id, inner) => {
    toc.push({ level: tag === 'h2' ? 2 : 3, id, text: textOf(inner) });
    return `<${tag} id="${id}">${inner} <a class="anchor" href="#${id}" aria-label="Permalink">#</a></${tag}>`;
  });

  // Scrollable tables; the wide data-flow table gets the four-column min width.
  let section = '';
  body = body.replace(/(<h2 id="[^"]+">([\s\S]*?)<\/h2>)|<table>([\s\S]*?)<\/table>/g, (m, h2, h2inner, tbl) => {
    if (h2) { section = textOf(h2inner); return m; }
    const cls = page.wideTable && section.startsWith(page.wideTable) ? ' class="four"' : '';
    return `<div class="table-wrap">\n<table${cls}>${tbl}</table>\n</div>`;
  });

  // A trailing all-italic paragraph is the closing note.
  body = body.replace(/<p><em>([\s\S]*?)<\/em><\/p>\s*$/, '<p class="closing"><em>$1</em></p>\n');

  let tocHtml = '';
  if (page.toc) {
    const items = [];
    for (let i = 0; i < toc.length; i++) {
      const t = toc[i];
      if (t.level !== 2) continue;
      const subs = [];
      for (let j = i + 1; j < toc.length && toc[j].level === 3; j++) subs.push(toc[j]);
      const sub = subs.length
        ? `\n      <ul>\n${subs.map((s) => `        <li><a href="#${s.id}">${esc(s.text)}</a></li>`).join('\n')}\n      </ul>\n    `
        : '';
      items.push(`    <li><a href="#${t.id}">${esc(t.text)}</a>${sub}</li>`);
    }
    tocHtml = `<details class="toc" open>\n  <summary>Contents</summary>\n  <nav aria-label="Table of contents">\n  <ul class="toc-list">\n${items.join('\n')}\n  </ul>\n  </nav>\n</details>\n\n`;
  }

  const main = `<h1>${esc(page.title)}</h1>\n<p class="effective">Effective date: ${esc(eff[1])}</p>\n\n${tocHtml}${body.trim()}`;
  const html = TEMPLATE.replaceAll('{{TITLE}}', esc(page.title)).replaceAll('{{DOCTITLE}}', esc(page.title)).replace('{{BODY}}', main);
  const out = join(SITE, page.out);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, html);
  console.log(`${page.src} → legal-site/${page.out} (${toc.length} headings)`);
}

for (const p of PAGES) render(p);
