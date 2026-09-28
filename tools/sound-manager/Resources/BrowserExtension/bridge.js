(() => {
  if (globalThis.__soundManagerBridgeAlive?.()) return;
  globalThis.__soundManagerBridgeAlive = () => Boolean(chrome.runtime?.id);

  const VOLUME_EVENT = 'soundmanager:volume';
  const PLAYING_EVENT = 'soundmanager:playing';
  const MEDIA_STATE_EVENTS = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange'];

  let pageScriptPlaying = false;
  let reportedPlaying = null;

  const send = (message) => {
    try {
      return chrome.runtime.sendMessage(message).catch(() => undefined);
    } catch {
      return Promise.resolve(undefined);
    }
  };

  const dispatchVolume = (volume) => {
    document.dispatchEvent(new CustomEvent(VOLUME_EVENT, { detail: volume }));
  };

  // The isolated world sees native media state, so this works even when the page script is an older version.
  const domMediaPlaying = () =>
    Array.from(document.querySelectorAll('audio, video')).some((media) => !media.paused && !media.ended && !media.muted);

  const reportPlaying = () => {
    const playing = pageScriptPlaying || domMediaPlaying();
    if (playing === reportedPlaying) return;
    reportedPlaying = playing;
    send({ type: 'soundmanager:playing', playing });
  };

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== 'soundmanager:setVolume') return false;
    dispatchVolume(message.volume);
    sendResponse({ ok: true });
    return false;
  });

  document.addEventListener(PLAYING_EVENT, (event) => {
    pageScriptPlaying = event.detail === true;
    reportPlaying();
  });
  for (const type of MEDIA_STATE_EVENTS) document.addEventListener(type, reportPlaying, true);
  window.addEventListener('pagehide', () => {
    reportedPlaying = null;
    send({ type: 'soundmanager:playing', playing: false });
  });
  window.addEventListener('pageshow', reportPlaying);

  reportPlaying();
  send({ type: 'soundmanager:getVolume' }).then((response) => {
    if (typeof response?.volume === 'number') dispatchVolume(response.volume);
  });
})();
