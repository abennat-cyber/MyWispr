import CoreAudio
import Foundation

struct SystemVolumeController {
    static func isMuted() -> Bool {
        var defaultDeviceID: AudioObjectID = kAudioObjectUnknown
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &size,
            &defaultDeviceID
        )
        
        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else { return false }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        
        var getStatus = AudioObjectGetPropertyData(
            defaultDeviceID,
            &address,
            0,
            nil,
            &muteSize,
            &isMuted
        )
        
        if getStatus != noErr {
            address.mElement = 0
            getStatus = AudioObjectGetPropertyData(
                defaultDeviceID,
                &address,
                0,
                nil,
                &muteSize,
                &isMuted
            )
        }
        
        return getStatus == noErr && isMuted != 0
    }
    
    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        var defaultDeviceID: AudioObjectID = kAudioObjectUnknown
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &size,
            &defaultDeviceID
        )
        
        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else { return false }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var mute: UInt32 = muted ? 1 : 0
        let muteSize = UInt32(MemoryLayout<UInt32>.size)
        
        var setStatus = AudioObjectSetPropertyData(
            defaultDeviceID,
            &address,
            0,
            nil,
            muteSize,
            &mute
        )
        
        if setStatus != noErr {
            address.mElement = 0
            setStatus = AudioObjectSetPropertyData(
                defaultDeviceID,
                &address,
                0,
                nil,
                muteSize,
                &mute
            )
        }
        
        return setStatus == noErr
    }
}
