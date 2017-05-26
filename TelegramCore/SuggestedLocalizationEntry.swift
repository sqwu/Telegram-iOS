import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public final class SuggestedLocalizationEntry: PreferencesEntry {
    public let languageCode: String
    public let isSeen: Bool
    
    init(languageCode: String, isSeen: Bool) {
        self.languageCode = languageCode
        self.isSeen = isSeen
    }
    
    public init(decoder: Decoder) {
        self.languageCode = decoder.decodeStringForKey("lc", orElse: "en")
        self.isSeen = decoder.decodeInt32ForKey("s", orElse: 0) != 0
    }
    
    public func encode(_ encoder: Encoder) {
        encoder.encodeString(self.languageCode, forKey: "lc")
        encoder.encodeInt32(self.isSeen ? 1 : 0, forKey: "s")
    }
    
    public func isEqual(to: PreferencesEntry) -> Bool {
        if let to = to as? SuggestedLocalizationEntry {
            return self == to
        } else {
            return false
        }
    }
    
    public static func ==(lhs: SuggestedLocalizationEntry, rhs: SuggestedLocalizationEntry) -> Bool {
        return lhs.languageCode == rhs.languageCode && lhs.isSeen == rhs.isSeen
    }
}

public func markSuggestedLocalizationAsSeenInteractively(postbox: Postbox, languageCode: String) -> Signal<Void, NoError> {
    return postbox.modify { modifier -> Void in
        modifier.updatePreferencesEntry(key: PreferencesKeys.suggestedLocalization, { current in
            if let current = current as? SuggestedLocalizationEntry, current.languageCode == languageCode, !current.isSeen {
                return SuggestedLocalizationEntry(languageCode: languageCode, isSeen: true)
            }
            return current
        })
    }
}
