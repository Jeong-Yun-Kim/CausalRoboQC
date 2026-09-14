// Playwright MCP browser_run_code_unsafe filename: this file's absolute path.
// Start server.tests.copilot_browser_fixture and its documented Flutter build.
async (page) => {
  const checks = [];
  const failures = [];
  page.on('pageerror', error => failures.push(String(error)));
  const panel = () => page.getByRole('group', {name: 'AI 코파일럿', exact: true}).first();
  const toggle = () => page.getByRole('button', {name: /^AI 코파일럿/});
  const close = () => page.getByRole('button', {name: '코파일럿 닫기', exact: true});
  async function click(locator) {
    // Exercise the accessibility action, independent of the canvas hit regions.
    await locator.evaluate(el => el.click());
    await page.mouse.move(0, 0);
    await page.waitForTimeout(200); // Flutter paints asynchronously to the canvas.
  }
  async function ask(question, expected = 200) {
    const input = page.getByRole('textbox', {name: '질문을 입력하세요'});
    await input.click();
    await page.keyboard.press('ControlOrMeta+A');
    // Use real editing events; assigning the semantics textarea value with fill
    // alone does not consistently update Flutter's TextEditingController.
    await page.keyboard.insertText(question);
    await page.waitForTimeout(150);
    const pending = page.waitForResponse(r => r.url().endsWith('/api/copilot/chat'));
    // Activate the semantic button directly: Flutter's canvas and its separate
    // accessibility DOM do not share native pointer hit testing while editing.
    await page.getByRole('button', {name: '전송', exact: true}).evaluate(el => el.click());
    const response = await pending;
    const body = await response.json();
    if (response.status() !== expected) throw Error(JSON.stringify(body));
    await page.waitForTimeout(200);
    checks.push({question, status: response.status(), chart: body.chart?.type ?? null,
                 rows: body.table?.rows.length ?? 0, demo: body.demo_data});
    return body;
  }

  await page.setViewportSize({width: 1440, height: 900});
  await page.goto('http://127.0.0.1:18080');
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  await click(toggle());
  await panel().waitFor();
  checks.push('dashboard open');
  await click(close());
  await panel().waitFor({state: 'hidden'});
  checks.push('close');
  await click(page.getByRole('button', {name: '품질관리', exact: true}));
  await click(toggle());
  checks.push('quality menu open');
  const help = await ask('CSV 다운로드는 어떻게 해?');
  if (!help.answer.includes('전체 제품')) throw Error('Missing CSV help');
  const product = await ask('DEMO-RPF-014가 왜 확인 필요야?');
  if (product.table.rows[0][0] !== 'DEMO-RPF-014' || !product.demo_data) throw Error('Product mismatch');
  const compare = await ask('DEMO-RPF-001과 DEMO-RPF-002 비교해줘');
  if (compare.table.rows.length !== 2) throw Error('Missing comparison');
  const bar = await ask('제품군별 평균 작업시간 그래프로 보여줘');
  if (bar.chart.type !== 'bar' || bar.chart.labels.join() !== 'A,B,C') throw Error('Missing bar');
  const line = await ask('최근 등급 추세 그래프로 보여줘');
  if (line.chart.type !== 'line') throw Error('Missing line');
  const missing = await ask('DEMO-RPF-999 설명해줘');
  if (missing.answer !== '현재 데이터에서 확인할 수 없습니다.') throw Error('Invented product');
  const unanalysed = await ask('최근 20개 제품 공정 이상도 그래프로 보여줘');
  if (unanalysed.chart !== null || !unanalysed.answer.includes('분석 결과 없음')) throw Error('Invented score');

  await page.request.post('http://127.0.0.1:11435/__test__/offline', {data: {offline: true}});
  try {
    const off = await ask('반복 실행은 어떻게 해?', 503);
    if (off.answer !== 'AI 코파일럿을 사용할 수 없습니다.\n로컬 AI 서버 상태를 확인해주세요.') throw Error('Error leak');
    if ((await page.request.get('http://127.0.0.1:18000/api/status')).status() !== 200) throw Error('Existing API blocked');
  } finally {
    await page.request.post('http://127.0.0.1:11435/__test__/offline', {data: {offline: false}});
  }
  for (const menu of ['로봇 제어', '데이터 조회']) {
    await click(close());
    await click(page.getByRole('button', {name: menu, exact: true}));
    await click(toggle());
    const history = await panel().ariaSnapshot();
    if (!history.includes('CSV 다운로드') && !history.includes('로컬 AI 서버 상태')) throw Error('Conversation lost');
    checks.push(`${menu}: conversation retained`);
  }
  await click(close());
  await page.setViewportSize({width: 390, height: 844});
  await click(toggle());
  const rect = await panel().boundingBox();
  if (rect.x < 0 || rect.x + rect.width > 390 || rect.y < 0 || rect.y + rect.height > 844) throw Error('Mobile overflow');
  checks.push({mobile: rect});
  await click(close());
  await panel().waitFor({state: 'hidden'});
  checks.push('mobile close');
  // Also verify ordinary pointer input with accessibility emulation disabled.
  const pointerPage = await page.context().newPage();
  try {
    await pointerPage.setViewportSize({width: 1440, height: 900});
    await pointerPage.goto('http://127.0.0.1:18080');
    await pointerPage.locator('flt-glass-pane').waitFor({state: 'attached'});
    await pointerPage.waitForTimeout(800);
    // Coordinates are the previously inspected 1440px panel/button bounds.
    await pointerPage.mouse.click(1392, 852);
    await pointerPage.waitForTimeout(200);
    await pointerPage.mouse.click(1160, 780);
    await pointerPage.keyboard.insertText('CSV 다운로드는 어떻게 해?');
    await pointerPage.waitForTimeout(150);
    const reply = pointerPage.waitForResponse(r => r.url().endsWith('/api/copilot/chat'));
    await pointerPage.mouse.click(1376, 780);
    if ((await reply).status() !== 200) throw Error('Pointer send failed');
    checks.push('ordinary pointer open, input and send');
  } finally {
    await pointerPage.close();
  }
  if (failures.length) throw Error(failures.join('\n'));
  return checks;
}
