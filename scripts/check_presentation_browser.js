// Playwright MCP browser_run_code_unsafe filename. Run against the final app :8080.
async (page) => {
  const checks = [];
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  const api = 'http://127.0.0.1:8000';
  const metrics = ['anomaly_score', 'inspection_risk_score', 'timeseries_anomaly_score'];
  const rows = (await (await page.request.get(`${api}/api/data/rpf?limit=100`)).json()).items;
  const seeded = rows.filter(row => /^RPF-\d{3}$/.test(row.product_id));
  if (seeded.length !== 30 || seeded.some(row => metrics.some(key => row[key] == null))) {
    throw Error('30 fully analyzed RPF records required');
  }
  const forbidden = /데모|합성|테스트|\bdemo\b|synthetic/i;
  async function scan(label) {
    const text = await page.locator('body').ariaSnapshot();
    if (forbidden.test(text)) throw Error(`${label}: forbidden visible text`);
    checks.push(`${label}: labels clean`);
    return text;
  }
  async function click(button) {
    await button.evaluate(el => el.click());
    await page.waitForTimeout(250);
  }
  await page.setViewportSize({width: 1440, height: 900});
  await page.goto('http://127.0.0.1:8080');
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  await page.getByRole('button', {name: '품질관리', exact: true}).waitFor();
  await page.waitForTimeout(400);
  const dashboard = await scan('dashboard');
  if (!dashboard.includes('분석 결과 30 / 30건') || !dashboard.includes('제품별 분석 점수 추세')) {
    throw Error('Dashboard analysis not visible');
  }
  await page.screenshot({path: '/tmp/causalroboqc-dashboard.png'});
  await click(page.getByRole('button', {name: '품질관리', exact: true}));
  await page.getByRole('row', {name: /^RPF-022 /}).waitFor();
  for (const row of seeded) {
    const text = await page.getByRole('row', {name: new RegExp(`^${row.product_id} `)}).ariaSnapshot();
    for (const key of metrics) {
      if (!text.includes(`${(row[key] * 100).toFixed(1)}%`)) throw Error(`Quality score mismatch ${row.product_id}: ${key}`);
    }
  }
  await scan('quality 30 rows and metric help');
  const selected = seeded.find(row => row.product_id === 'RPF-022');
  const detail = await (await page.request.get(`${api}/api/rpf/${selected.id}`)).json();
  await page.getByRole('row', {name: /^RPF-022 /}).click();
  await page.getByRole('dialog').waitFor();
  await page.waitForTimeout(300);
  const product = await scan('product detail');
  for (const key of metrics) {
    if (!product.includes(`${Math.round(selected[key] * 100)}%`)) throw Error(`Detail score mismatch: ${key}`);
  }
  for (const stage of detail.presentation.stages) {
    if (!product.includes(`${(stage.duration_ms / 1000).toFixed(3)}초`)) throw Error('Stage time mismatch');
  }
  await click(page.getByRole('button', {name: '품질보고서 초안', exact: true}));
  const report = await scan('report and checks');
  if (!report.includes('보고서 복사') || !report.includes('공정 단계 시간 이상도:')) throw Error('Report missing');
  await page.mouse.move(900, 650);
  await page.mouse.wheel(0, 750);
  await page.waitForTimeout(250);
  await page.screenshot({path: '/tmp/causalroboqc-product-detail.png'});
  await click(page.getByRole('button', {name: '닫기', exact: true}));
  await click(page.getByRole('button', {name: '데이터 조회', exact: true}));
  for (const label of ['시작일 지우기', '종료일 지우기']) {
    await click(page.getByRole('button', {name: label, exact: true}));
  }
  const loaded = page.waitForResponse(response => response.url().includes('/api/data/rpf?'));
  await click(page.getByRole('button', {name: '조회', exact: true}));
  await loaded;
  await page.waitForTimeout(200);
  let displayed = 0;
  for (let index = 0; index < 2; index++) {
    const visibleRows = page.getByRole('row', {name: /^RPF-\d{3} /});
    for (const row of await visibleRows.all()) {
      const text = await row.ariaSnapshot();
      const ident = text.match(/RPF-\d{3}/)[0];
      const saved = seeded.find(item => item.product_id === ident);
      for (const key of metrics) {
        if (!text.includes(`${(saved[key] * 100).toFixed(1)}%`)) throw Error(`Data browser score mismatch: ${ident}`);
      }
      displayed++;
    }
    await scan(`data page ${index + 1}`);
    if (index === 0) {
      // Flutter creates semantics for the footer only once it enters the viewport.
      await page.mouse.move(900, 600);
      await page.mouse.wheel(0, 1900);
      await page.getByRole('button', {name: '다음', exact: true}).waitFor();
      const next = page.waitForResponse(response => response.url().includes('/api/data/rpf?'));
      await click(page.getByRole('button', {name: '다음', exact: true}));
      await next;
      await page.waitForTimeout(200);
    }
  }
  if (displayed !== 30) throw Error(`Expected 30 displayed rows, saw ${displayed}`);
  await page.mouse.move(900, 500);
  await page.mouse.wheel(0, -2500);
  await page.getByRole('button', {name: 'CSV 다운로드', exact: true}).waitFor();
  const download = page.waitForEvent('download');
  await click(page.getByRole('button', {name: 'CSV 다운로드', exact: true}));
  const csv = await download;
  if (!csv.suggestedFilename().endsWith('.csv')) throw Error('CSV not downloaded');
  checks.push('CSV download and 30 data rows verified');
  await click(page.getByRole('button', {name: '로봇 제어', exact: true}));
  await scan('robot controls');
  await click(page.getByRole('button', {name: '대시보드', exact: true}));
  await page.setViewportSize({width: 390, height: 844});
  await scan('mobile dashboard');
  await page.screenshot({path: '/tmp/causalroboqc-mobile.png'});
  if (errors.length) throw Error(errors.join('\n'));
  return checks;
}
