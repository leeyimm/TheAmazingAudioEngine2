//
//  AEAudioFilePlayerModule.m
//  The Amazing Audio Engine
//
//  Created by Michael Tyson on 30/03/2016.
//
//  Contributions by Ryan King and Jeremy Huff of Hello World Engineering, Inc on 7/15/15.
//      Copyright (c) 2015 Hello World Engineering, Inc. All rights reserved.
//  Contributions by Ryan Holmes
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AEAudioFilePlayerModule.h"
#import "AEUtilities.h"
#import "AETypes.h"
#import "AEAudioBufferListUtilities.h"
#import "AEDSPUtilities.h"

static const UInt32 kMicrofadeLength = 32;

@interface AEAudioFilePlayerModule () {
    AudioFileID _audioFile;
    double      _fileSampleRate;
    int         _channels;
    int         _usableChannels;
    UInt32      _lengthInFrames;
    AESeconds   _regionDuration;
    AESeconds   _regionStartTime;
    BOOL        _stopEventScheduled;
    BOOL        _sequenceScheduled;
    AEHostTicks _startTime;
    AEHostTicks _anchorTime;
    UInt32      _playheadOffset;
    double      _playhead;
    UInt32      _remainingMicrofadeInFrames;
    UInt32      _remainingMicrofadeOutFrames;
}
@property (nonatomic, strong, readwrite) NSURL * url;
@property (nonatomic, strong) NSTimer * pollTimer;
@property (nonatomic, copy) void(^beginBlock)();
@end

@interface AEAudioFilePlayerModuleWeakProxy : NSProxy
@property (nonatomic, weak) id target;
@end

@implementation AEAudioFilePlayerModule

- (instancetype)initWithRenderer:(AERenderer *)renderer URL:(NSURL *)url error:(NSError *__autoreleasing *)error {
    if ( !(self = [super initWithRenderer:renderer componentDescription:
                   AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple,
                                                   kAudioUnitType_Generator,
                                                   kAudioUnitSubType_AudioFilePlayer)]) ) return nil;
    
    if ( ![self loadAudioFileWithURL:url error:error] ) {
        return nil;
    }
    
    if ( ![self setup] ) return nil;
    [self initialize];
    
    self.processFunction = AEAudioFilePlayerModuleProcess;
    
    return self;
}

- (void)dealloc {
    if ( self.pollTimer ) {
        [self.pollTimer invalidate];
    }
    if ( _audioFile ) {
        AudioFileClose(_audioFile);
    }
}

- (void)setCompletionBlock:(void (^)())completionBlock {
    _completionBlock = completionBlock;
    
    if ( _completionBlock && !self.pollTimer && !self.loop ) {
        [self schedulePollTimer];
    } else if ( !_completionBlock && !self.beginBlock && self.pollTimer ) {
        [self.pollTimer invalidate];
        self.pollTimer = nil;
    }
}

- (void)playAtTime:(AEHostTicks)time {
    [self playAtTime:time beginBlock:nil];
}

- (void)playAtTime:(AEHostTicks)time beginBlock:(void(^)())block {
    _startTime = time;
    if ( !_playing ) {
        self.beginBlock = block;
        _anchorTime = 0;
        _playing = YES;
        
        if ( (self.beginBlock || (self.completionBlock && !self.loop)) && !self.pollTimer ) {
            [self schedulePollTimer];
        }
        
        if ( !_sequenceScheduled ) {
            [self schedulePlayRegionFromPosition:_playhead];
        }
    }
}

- (void)stop {
    self.beginBlock = nil;
    if ( !self.pollTimer ) {
        [self schedulePollTimer];
    }
    _remainingMicrofadeOutFrames = kMicrofadeLength;
}

- (AESeconds)duration {
    return (double)_lengthInFrames / (double)_fileSampleRate;
}

- (AESeconds)currentTime {
    return AEAudioFilePlayerModuleGetPlayhead(self, AECurrentTimeInHostTicks());
}

- (void)setCurrentTime:(AESeconds)currentTime {
    [self schedulePlayRegionFromPosition:
        (UInt32)(self.regionStartTime * _fileSampleRate)
        + ((UInt32)((currentTime - self.regionStartTime) * _fileSampleRate) % (UInt32)(self.regionDuration * _fileSampleRate))];
}

