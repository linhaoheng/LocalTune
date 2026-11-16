#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

/// `AVAudioEngine.connect` 抛的是 ObjC 异常，Swift `do/catch` 接不住（Cosmos issue #75）。
/// 成功返回 YES；失败把异常收成 NSError，返回 NO。
BOOL LTCatchAudioEngineConnect(
    AVAudioEngine *_Nonnull engine,
    AVAudioNode *_Nonnull source,
    AVAudioNode *_Nonnull destination,
    AVAudioFormat *_Nullable format,
    NSError *_Nullable *_Nullable error
);
