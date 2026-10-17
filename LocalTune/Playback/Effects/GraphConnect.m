#import "GraphConnect.h"

BOOL LTCatchAudioEngineConnect(
    AVAudioEngine *engine,
    AVAudioNode *source,
    AVAudioNode *destination,
    AVAudioFormat *format,
    NSError **error
) {
    @try {
        [engine connect:source to:destination format:format];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"LocalTune.EffectsGraph"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"connect failed"
            }];
        }
        return NO;
    }
}