- (void)setRegionDuration:(NSTimeInterval)regionDuration {
    if ( fabs(_regionDuration - regionDuration) < DBL_EPSILON ) return;
    
    if ( regionDuration < 0 ) {
        regionDuration = 0;
    }
    
    if ( regionDuration > (_lengthInFrames / _fileSampleRate) - _regionStartTime ) {
        regionDuration = (_lengthInFrames / _fileSampleRate) - _regionStartTime;
    }
    
    _regionDuration = regionDuration;
    
    [self schedulePlayRegionFromPosition:_playhead];
}

- (void)setRegionStartTime:(NSTimeInterval)regionStartTime {
    if ( fabs(_regionStartTime - regionStartTime) < DBL_EPSILON ) return;
    
    if ( regionStartTime < 0 ) {
        regionStartTime = 0;
    }
    
    if ( regionStartTime > _lengthInFrames / _fileSampleRate ) {
        regionStartTime = _lengthInFrames / _fileSampleRate;
    }
    if ( _regionDuration > (_lengthInFrames / _fileSampleRate) - regionStartTime ) {
        _regionDuration = (_lengthInFrames / _fileSampleRate) - regionStartTime;
    }
    
    _regionStartTime = regionStartTime;
    
    [self schedulePlayRegionFromPosition:round(_regionStartTime * _fileSampleRate)];
}

- (void)setLoop:(BOOL)loop {
    _loop = loop;
    
    if ( !_loop && self.completionBlock && !self.pollTimer ) {
        [self schedulePollTimer];
    }
}

AESeconds AEAudioFilePlayerModuleGetPlayhead(__unsafe_unretained AEAudioFilePlayerModule * THIS, AEHostTicks time) {
    if ( !THIS->_playing || !THIS->_anchorTime ) {
        return THIS->_playhead / THIS->_fileSampleRate;
    }
    
    AESeconds offset = THIS->_playhead / THIS->_fileSampleRate;
    AESeconds timeline = (time > THIS->_anchorTime ? AESecondsFromHostTicks(time - THIS->_anchorTime) :
                          -AESecondsFromHostTicks(THIS->_anchorTime - time)) + offset;
    if ( !THIS->_loop ) {
        return MIN(timeline, THIS->_regionDuration);
    } else {
        return fmod(timeline, THIS->_regionDuration);
    }
}

BOOL AEAudioFilePlayerModuleGetPlaying(__unsafe_unretained AEAudioFilePlayerModule * THIS) {
    return THIS->_playing;
}

- (void)schedulePollTimer {
    AEAudioFilePlayerModuleWeakProxy * proxy = [AEAudioFilePlayerModuleWeakProxy alloc];
    proxy.target = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:proxy selector:@selector(pollTimeout)
                                                                userInfo:nil repeats:YES];
}

- (void)pollTimeout {
    if ( self.beginBlock && _anchorTime != 0 ) {
        self.beginBlock();
        self.beginBlock = nil;
        if ( !self.completionBlock || self.loop ) {
            [self.pollTimer invalidate];
            self.pollTimer = nil;
        }
    }
    
    if ( _stopEventScheduled ) {
        _stopEventScheduled = NO;
        AECheckOSStatus(AudioUnitReset(self.audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
        _sequenceScheduled = NO;
        _playing = NO;
        if ( self.completionBlock ) self.completionBlock();
        [self.pollTimer invalidate];
        self.pollTimer = nil;
    }
}

- (BOOL)loadAudioFileWithURL:(NSURL*)url error:(NSError**)error {
    OSStatus result;
    
    // Open the file
    result = AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, 0, &_audioFile);
    if ( !AECheckOSStatus(result, "AudioFileOpenURL") ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't open the audio file", @"")}];
        return NO;
    }
    
    // Get the file data format
    AudioStreamBasicDescription fileDescription;
    UInt32 size = sizeof(fileDescription);
    result = AudioFileGetProperty(_audioFile, kAudioFilePropertyDataFormat, &size, &fileDescription);
    if ( !AECheckOSStatus(result, "AudioFileGetProperty(kAudioFilePropertyDataFormat)") ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
        AudioFileClose(_audioFile);
        _audioFile = NULL;
        return NO;
    }
    
    // Determine length in frames (in original file's sample rate)
    AudioFilePacketTableInfo packetInfo;
    size = sizeof(packetInfo);
    result = AudioFileGetProperty(_audioFile, kAudioFilePropertyPacketTableInfo, &size, &packetInfo);
    if ( result != noErr ) {
        size = 0;
    }
    
    UInt64 fileLengthInFrames;
    if ( size > 0 ) {
        fileLengthInFrames = packetInfo.mNumberValidFrames;
    } else {
        UInt64 packetCount;
        size = sizeof(packetCount);
        result = AudioFileGetProperty(_audioFile, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount);
        if ( !AECheckOSStatus(result, "AudioFileGetProperty(kAudioFilePropertyAudioDataPacketCount)") ) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result
                                     userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Couldn't read the audio file", @"")}];
            AudioFileClose(_audioFile);
            _audioFile = NULL;
            return NO;
        }
        fileLengthInFrames = packetCount * fileDescription.mFramesPerPacket;
    }
    
    if ( fileLengthInFrames == 0 ) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-50
                                 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"This audio file is empty", @"")}];
        AudioFileClose(_audioFile);
        _audioFile = NULL;
        return NO;
    }
    
    _fileSampleRate = fileDescription.mSampleRate;
    _channels = fileDescription.mChannelsPerFrame;
    _usableChannels = MIN(_channels, AEBufferStackGetMaximumChannelsPerBuffer(self.renderer.stack));
    _lengthInFrames = (UInt32)fileLengthInFrames;
    _regionStartTime = 0;
    _regionDuration = (double)_lengthInFrames / _fileSampleRate;
    self.url = url;
    
    return YES;
}

