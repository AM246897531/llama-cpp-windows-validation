'use strict';
const crypto=require('node:crypto');const https=require('node:https');const assert=require('node:assert/strict');
const GENRES=["modern_hebrew","mishnah","gemara","rishonim","poskim"];const WIKI_SOURCES=[{"genre":"mishnah","title":"משנה ברכות א","author":"Mishnah, ancient collective authorship"},{"genre":"mishnah","title":"משנה פאה א","author":"Mishnah, ancient collective authorship"},{"genre":"gemara","title":"ברכות ב א","author":"Babylonian Talmud, ancient collective authorship"},{"genre":"gemara","title":"ברכות ב ב","author":"Babylonian Talmud, ancient collective authorship"},{"genre":"gemara","title":"ברכות ג א","author":"Babylonian Talmud, ancient collective authorship"},{"genre":"rishonim","title":"רמב\"ם הלכות תלמוד תורה פרק א","author":"Moses Maimonides (1138–1204)"},{"genre":"rishonim","title":"רמב\"ם הלכות תשובה פרק א","author":"Moses Maimonides (1138–1204)"},{"genre":"poskim","title":"שולחן ערוך אורח חיים א","author":"Joseph Karo (1488–1575); Moses Isserles (1530–1572)"},{"genre":"poskim","title":"שולחן ערוך אורח חיים ב","author":"Joseph Karo (1488–1575); Moses Isserles (1530–1572)"},{"genre":"poskim","title":"שולחן ערוך אורח חיים ג","author":"Joseph Karo (1488–1575); Moses Isserles (1530–1572)"}];
const sha256=value => crypto.createHash('sha256').update(value).digest('hex');const WIKI_USER_AGENT="AncientTextReviewBot/1.0 (+https://github.com/AM246897531/llama-cpp-windows-validation; small serial licensed research corpus)";
function wikiUrl(parameters) {
  const url = new URL('https://he.wikisource.org/w/api.php');
  url.search = new URLSearchParams({ format: 'json', formatversion: '2', ...parameters }).toString();
  return url;
}
function retryPlan(status, retryAfter, attempt, now = Date.now()) {
  if (![429, 503].includes(status)) return { retry: false, reason: 'Non-retryable HTTP status' };
  if (attempt >= 3) return { retry: false, reason: 'Three-attempt bound reached' };
  let delay = status === 429 ? 10000 * attempt : 5000 * attempt;
  if (typeof retryAfter === 'string' && retryAfter.trim()) {
    const value = retryAfter.trim();
    const numeric = /^\d+$/u.test(value) ? Number(value) * 1000 : Date.parse(value) - now;
    if (Number.isFinite(numeric)) delay = Math.max(0, numeric);
  }
  if (delay > 60000) return { retry: false, reason: 'Official Retry-After exceeds the sixty-second bounded wait' };
  return { retry: true, delay_ms: Math.max(1500, delay), reason: 'Honor official 429/503 backoff' };
}
function requestAttempt(url, budget) {
  assert.equal(url.origin, 'https://he.wikisource.org', 'Only official Hebrew Wikisource is permitted');
  return new Promise((resolve, reject) => {
    const request = https.get(url, { headers: { 'User-Agent': WIKI_USER_AGENT, Accept: 'application/json' } }, response => {
      const chunks = []; let bytes = 0;
      response.on('data', chunk => {
        bytes += chunk.length; budget.used += chunk.length;
        if (bytes > 350000 || budget.used > 1000000) response.destroy(new Error('Corpus download exceeded the one-megabyte total limit'));
        else chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => {
        try {
          const raw = Buffer.concat(chunks);
          if (response.statusCode !== 200) {
            const context = { action: url.searchParams.get('action'), title: url.searchParams.get('titles') ?? null, oldid: url.searchParams.get('oldid') ?? null };
            resolve({ failure: { status: response.statusCode, content_type: String(response.headers['content-type'] ?? '').slice(0, 120),
              retry_after: String(response.headers['retry-after'] ?? '').slice(0, 120), context,
              body_excerpt: raw.toString('utf8').slice(0, 512).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/gu, '') } });
            return;
          }
          const data = JSON.parse(raw.toString('utf8')); assert.ok(!data.error, 'Official API returned an error');
          resolve({ data, bytes: raw.length, sha256: sha256(raw) });
        }
        catch (error) { reject(error); }
      });
    });
    request.setTimeout(20000, () => request.destroy(new Error('Official API request timed out')));
    const deadline = setTimeout(() => request.destroy(new Error('Official API exceeded twenty-second wall-clock bound')), 20000);
    deadline.unref();
    request.once('close', () => clearTimeout(deadline));
    request.on('error', reject);
  });
}
async function requestJson(url, budget) {
  assert.equal(url.origin, 'https://he.wikisource.org', 'Only official Hebrew Wikisource is permitted');
  budget.started_at ??= Date.now();
  for (let attempt = 1; attempt <= 3; attempt++) {
    const cadence = Math.max(0, 1500 - (Date.now() - (budget.last_request_at ?? 0)));
    assert.ok(Date.now() - budget.started_at + cadence + 20000 < 540000, 'Nine-minute whole-collection bound reached');
    if (cadence) await new Promise(resolve => setTimeout(resolve, cadence));
    budget.last_request_at = Date.now();
    const result = await requestAttempt(url, budget);
    if (!result.failure) return result;
    const plan = retryPlan(result.failure.status, result.failure.retry_after, attempt);
    console.error(JSON.stringify({ official_api_failure: result.failure, attempt, retry_policy: plan }));
    if (!plan.retry) throw new Error(`Official API returned HTTP ${result.failure.status}; ${plan.reason}`);
    assert.ok(Date.now() - budget.started_at + plan.delay_ms + 20000 < 540000, 'Nine-minute whole-collection bound reached');
    await new Promise(resolve => setTimeout(resolve, plan.delay_ms));
  }
  throw new Error('Official API retry bound reached');
}
function decodeEntities(text) {
  const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '–', mdash: '—', thinsp: ' ', lrm: '\u200e', rlm: '\u200f', hellip: '…' };
  return text.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/giu, (whole, entity) => {
    if (entity[0] !== '#') return named[entity.toLowerCase()] ?? whole;
    const value = parseInt(entity.slice(entity[1].toLowerCase() === 'x' ? 2 : 1), entity[1].toLowerCase() === 'x' ? 16 : 10);
    return value > 0 && value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff) ? String.fromCodePoint(value) : whole;
  });
}
function wikiPlainText(html) {
  assert.equal(typeof html, 'string');
  return decodeEntities(html.replace(/<!--[\s\S]*?-->/gu, '')
    .replace(/<(script|style|noscript)\b[^>]*>[\s\S]*?<\/\1\s*>/giu, '')
    .replace(/<(?:br|hr)\b[^>]*>/giu, '\n')
    .replace(/<\/(?:p|div|h[1-6]|li|tr|section|table)>/giu, '\n\n')
    .replace(/<[^>]*>/gu, '')).replace(/\r\n?/gu, '\n')
    .replace(/[ \t]+\n/gu, '\n').replace(/\n{3,}/gu, '\n\n').trim();
}
function verifyWikiLicense(siteinfo) {
  const rights = siteinfo.query?.rightsinfo;
  const url = rights?.url?.replace(/^http:/u, 'https:');
  assert.ok(url && /^https:\/\/creativecommons\.org\/licenses\/by-sa\/4\.0\/?(?:deed(?:\.[a-z-]+)?)?$/u.test(url), 'Official wiki license must explicitly be CC BY-SA 4.0');
  assert.equal(siteinfo.query?.general?.wikiid, 'hewikisource', 'Unexpected wiki publisher');
  return { id: 'CC-BY-SA-4.0', url, text: rights.text, publisher: 'Hebrew Wikisource / Wikimedia contributors' };
}
async function collectWiki({ fetchJson = requestJson, sources = WIKI_SOURCES } = {}) {
  const budget = { used: 0 };
  const site = await fetchJson(wikiUrl({ action: 'query', meta: 'siteinfo', siprop: 'general|rightsinfo' }), budget);
  const license = verifyWikiLicense(site.data);
  const rows = [];
  for (const source of sources) {
    assert.ok(GENRES.includes(source.genre) && source.genre !== 'modern_hebrew', 'Unexpected corpus genre');
    const response = await fetchJson(wikiUrl({ action: 'query', prop: 'revisions', titles: source.title,
      redirects: '1', rvprop: 'ids|timestamp|user|content', rvslots: 'main' }), budget);
    const pages = response.data.query?.pages;
    assert.ok(Array.isArray(pages) && pages.length === 1, 'Expected exactly one original-source page');
    const page = pages[0], revision = page.revisions?.[0], slot = revision?.slots?.main;
    assert.ok(page.ns === 0 && !page.missing && page.pageid > 0 && page.title, `Missing/non-original namespace source: action=query; requested title=${source.title}; returned title=${page.title ?? '(none)'}`);
    assert.ok(Number.isSafeInteger(revision?.revid) && revision.revid > 0 && /^\d{4}-\d{2}-\d{2}T/u.test(revision.timestamp), 'Source revision must be pinned');
    assert.ok(slot?.contentmodel === 'wikitext' && typeof slot.content === 'string', 'Expected original-source wikitext');
    assert.ok(!/כל הזכויות שמורות|©|\{\{\s*(?:copyright|הזכויות שמורות|שימוש הוגן)|creativecommons\.org\/licenses\/(?!by-sa\/4\.0)/iu.test(slot.content), 'Source declares incompatible or ambiguous license');
    const parsed = await fetchJson(wikiUrl({ action: 'parse', oldid: String(revision.revid), prop: 'text|revid|displaytitle' }), budget);
    const parse = parsed.data.parse;
    assert.equal(parse?.revid, revision.revid, 'Rendered text revision mismatch');
    assert.equal(parse.title, page.title, 'Rendered source title mismatch');
    const html = typeof parse.text === 'string' ? parse.text : parse.text?.['*'];
    const text = wikiPlainText(html);
    assert.ok(text.length >= 100 && /[\u05d0-\u05ea]/u.test(text), 'Source extraction is empty or non-Hebrew');
    const origin = `https://he.wikisource.org/w/index.php?title=${encodeURIComponent(page.title)}&oldid=${revision.revid}`;
    rows.push({ schema_version: 1, doc_id: `hewikisource:${page.pageid}:${revision.revid}`, genre: source.genre,
      title: page.title, requested_title: source.title, split: 'dev', original_text: text, content_sha256: sha256(text),
      source_license: license.id, source_origin: origin, license_evidence: license,
      attribution: `${source.author}; Hebrew Wikisource contributors; ${origin}; ${license.id}`,
      provenance: { publisher: license.publisher, original_author: source.author, page_id: page.pageid, namespace: 0,
        revision_id: revision.revid, revision_timestamp: revision.timestamp, revision_last_editor: revision.user,
        page_history: `https://he.wikisource.org/w/index.php?title=${encodeURIComponent(page.title)}&action=history`,
        wikitext_sha256: sha256(slot.content), rendered_html_sha256: sha256(html), query_response_sha256: response.sha256,
        parse_response_sha256: parsed.sha256, siteinfo_sha256: site.sha256, extractor: 'wikiPlainText-v1',
        extractor_sha256: sha256(wikiPlainText.toString() + decodeEntities.toString()),
        source_kind: 'rendered community edition of ancient original; human verification still required',
        transclusion_warning: 'oldid pins the source page, not historical revisions of transcluded templates; rendered derivative hash pins the collected bytes' } });
  }
  assert.ok(Buffer.byteLength(JSON.stringify(rows)) < 1000000, 'Prepared corpus exceeds one megabyte');
  return { schema_version: 1, classification: 'LICENSED INPUT / HUMAN REVIEW NOT DONE', sources: rows,
    collection: { official_host: 'he.wikisource.org', total_downloaded_bytes: budget.used, siteinfo_sha256: site.sha256,
      collector_sha256: sha256(JSON.stringify([WIKI_USER_AGENT, sources, ...[wikiUrl, retryPlan, requestAttempt, requestJson, decodeEntities, wikiPlainText, verifyWikiLicense, collectWiki].map(fn => fn.toString())])),
      request_policy: { serial: true, minimum_start_interval_ms: 1500, retry_statuses: [429, 503], maximum_attempts: 3,
        maximum_retry_after_ms: 60000, maximum_request_wall_ms: 20000, maximum_collection_wall_ms: 540000, redirects: false },
      licenses: [license], human_review: false } };
}
collectWiki().then(result=>process.stdout.write(JSON.stringify(result)+"\n")).catch(error=>{console.error(error.message);process.exitCode=1;});
