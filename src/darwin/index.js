const path = require('path');
const { app } = require('electron');

// bindings doesn't work with asar, manually resolve path
function loadNativeModule() {
  const moduleName = 'electron_media_service.node';
  const possiblePaths = [];

  // In packaged app
  if (app && app.isPackaged) {
    const unpackedBase = app.getAppPath().replace('app.asar', 'app.asar.unpacked');
    possiblePaths.push(
      path.join(unpackedBase, 'electron-media-service/build/Release', moduleName),
      path.join(unpackedBase, 'electron-media-service/bin', `darwin-${process.arch}-${process.versions.modules}`, moduleName.replace('.node', '.node'))
    );
  }

  // Development paths
  possiblePaths.push(
    path.join(__dirname, '../../build/Release', moduleName),
    path.join(__dirname, '../../bin', `darwin-${process.arch}-${process.versions.modules}`, moduleName.replace('electron_media_service', 'electron-media-service'))
  );

  for (const p of possiblePaths) {
    try {
      return require(p);
    } catch (e) {
      continue;
    }
  }

  // Fallback to bindings
  return require('bindings')(moduleName);
}

const { DarwinMediaService } = loadNativeModule();
const { EventEmitter } = require('events');

class MediaService extends EventEmitter {
  constructor() {
    super();
    this.service = new DarwinMediaService();
    this._started = false;
  }

  _requireStart() {
    if (!this.isStarted()) {
      throw new Error('This method requires the media service be started before calling');
    }
  }

  startService() {
    this._started = true;
    this.service.startService();
    this.service.hook((eventName, arg) => {
      if (arg === -1) {
        this.emit(eventName);
      } else {
        this.emit(eventName, arg * 1000);
      }
    });
  }

  stopService() {
    this._requireStart();
    this._started = false;
    this.service.stopService();
  }

  isStarted() {
    return this._started;
  }

  setMetaData({
    currentTime,
    duration,
    title,
    artist,
    album,
    id,
    state,
    artworkPath,
  }) {
    this._requireStart();
    this.service.setMetaData(title, artist, album, state, id, currentTime / 1000, duration / 1000, artworkPath || null);
  }
}

MediaService.STATES = {
  PLAYING: 'playing',
  PAUSED: 'paused',
  STOPPED: 'stopped',
};

module.exports = MediaService;