- (BOOL)setup {
    if ( !_audioFile ) {
        // Defer setup until loaded
        return YES;
    }
    
    return [super setup];
}

- (void)initialize {
    if ( !_audioFile ) {
        // Defer initialization until loaded
        return;
    }
    
    [super initialize];
    [self schedulePlayRegionFromPosition:_playhead];
}

- (int)numberOfChannels {
    return _channels;
}

- (void)schedulePlayRegionFromPosition:(UInt32)position {
    // Note: "position" is in frames, in the input file's sample rate
    AudioUnit audioUnit = self.audioUnit;
    if ( !audioUnit || !_audioFile ) {
        return;
    }
    
    // Make sure region is valid
    if (self.regionStartTime > self.duration) {
        _regionStartTime = self.duration;
    }
    if (self.regionStartTime + self.regionDuration > self.duration) {
        _regionDuration = self.duration - self.regionStartTime;
    }
    
    UInt32 start = round(self.regionStartTime * _fileSampleRate);
    UInt32 end = round((self.regionStartTime + self.regionDuration) * _fileSampleRate);
    position = MIN(MAX(start, position), end);
    
    double sourceToOutputSampleRateScale = self.renderer.sampleRate / _fileSampleRate;
    
    // Reset the unit, to clear prior schedules
    AECheckOSStatus(AudioUnitReset(audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
    
    // Set the file to play
    UInt32 size = sizeof(_audioFile);
    OSStatus result = AudioUnitSetProperty(self.audioUnit, kAudioUnitProperty_ScheduledFileIDs, kAudioUnitScope_Global,
                                           0, &_audioFile, size);
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileIDs)");
    
    Float64 mainRegionStartTime = 0;
    if ( position > start ) {
        // Schedule the remaining part of the audio
        UInt32 framesToPlay = (self.regionDuration * _fileSampleRate) - position - (self.regionStartTime * _fileSampleRate);
        ScheduledAudioFileRegion region = {
            .mAudioFile = _audioFile,
            .mStartFrame = position,
            .mFramesToPlay = framesToPlay
        };
        OSStatus result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global,
                                               0, &region, sizeof(region));
        AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
        
        mainRegionStartTime = (double)framesToPlay * sourceToOutputSampleRateScale;
    }
    
    // Set the main file region to play
    ScheduledAudioFileRegion region = {
        .mTimeStamp = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = mainRegionStartTime },
        .mAudioFile = _audioFile,
        .mStartFrame = round(_regionStartTime * _fileSampleRate),
        // Always loop the unit, even if we're not actually looping, to avoid rescheduling when switching loop mode.
        .mLoopCount = (UInt32)-1,
        .mFramesToPlay = round(_regionDuration * _fileSampleRate)
    };
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFileRegion, kAudioUnitScope_Global, 0,
                                  &region, sizeof(region));
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFileRegion)");
    
    // Prime the player
    UInt32 primeFrames = 0;
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduledFilePrime, kAudioUnitScope_Global, 0, &primeFrames,
                                  sizeof(primeFrames));
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduledFilePrime)");
    
    // Set the start time
    AudioTimeStamp startTime = { .mFlags = kAudioTimeStampSampleTimeValid, .mSampleTime = -1 /* ASAP */ };
    result = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduleStartTimeStamp, kAudioUnitScope_Global, 0,
                                  &startTime, sizeof(startTime));
    AECheckOSStatus(result, "AudioUnitSetProperty(kAudioUnitProperty_ScheduleStartTimeStamp)");
    
    _playhead = position;
    _playheadOffset = position - start;
    _anchorTime = 0;
    _sequenceScheduled = YES;
    _remainingMicrofadeInFrames = kMicrofadeLength;
}

