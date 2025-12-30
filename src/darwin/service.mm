#include "module.h"
#include "nan.h"
#import <AppKit/AppKit.h>
#include <queue>
#include <mutex>

// Thread-safe event queue
struct MediaEvent {
  std::string name;
  int details;
};

static std::queue<MediaEvent> eventQueue;
static std::mutex eventMutex;
static uv_async_t asyncHandle;
static Nan::Callback* persistentCallback = nullptr;  // Pointer to avoid static destructor crash
static bool asyncInitialized = false;

// Called on Node.js thread when uv_async_send is triggered
static void AsyncCallback(uv_async_t* handle) {
  Nan::HandleScope scope;

  std::lock_guard<std::mutex> lock(eventMutex);
  while (!eventQueue.empty()) {
    MediaEvent event = eventQueue.front();
    eventQueue.pop();

    if (persistentCallback) {
      v8::Local<v8::Value> argv[2] = {
        Nan::New(event.name).ToLocalChecked(),
        Nan::New(event.details)
      };

      persistentCallback->Call(2, argv);
    }
  }
}

// Thread-safe emit function
static void QueueEvent(const std::string& eventName, int details) {
  {
    std::lock_guard<std::mutex> lock(eventMutex);
    eventQueue.push({eventName, details});
  }
  if (asyncInitialized) {
    uv_async_send(&asyncHandle);
  }
}

@implementation NativeMediaController
  DarwinMediaService* _service;

- (void)associateService:(DarwinMediaService*)service {
  _service = service;
}

- (MPRemoteCommandHandlerStatus)remotePlay {
  QueueEvent("play", -1);
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remotePause {
  QueueEvent("pause", -1);
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remoteTogglePlayPause {
  QueueEvent("playPause", -1);
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remoteNext {
  QueueEvent("next", -1);
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remotePrev {
  QueueEvent("previous", -1);
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remoteChangePlaybackPosition:(MPChangePlaybackPositionCommandEvent*)event {
  QueueEvent("seek", (int)event.positionTime);
  return MPRemoteCommandHandlerStatusSuccess;
}

@end

NAN_METHOD(DarwinMediaService::Hook) {
  Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  v8::Local<v8::Function> function = v8::Local<v8::Function>::Cast(info[0]);

  // Allocate callback if needed
  if (!persistentCallback) {
    persistentCallback = new Nan::Callback();
  }
  persistentCallback->SetFunction(function);

  // Initialize async handle on first hook
  if (!asyncInitialized) {
    uv_async_init(uv_default_loop(), &asyncHandle, AsyncCallback);
    asyncInitialized = true;
  }
}

void DarwinMediaService::Emit(std::string eventName) {
  QueueEvent(eventName, -1);
}

void DarwinMediaService::EmitWithInt(std::string eventName, int details) {
  QueueEvent(eventName, details);
}

NAN_METHOD(DarwinMediaService::New) {
  DarwinMediaService *service = new DarwinMediaService();
  service->Wrap(info.This());
  info.GetReturnValue().Set(info.This());
}

NAN_METHOD(DarwinMediaService::StartService) {
  DarwinMediaService *self = Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  NativeMediaController* controller = [[NativeMediaController alloc] init];
  [controller associateService:self];

  MPRemoteCommandCenter *remoteCommandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  [remoteCommandCenter playCommand].enabled = true;
  [remoteCommandCenter pauseCommand].enabled = true;
  [remoteCommandCenter togglePlayPauseCommand].enabled = true;
  [remoteCommandCenter changePlaybackPositionCommand].enabled = true;
  [remoteCommandCenter nextTrackCommand].enabled = true;
  [remoteCommandCenter previousTrackCommand].enabled = true;

  [[remoteCommandCenter playCommand] addTarget:controller action:@selector(remotePlay)];
  [[remoteCommandCenter pauseCommand] addTarget:controller action:@selector(remotePause)];
  [[remoteCommandCenter togglePlayPauseCommand] addTarget:controller action:@selector(remoteTogglePlayPause)];
  [[remoteCommandCenter changePlaybackPositionCommand] addTarget:controller action:@selector(remoteChangePlaybackPosition:)];
  [[remoteCommandCenter nextTrackCommand] addTarget:controller action:@selector(remoteNext)];
  [[remoteCommandCenter previousTrackCommand] addTarget:controller action:@selector(remotePrev)];
}

NAN_METHOD(DarwinMediaService::StopService) {
  Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  MPRemoteCommandCenter *remoteCommandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  [remoteCommandCenter playCommand].enabled = false;
  [remoteCommandCenter pauseCommand].enabled = false;
  [remoteCommandCenter togglePlayPauseCommand].enabled = false;
  [remoteCommandCenter changePlaybackPositionCommand].enabled = false;

  // Clean up callback while V8 is still alive
  // Note: Don't call uv_close here - it's async and V8 may shut down before it completes causing a crash
  if (persistentCallback) {
    persistentCallback->Reset();
    delete persistentCallback;
    persistentCallback = nullptr;
  }
  asyncInitialized = false;

  // Clear any pending events
  {
    std::lock_guard<std::mutex> lock(eventMutex);
    while (!eventQueue.empty()) {
      eventQueue.pop();
    }
  }
}

NAN_METHOD(DarwinMediaService::SetMetaData) {
  Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  std::string songTitle = *Nan::Utf8String(info[0]);
  std::string songArtist = *Nan::Utf8String(info[1]);
  std::string songAlbum = *Nan::Utf8String(info[2]);
  std::string songState = *Nan::Utf8String(info[3]);

  v8::Local<v8::Context> context = info.GetIsolate()->GetCurrentContext();
  unsigned int songID = info[4]->Uint32Value(context).FromJust();
  unsigned int currentTime = info[5]->Uint32Value(context).FromJust();
  unsigned int duration = info[6]->Uint32Value(context).FromJust();

  // Optional artwork path (info[7])
  std::string artworkPath = "";
  if (info.Length() > 7 && !info[7]->IsNullOrUndefined()) {
    artworkPath = *Nan::Utf8String(info[7]);
  }

  NSMutableDictionary *songInfo = [[NSMutableDictionary alloc] init];
  [songInfo setObject:[NSString stringWithUTF8String:songTitle.c_str()] forKey:MPMediaItemPropertyTitle];
  [songInfo setObject:[NSString stringWithUTF8String:songArtist.c_str()] forKey:MPMediaItemPropertyArtist];
  [songInfo setObject:[NSString stringWithUTF8String:songAlbum.c_str()] forKey:MPMediaItemPropertyAlbumTitle];
  [songInfo setObject:[NSNumber numberWithFloat:currentTime] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
  [songInfo setObject:[NSNumber numberWithFloat:duration] forKey:MPMediaItemPropertyPlaybackDuration];
  [songInfo setObject:[NSNumber numberWithFloat:songID] forKey:MPMediaItemPropertyPersistentID];

  // Add artwork if path is provided
  if (!artworkPath.empty()) {
    NSString *path = [NSString stringWithUTF8String:artworkPath.c_str()];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (image) {
      MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^NSImage * _Nonnull(CGSize size) {
        return image;
      }];
      [songInfo setObject:artwork forKey:MPMediaItemPropertyArtwork];
    }
  }

  if (songState == "playing") {
    [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePlaying;
  } else if (songState == "paused") {
    [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePaused;
  } else {
    [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStateStopped;
  }

  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:songInfo];
}
