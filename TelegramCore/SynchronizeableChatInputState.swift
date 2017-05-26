import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

public struct SynchronizeableChatInputState: Coding, Equatable {
    public let replyToMessageId: MessageId?
    public let text: String
    public let timestamp: Int32
    
    public init(replyToMessageId: MessageId?, text: String, timestamp: Int32) {
        self.replyToMessageId = replyToMessageId
        self.text = text
        self.timestamp = timestamp
    }
    
    public init(decoder: Decoder) {
        self.text = decoder.decodeStringForKey("t", orElse: "")
        self.timestamp = decoder.decodeInt32ForKey("s", orElse: 0)
        if let messageIdPeerId = decoder.decodeOptionalInt64ForKey("m.p"), let messageIdNamespace = decoder.decodeOptionalInt32ForKey("m.n"), let messageIdId = decoder.decodeOptionalInt32ForKey("m.i") {
            self.replyToMessageId = MessageId(peerId: PeerId(messageIdPeerId), namespace: messageIdNamespace, id: messageIdId)
        } else {
            self.replyToMessageId = nil
        }
    }
    
    public func encode(_ encoder: Encoder) {
        encoder.encodeString(self.text, forKey: "t")
        encoder.encodeInt32(self.timestamp, forKey: "s")
        if let replyToMessageId = self.replyToMessageId {
            encoder.encodeInt64(replyToMessageId.peerId.toInt64(), forKey: "m.p")
            encoder.encodeInt32(replyToMessageId.namespace, forKey: "m.n")
            encoder.encodeInt32(replyToMessageId.id, forKey: "m.i")
        } else {
            encoder.encodeNil(forKey: "m.p")
            encoder.encodeNil(forKey: "m.n")
            encoder.encodeNil(forKey: "m.i")
        }
    }
    
    public static func ==(lhs: SynchronizeableChatInputState, rhs: SynchronizeableChatInputState) -> Bool {
        if lhs.replyToMessageId != rhs.replyToMessageId {
            return false
        }
        if lhs.text != rhs.text {
            return true
        }
        if lhs.timestamp != rhs.timestamp {
            return false
        }
        return true
    }
}

public protocol SynchronizeableChatInterfaceState: PeerChatInterfaceState {
    var synchronizeableInputState: SynchronizeableChatInputState? { get }
    func withUpdatedSynchronizeableInputState(_ state: SynchronizeableChatInputState?) -> SynchronizeableChatInterfaceState
}