static void AEAudioFilePlayerModuleProcess(__unsafe_unretained AEAudioFilePlayerModule * THIS,
                                           const AERenderContext * _Nonnull context) {
    
    const AudioBufferList * abl = AEBufferStackPushWithChannels(context->stack, 1, THIS->_usableChannels);
    if ( !abl ) return;
    
    if ( !THIS->_playing ) {
        AEAudioBufferListSilence(abl, AEAudioDescription, 0, context->frames);
        return;
    }
    
    AudioUnit audioUnit = AEAudioUnitModuleGetAudioUnit(THIS);
    AEHostTicks startTime = THIS->_startTime;
    double playhead = THIS->_playhead;
    
    // Check start time
    AEHostTicks hostTimeAtBufferEnd
        = context->timestamp->mHostTime + AEHostTicksFromSeconds((double)context->frames / context->sampleRate);
    if ( startTime && startTime > hostTimeAtBufferEnd ) {
        // Start time not yet reached: emit silence
        AEAudioBufferListSilence(abl, AEAudioDescription, 0, context->frames);
        return;
        
    } else if ( startTime && startTime < context->timestamp->mHostTime ) {
        // Start time is in the past - we need to skip some frames
        AEHostTicks skipTime = context->timestamp->mHostTime - startTime;
        UInt32 skipFrames = round(AESecondsFromHostTicks(skipTime) * context->sampleRate);
        playhead += AESecondsFromHostTicks(skipTime) * THIS->_fileSampleRate;
        AudioTimeStamp timestamp = {
            .mFlags = kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid,
            .mSampleTime = context->timestamp->mSampleTime - skipFrames,
            .mHostTime = startTime
        };
        
        AEAudioBufferListCopyOnStack(scratch, abl, 0);
        while ( skipFrames > 0 ) {
            UInt32 framesToSkip = MIN(skipFrames, context->frames);
            AudioUnitRenderActionFlags flags = 0;
            AEAudioBufferListSetLength(scratch, AEAudioDescription, framesToSkip);
            OSStatus result = AudioUnitRender(audioUnit, &flags, &timestamp, 0, framesToSkip, scratch);
            if ( !AECheckOSStatus(result, "AudioUnitRender") ) {
                AEAudioBufferListSilence(abl, AEAudioDescription, 0, context->frames);
                return;
            }
            
            skipFrames -= framesToSkip;
            timestamp.mSampleTime += framesToSkip;
            timestamp.mHostTime += AEHostTicksFromSeconds(round((double)framesToSkip / context->sampleRate));
        }
    }
    
    THIS->_startTime = 0;
    
    // Prepare buffer
    UInt32 frames = context->frames;
    UInt32 silentFrames = startTime && startTime > context->timestamp->mHostTime
        ? round(AESecondsFromHostTicks(startTime - context->timestamp->mHostTime) * context->sampleRate) : 0;
    AEAudioBufferListCopyOnStack(scratchAudioBufferList, abl, silentFrames * AEAudioDescription.mBytesPerFrame);
    AudioTimeStamp adjustedTime = *context->timestamp;
    
    if ( silentFrames > 0 ) {
        // Start time is offset into this buffer - silence beginning of buffer
        for ( int i=0; i<abl->mNumberBuffers; i++) {
            memset(abl->mBuffers[i].mData, 0, silentFrames * AEAudioDescription.mBytesPerFrame);
        }
        
        // Point buffer list to remaining frames
        abl = scratchAudioBufferList;
        frames -= silentFrames;
        adjustedTime.mHostTime = startTime;
        adjustedTime.mSampleTime += silentFrames;
    }
    
    // Render
    AudioUnitRenderActionFlags flags = 0;
    AEAudioBufferListCopyOnStack(mutableAbl, abl, 0);
    OSStatus result = AudioUnitRender(audioUnit, &flags, context->timestamp, 0, frames, mutableAbl);
    if ( !AECheckOSStatus(result, "AudioUnitRender") ) {
        AEAudioBufferListSilence(abl, AEAudioDescription, 0, context->frames);
        return;
    }
    
    // Examine playhead
    UInt32 playheadInOutputRate = round(playhead * (context->sampleRate / THIS->_fileSampleRate));
    UInt32 regionLength = round(THIS->_regionDuration * context->sampleRate);
    UInt32 regionStartTime = round(THIS->_regionStartTime * context->sampleRate);
    UInt32 playheadInRegion = playheadInOutputRate - regionStartTime;
    UInt32 playheadInRegionAtBufferEnd = playheadInRegion + frames;
    
    BOOL stopped = NO;
    if ( THIS->_remainingMicrofadeInFrames > 0 ) {
        // Fade in
        UInt32 microfadeFrames = MIN(THIS->_remainingMicrofadeInFrames, frames);
        float start = 1.0 - (float)THIS->_remainingMicrofadeInFrames / (float)kMicrofadeLength;
        float step = 1.0 / (double)kMicrofadeLength;
        AEDSPApplyRamp(abl, &start, step, microfadeFrames);
        THIS->_remainingMicrofadeInFrames -= microfadeFrames;
        
    } else if ( THIS->_remainingMicrofadeOutFrames > 0 ) {
        // Fade out (stopped)
        UInt32 microfadeFrames = MIN(THIS->_remainingMicrofadeOutFrames, frames);
        float start = (float)THIS->_remainingMicrofadeOutFrames / (float)kMicrofadeLength;
        float step = -1.0 / (double)kMicrofadeLength;
        AEDSPApplyRamp(abl, &start, step, microfadeFrames);
        THIS->_remainingMicrofadeOutFrames -= microfadeFrames;
        if ( THIS->_remainingMicrofadeOutFrames == 0 ) {
            // Silence rest of buffer and stop
            for ( int i=0; i<abl->mNumberBuffers; i++) {
                // Silence the rest of the buffer past the end
                memset((char*)abl->mBuffers[i].mData + (AEAudioDescription.mBytesPerFrame * microfadeFrames), 0,
                       (AEAudioDescription.mBytesPerFrame * (frames - microfadeFrames)));
            }
            stopped = YES;
        }
    } else if ( !THIS->_loop && playheadInRegionAtBufferEnd >= regionLength-kMicrofadeLength ) {
        // Fade out (ended)
        UInt32 offset = MIN(regionLength-kMicrofadeLength - playheadInRegion, frames);
        UInt32 microfadeFrames = MIN(playheadInRegionAtBufferEnd - regionLength-kMicrofadeLength, kMicrofadeLength);
        microfadeFrames = MIN(microfadeFrames, frames);
        float start = MIN(playheadInRegionAtBufferEnd - regionLength-kMicrofadeLength, kMicrofadeLength) / kMicrofadeLength;
        float step = -1.0 / (double)kMicrofadeLength;
        AEAudioBufferListCopyOnStack(offsetAbl, abl, offset * AEAudioDescription.mBytesPerFrame);
        AEDSPApplyRamp(offsetAbl, &start, step, microfadeFrames);
       
        if ( playheadInRegionAtBufferEnd >= regionLength ) {
            UInt32 finalFrames = MIN(regionLength - playheadInRegion, frames);
            for ( int i=0; i<abl->mNumberBuffers; i++) {
                // Silence the rest of the buffer past the end
                memset((char*)abl->mBuffers[i].mData + (AEAudioDescription.mBytesPerFrame * finalFrames), 0,
                       (AEAudioDescription.mBytesPerFrame * (frames - finalFrames)));
            }
            stopped = YES;
        }
    }
    
    if ( stopped ) {
        // Reset the unit, and cease playback
        AECheckOSStatus(AudioUnitReset(audioUnit, kAudioUnitScope_Global, 0), "AudioUnitReset");
        THIS->_playhead = round(THIS->_regionStartTime * THIS->_fileSampleRate);
        THIS->_sequenceScheduled = NO;
        THIS->_stopEventScheduled = YES;
        THIS->_playing = NO;
    } else {
        // Update the playhead
        AudioTimeStamp playTime = {};
        UInt32 size = sizeof(playTime);
        AECheckOSStatus(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_CurrentPlayTime, kAudioUnitScope_Global,
                                             0, &playTime, &size), "kAudioUnitProperty_CurrentPlayTime");
        double regionStartTimeAtFileRate = THIS->_regionStartTime * THIS->_fileSampleRate;
        double regionLengthAtFileRate = THIS->_regionDuration * THIS->_fileSampleRate;
        THIS->_playhead = regionStartTimeAtFileRate +
            fmod(THIS->_playheadOffset + playTime.mSampleTime * (THIS->_fileSampleRate / context->sampleRate),
                 regionLengthAtFileRate);
        THIS->_anchorTime = hostTimeAtBufferEnd;
    }
}

@end

@implementation AEAudioFilePlayerModuleWeakProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_target methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation setTarget:_target];
    [invocation invoke];
}
@end
