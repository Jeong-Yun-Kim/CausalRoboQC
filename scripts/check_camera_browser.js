// Playwright MCP browser_run_code_unsafe filename. Requires a real camera and :8080.
// Uses camera frames only for playback; never captures, stores or uploads images.
async (page) => {
  const checks = [];
  const forbiddenRequests = [];
  const watch = request => {
    if (/POST|PUT|PATCH/.test(request.method())) forbiddenRequests.push(request.url());
  };
  page.on('request', watch);
  const click = name => page.getByRole('button', {name, exact: true}).evaluate(el => el.click());
  const videoReady = () => page.waitForFunction(() => {
    const video = document.querySelector('#robot-camera-preview');
    return video && video.readyState >= 2 && video.videoWidth > 0 && !video.paused;
  });
  const stopped = () => page.waitForFunction(() =>
    window.cameraChecks.streams.every(s => s.getTracks().every(t => t.readyState === 'ended')));
  await page.goto('http://localhost:8080');
  await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
  await click('로봇 제어');
  await page.getByRole('button', {name: '카메라 시작', exact: true}).waitFor();
  await page.context().grantPermissions(['camera'], {origin: 'http://localhost:8080'});
  await page.evaluate(() => {
    const media = navigator.mediaDevices;
    const state = window.cameraChecks = {
      original: media.getUserMedia.bind(media), enumerate: media.enumerateDevices.bind(media),
      streams: [], calls: [], mode: 'live', release: null,
    };
    media.getUserMedia = async constraints => {
      state.calls.push(constraints);
      if (state.mode === 'denied') throw new DOMException('Denied', 'NotAllowedError');
      if (state.mode === 'missing') throw new DOMException('Missing', 'NotFoundError');
      if (state.mode === 'pending') await new Promise(resolve => { state.release = resolve; });
      const stream = await state.original(state.mode === 'switch'
        ? {video: true, audio: false} : constraints);
      state.streams.push(stream);
      return stream;
    };
  });
  try {
    if (await page.locator('video').count()) throw Error('Preview started without a click');
    await click('카메라 시작');
    await videoReady();
    const first = await page.locator('video').evaluate(v => ({
      time: v.currentTime, frames: v.getVideoPlaybackQuality().totalVideoFrames,
      width: v.videoWidth, height: v.videoHeight, displayWidth: v.getBoundingClientRect().width,
    }));
    await page.waitForTimeout(700);
    const progressing = await page.locator('video').evaluate((v, before) =>
      v.currentTime > before.time && v.getVideoPlaybackQuality().totalVideoFrames > before.frames, first);
    if (!progressing || first.displayWidth > 560) throw Error('Invalid live preview');
    checks.push({realVideo: first, advancingFrames: true});
    // Scrolling to the lower robot controls must not stop the camera.
    await page.mouse.move(700, 700);
    await page.mouse.wheel(0, 2400);
    await page.waitForTimeout(250);
    if (!await page.evaluate(() => window.cameraChecks.streams.at(-1).getTracks()[0].readyState === 'live')) {
      throw Error('Scrolling released the preview');
    }
    await page.mouse.wheel(0, -3000);
    await click('카메라 정지');
    await stopped();
    checks.push('stop releases all tracks; scrolling preserves capture');
    await click('카메라 시작');
    await videoReady();
    await click('대시보드');
    await stopped();
    checks.push('leaving robot tab releases all tracks');
    await click('로봇 제어');
    for (const mode of ['denied', 'missing']) {
      await page.evaluate(value => { window.cameraChecks.mode = value; }, mode);
      await click('카메라 시작');
      await page.getByRole('group', {name: /카메라를 사용할 수 없습니다\./}).waitFor();
      await page.getByRole('button', {name: '카메라 시작', exact: true}).waitFor();
      checks.push(`${mode}: short error and retry available`);
    }
    // Permission can resolve after cancellation; that late stream must be stopped.
    await page.evaluate(() => { window.cameraChecks.mode = 'pending'; });
    await click('카메라 시작');
    await page.waitForFunction(() => window.cameraChecks.release !== null);
    const before = await page.evaluate(() => window.cameraChecks.streams.length);
    await click('카메라 정지');
    await page.evaluate(() => { window.cameraChecks.release(); });
    await page.waitForFunction(count => window.cameraChecks.streams.length > count, before);
    await stopped();
    if (await page.locator('video').count()) throw Error('Late stream reactivated the preview');
    checks.push('late permission result is stopped');
    // Exercise selection with two logical devices backed by the same real camera.
    await page.evaluate(() => {
      window.cameraChecks.mode = 'switch';
      navigator.mediaDevices.enumerateDevices = async () => [
        {kind: 'videoinput', deviceId: 'camera-a', label: 'Camera A'},
        {kind: 'videoinput', deviceId: 'camera-b', label: 'Camera B'},
      ];
    });
    await click('카메라 시작');
    await videoReady();
    await page.getByRole('button', {name: '카메라 선택', exact: true}).evaluate(el => el.click());
    await page.getByRole('menuitem', {name: 'Camera B', exact: true}).evaluate(el => el.click());
    await page.waitForFunction(() => window.cameraChecks.calls.at(-1).video.deviceId?.exact === 'camera-b');
    await videoReady();
    const oldStopped = await page.evaluate(() => window.cameraChecks.streams.slice(0, -1)
      .every(s => s.getTracks().every(t => t.readyState === 'ended')));
    if (!oldStopped) throw Error('Switch retained the previous device');
    await click('카메라 정지');
    await stopped();
    checks.push('selector switches cameras and releases the previous stream');
    const audio = await page.evaluate(() => window.cameraChecks.calls.some(c => c.audio !== false));
    if (audio || forbiddenRequests.length) throw Error('Unexpected audio capture or HTTP writes');
    checks.push('no audio, image uploads or robot commands');
    return checks;
  } finally {
    await page.evaluate(() => {
      const state = window.cameraChecks;
      state.streams.forEach(s => s.getTracks().forEach(t => t.stop()));
      navigator.mediaDevices.getUserMedia = state.original;
      navigator.mediaDevices.enumerateDevices = state.enumerate;
    });
    page.off('request', watch);
  }
}
