const APP_URL = 'ws://127.0.0.1:47821';
const RECONNECT_ALARM = 'soundmanager-reconnect';
const KEEPALIVE_MS = 20000;
const TAB_EVENT_KEYS = ['audible', 'mutedInfo', 'title', 'favIconUrl', 'url'];

let socket = null;
let keepAliveTimer = null;
let tabsTimer = null;
const volumes = new Map();
const frameStates = new Map();

const stateReady = chrome.storage.session.get(['volumes', 'frames']).then(({ volumes: storedVolumes, frames: storedFrames }) => {
  for (const [tabId, volume] of Object.entries(storedVolumes ?? {})) volumes.set(Number(tabId), volume);
  for (const [tabId, frames] of Object.entries(storedFrames ?? {})) {
    frameStates.set(Number(tabId), new Map(Object.entries(frames).map(([frameId, playing]) => [Number(frameId), playing])));
  }
});

const persistVolumes = () => chrome.storage.session.set({ volumes: Object.fromEntries(volumes) });

const persistFrames = () => chrome.storage.session.set({
  frames: Object.fromEntries([...frameStates].map(([tabId, frames]) => [tabId, Object.fromEntries(frames)])),
});

function setFramePlaying(tabId, frameId, playing) {
  const frames = frameStates.get(tabId) ?? new Map();
  if (frames.get(frameId) === playing) return false;
  frames.set(frameId, playing);
  frameStates.set(tabId, frames);
  persistFrames();
  return true;
}

// null means no frame of the tab has reported yet, so the app cannot tell playing from paused.
function tabPlaying(tabId) {
  const frames = frameStates.get(tabId);
  return frames ? [...frames.values()].some(Boolean) : null;
}

const isOpen = () => socket?.readyState === WebSocket.OPEN;

const send = (message) => {
  if (isOpen()) socket.send(JSON.stringify(message));
};

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  const ws = new WebSocket(APP_URL);
  socket = ws;
  ws.onopen = () => {
    send({ type: 'hello', brands: navigator.userAgentData?.brands?.map((entry) => entry.brand) ?? [] });
    sendTabs();
    keepAliveTimer = setInterval(() => send({ type: 'ping' }), KEEPALIVE_MS);
  };
  ws.onmessage = (event) => {
    try {
      handleCommand(JSON.parse(event.data));
    } catch (error) {
      console.warn('Sound Manager: comando inválido', error);
    }
  };
  ws.onclose = () => {
    clearInterval(keepAliveTimer);
    if (socket === ws) socket = null;
  };
}

const scheduleTabs = () => {
  clearTimeout(tabsTimer);
  tabsTimer = setTimeout(sendTabs, 150);
};

async function sendTabs() {
  if (!isOpen()) return;
  await stateReady;
  const tabs = await chrome.tabs.query({});
  send({
    type: 'tabs',
    tabs: tabs.map((tab) => {
      const url = tab.url || tab.pendingUrl || '';
      return {
        id: tab.id,
        windowId: tab.windowId,
        title: tab.title ?? '',
        url,
        favIconUrl: tab.favIconUrl || null,
        audible: Boolean(tab.audible),
        muted: Boolean(tab.mutedInfo?.muted),
        volume: volumes.get(tab.id) ?? 1,
        playing: tabPlaying(tab.id),
        volumeSupported: /^(https?|file):/.test(url),
      };
    }),
  });
}

async function handleCommand(message) {
  if (message.type === 'setMuted') {
    await chrome.tabs.update(message.tabId, { muted: Boolean(message.muted) });
  } else if (message.type === 'setVolume') {
    await stateReady;
    const volume = Math.min(1, Math.max(0, Number(message.volume)));
    if (volume === 1) volumes.delete(message.tabId); else volumes.set(message.tabId, volume);
    persistVolumes();
    await deliverVolume(message.tabId, volume);
  }
  scheduleTabs();
}

async function deliverVolume(tabId, volume) {
  const message = { type: 'soundmanager:setVolume', volume };
  try {
    await chrome.tabs.sendMessage(tabId, message);
  } catch {
    try {
      await injectInto(tabId);
      await chrome.tabs.sendMessage(tabId, message);
    } catch (error) {
      console.warn(`Sound Manager: aba ${tabId} não aceita controle de volume`, error);
    }
  }
}

async function injectInto(tabId) {
  const target = { tabId, allFrames: true };
  await chrome.scripting.executeScript({ target, files: ['page-volume.js'], world: 'MAIN', injectImmediately: true });
  await chrome.scripting.executeScript({ target, files: ['bridge.js'], injectImmediately: true });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!sender.tab) return false;
  if (message?.type === 'soundmanager:getVolume') {
    stateReady.then(() => sendResponse({ volume: volumes.get(sender.tab.id) ?? 1 }));
    return true;
  }
  if (message?.type === 'soundmanager:playing') {
    stateReady.then(() => {
      if (setFramePlaying(sender.tab.id, sender.frameId, message.playing === true)) scheduleTabs();
    });
  }
  return false;
});

chrome.tabs.onCreated.addListener(scheduleTabs);
chrome.tabs.onAttached.addListener(scheduleTabs);
chrome.tabs.onDetached.addListener(scheduleTabs);
chrome.tabs.onUpdated.addListener((_tabId, changeInfo) => {
  if (TAB_EVENT_KEYS.some((key) => key in changeInfo)) scheduleTabs();
});
chrome.tabs.onRemoved.addListener((tabId) => {
  if (volumes.delete(tabId)) persistVolumes();
  if (frameStates.delete(tabId)) persistFrames();
  scheduleTabs();
});
chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  if (volumes.has(removedTabId)) {
    volumes.set(addedTabId, volumes.get(removedTabId));
    volumes.delete(removedTabId);
    persistVolumes();
  }
  if (frameStates.delete(removedTabId)) persistFrames();
  scheduleTabs();
});

chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({ url: ['http://*/*', 'https://*/*', 'file:///*'] });
  for (const tab of tabs) {
    if (!tab.discarded) injectInto(tab.id).catch(() => {});
  }
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connect();
});
chrome.alarms.get(RECONNECT_ALARM).then((alarm) => {
  if (!alarm) chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
});

connect();
