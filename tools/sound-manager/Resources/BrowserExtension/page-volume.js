(() => {
  const VOLUME_EVENT = 'soundmanager:volume';
  const PLAYING_EVENT = 'soundmanager:playing';
  const MEDIA_STATE_EVENTS = ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange'];
  const INSTALLED = Symbol.for('soundmanager.installed');
  if (window[INSTALLED]) return;
  window[INSTALLED] = true;

  let tabGain = 1;
  let reportedPlaying = false;

  // <audio>/<video>: the page keeps reading its own volume; the element plays pageVolume * tabGain.
  const volumeDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
  const pageVolumes = new WeakMap();
  const mediaRefs = new Set();

  const track = (element) => {
    if (pageVolumes.has(element)) return;
    pageVolumes.set(element, volumeDescriptor.get.call(element));
    mediaRefs.add(new WeakRef(element));
    for (const type of MEDIA_STATE_EVENTS) element.addEventListener(type, reportPlaying);
  };

  const applyToMedia = (element) => {
    track(element);
    const scaled = pageVolumes.get(element) * tabGain;
    if (Math.abs(volumeDescriptor.get.call(element) - scaled) > 1e-4) volumeDescriptor.set.call(element, scaled);
  };

  Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
    configurable: true,
    enumerable: volumeDescriptor.enumerable,
    get() {
      track(this);
      return pageVolumes.get(this);
    },
    set(value) {
      track(this);
      const volume = Number(value);
      if (!(volume >= 0 && volume <= 1)) {
        volumeDescriptor.set.call(this, value);
        return;
      }
      pageVolumes.set(this, volume);
      volumeDescriptor.set.call(this, volume * tabGain);
    },
  });

  const originalPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    applyToMedia(this);
    return originalPlay.apply(this, args);
  };
  document.addEventListener('play', (event) => {
    if (!(event.target instanceof HTMLMediaElement)) return;
    applyToMedia(event.target);
    reportPlaying();
  }, true);

  // Web Audio: everything routed to a context's destination passes through one gain node per context.
  const originalConnect = AudioNode.prototype.connect;
  const originalDisconnect = AudioNode.prototype.disconnect;
  const masterGains = new WeakMap();
  const masterRefs = new Set();

  const isLiveDestination = (node) =>
    node instanceof AudioDestinationNode && !(node.context instanceof OfflineAudioContext);

  const masterFor = (context) => {
    let gain = masterGains.get(context);
    if (!gain) {
      gain = context.createGain();
      gain.gain.value = tabGain;
      originalConnect.call(gain, context.destination);
      masterGains.set(context, gain);
      masterRefs.add(new WeakRef(gain));
      context.addEventListener('statechange', reportPlaying);
      queueMicrotask(reportPlaying);
    }
    return gain;
  };

  AudioNode.prototype.connect = function (destination, ...rest) {
    if (isLiveDestination(destination)) {
      const master = masterFor(destination.context);
      if (this !== master) {
        originalConnect.call(this, master, ...rest);
        return destination;
      }
    }
    return originalConnect.call(this, destination, ...rest);
  };

  AudioNode.prototype.disconnect = function (destination, ...rest) {
    if (isLiveDestination(destination) && this !== masterGains.get(destination.context)) {
      return originalDisconnect.call(this, masterFor(destination.context), ...rest);
    }
    return originalDisconnect.call(this, destination, ...rest);
  };

  const applyGain = (gain) => {
    tabGain = gain;
    document.querySelectorAll('audio, video').forEach(applyToMedia);
    for (const ref of mediaRefs) {
      const element = ref.deref();
      if (element) applyToMedia(element); else mediaRefs.delete(ref);
    }
    for (const ref of masterRefs) {
      const node = ref.deref();
      if (node) node.gain.setTargetAtTime(gain, node.context.currentTime, 0.015); else masterRefs.delete(ref);
    }
    reportPlaying();
  };

  // "Playing" means the page is producing audio before the tab gain, so a tab at 0% still counts.
  function reportPlaying() {
    const playing = isProducingAudio();
    if (playing === reportedPlaying) return;
    reportedPlaying = playing;
    document.dispatchEvent(new CustomEvent(PLAYING_EVENT, { detail: playing }));
  }

  function isProducingAudio() {
    for (const ref of mediaRefs) {
      const element = ref.deref();
      if (!element) {
        mediaRefs.delete(ref);
      } else if (!element.paused && !element.ended && !element.muted && pageVolumes.get(element) > 0) {
        return true;
      }
    }
    for (const ref of masterRefs) {
      if (ref.deref()?.context.state === 'running') return true;
    }
    return false;
  }

  window.addEventListener('pagehide', () => {
    reportedPlaying = false;
    document.dispatchEvent(new CustomEvent(PLAYING_EVENT, { detail: false }));
  });
  window.addEventListener('pageshow', reportPlaying);

  document.addEventListener(VOLUME_EVENT, (event) => {
    const gain = Number(event.detail);
    if (gain >= 0 && gain <= 1) applyGain(gain);
  });
})();
