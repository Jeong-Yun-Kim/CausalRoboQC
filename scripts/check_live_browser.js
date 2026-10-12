// Playwright fixture ONLY: python -m server.tests.live_browser_fixture
async (page) => {
  const origin = 'http://127.0.0.1:18081';
  const checks = [];
  await page.setViewportSize({width:1440,height:1000});
  await page.route('**/*', route => {
    const url = route.request().url();
    if (url.startsWith(origin + '/') || /^(data|blob):/.test(url)) return route.continue();
    return route.abort();
  });
  await page.addInitScript(() => {
    window.cameraCalls = 0;
    if (navigator.mediaDevices) {
      navigator.mediaDevices.getUserMedia = async () => {
        window.cameraCalls++;
        throw new Error('Hardware camera access prohibited');
      };
    }
  });
  await page.request.post(origin + '/__fixture__/camera/online');
  await page.goto(origin);
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  const click = name => page.getByRole('button', {name, exact: true}).evaluate(el => el.click());
  await click('로봇 제어');
  await page.getByLabel('서버 카메라 영상', {exact: true}).waitFor();
  if (await page.getByRole('button', {name: '카메라 시작', exact: true}).count()) throw Error('Browser camera enabled');
  checks.push('server preview displays synthetic frame without browser capture');
  await page.request.post(origin + '/__fixture__/camera/offline');
  await page.getByText('카메라에 연결할 수 없습니다.', {exact:false}).waitFor();
  await page.request.post(origin + '/__fixture__/camera/online');
  await page.getByLabel('서버 카메라 영상', {exact: true}).waitFor();
  checks.push('camera failure message and recovery');
  if (await page.evaluate(() => window.cameraCalls)) throw Error('getUserMedia called');
  await click('품질관리');
  await page.getByRole('row', {name: /^RPF-022 /}).click();
  await page.getByRole('textbox', {name: /확인된 원인/}).waitFor();
  await page.mouse.move(1000,700);
  await page.mouse.wheel(0,1800);
  await page.waitForTimeout(300);
  for (const [name, value] of [[/확인된 원인/, '표면 손상'], [/^조치/, '재검사'], [/^메모/, 'fixture verification']]) {
    const field = page.getByRole('textbox', {name});
    await field.click();
    await field.press('ControlOrMeta+A');
    await page.keyboard.insertText(value);
    await page.waitForTimeout(100);
  }
  await page.getByRole('button', {name:'검사 결과 저장', exact:true}).click();
  await page.getByText('검사 결과를 저장했습니다.', {exact: false}).waitFor();
  const records = await (await page.request.get(origin + '/api/rpf?limit=100')).json();
  const record = records.items.find(row => row.product_id === 'RPF-022');
  if (record.inspection.note !== 'fixture verification' || record.inspection.action !== '재검사') throw Error('Inspection was not persisted');
  if (records.items.length !== 30) throw Error('Presentation count changed');
  checks.push('inspection save and fixed 30 presentation RPFs');
  await click('닫기');
  return checks;
}
