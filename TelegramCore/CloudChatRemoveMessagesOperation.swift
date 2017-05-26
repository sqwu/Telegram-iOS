import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

enum CloudChatRemoveMessagesType: Int32 {
    case forLocalPeer
    case forEveryone
}

extension CloudChatRemoveMessagesType {
    init(_ type: InteractiveMessagesDeletionType) {
        switch type {
            case .forLocalPeer:
                self = .forLocalPeer
            case .forEveryone:
                self = .forEveryone
        }
    }
}

final class CloudChatRemoveMessagesOperation: Coding {
    let messageIds: [MessageId]
    let type: CloudChatRemoveMessagesType
    
    init(messageIds: [MessageId], type: CloudChatRemoveMessagesType) {
        self.messageIds = messageIds
        self.type = type
    }
    
    init(decoder: Decoder) {
        self.messageIds = MessageId.decodeArrayFromBuffer(decoder.decodeBytesForKeyNoCopy("i")!)
        self.type = CloudChatRemoveMessagesType(rawValue: decoder.decodeInt32ForKey("t", orElse: 0))!
    }
    
    func encode(_ encoder: Encoder) {
        let buffer = WriteBuffer()
        MessageId.encodeArrayToBuffer(self.messageIds, buffer: buffer)
        encoder.encodeBytes(buffer, forKey: "i")
        encoder.encodeInt32(self.type.rawValue, forKey: "t")
    }
}

final class CloudChatRemoveChatOperation: Coding {
    let peerId: PeerId
    let reportChatSpam: Bool
    let topMessageId: MessageId?
    
    init(peerId: PeerId, reportChatSpam: Bool, topMessageId: MessageId?) {
        self.peerId = peerId
        self.reportChatSpam = reportChatSpam
        self.topMessageId = topMessageId
    }
    
    init(decoder: Decoder) {
        self.peerId = PeerId(decoder.decodeInt64ForKey("p", orElse: 0))
        self.reportChatSpam = decoder.decodeInt32ForKey("r", orElse: 0) != 0
        if let messageIdPeerId = decoder.decodeOptionalInt64ForKey("m.p"), let messageIdNamespace = decoder.decodeOptionalInt32ForKey("m.n"), let messageIdId = decoder.decodeOptionalInt32ForKey("m.i") {
            self.topMessageId = MessageId(peerId: PeerId(messageIdPeerId), namespace: messageIdNamespace, id: messageIdId)
        } else {
            self.topMessageId = nil
        }
    }
    
    func encode(_ encoder: Encoder) {
        encoder.encodeInt64(self.peerId.toInt64(), forKey: "p")
        encoder.encodeInt32(self.reportChatSpam ? 1 : 0, forKey: "r")
        if let topMessageId = self.topMessageId {
            encoder.encodeInt64(topMessageId.peerId.toInt64(), forKey: "m.p")
            encoder.encodeInt32(topMessageId.namespace, forKey: "m.n")
            encoder.encodeInt32(topMessageId.id, forKey: "m.i")
        } else {
            encoder.encodeNil(forKey: "m.p")
            encoder.encodeNil(forKey: "m.n")
            encoder.encodeNil(forKey: "m.i")
        }
    }
}

final class CloudChatClearHistoryOperation: Coding {
    let peerId: PeerId
    let topMessageId: MessageId
    
    init(peerId: PeerId, topMessageId: MessageId) {
        self.peerId = peerId
        self.topMessageId = topMessageId
    }
    
    init(decoder: Decoder) {
        self.peerId = PeerId(decoder.decodeInt64ForKey("p", orElse: 0))
        self.topMessageId = MessageId(peerId: PeerId(decoder.decodeInt64ForKey("m.p", orElse: 0)), namespace: decoder.decodeInt32ForKey("m.n", orElse: 0), id: decoder.decodeInt32ForKey("m.i", orElse: 0))
    }
    
    func encode(_ encoder: Encoder) {
        encoder.encodeInt64(self.peerId.toInt64(), forKey: "p")
        encoder.encodeInt64(self.topMessageId.peerId.toInt64(), forKey: "m.p")
        encoder.encodeInt32(self.topMessageId.namespace, forKey: "m.n")
        encoder.encodeInt32(self.topMessageId.id, forKey: "m.i")
    }
}

func cloudChatAddRemoveMessagesOperation(modifier: Modifier, peerId: PeerId, messageIds: [MessageId], type: CloudChatRemoveMessagesType) {
    modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: CloudChatRemoveMessagesOperation(messageIds: messageIds, type: type))
}

func cloudChatAddRemoveChatOperation(modifier: Modifier, peerId: PeerId, reportChatSpam: Bool) {
    modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: CloudChatRemoveChatOperation(peerId: peerId, reportChatSpam: reportChatSpam, topMessageId: modifier.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud)))
}

func cloudChatAddClearHistoryOperation(modifier: Modifier, peerId: PeerId) {
    if let topMessageId = modifier.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud) {
        modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.CloudChatRemoveMessages, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: CloudChatClearHistoryOperation(peerId: peerId, topMessageId: topMessageId))
    }
}
