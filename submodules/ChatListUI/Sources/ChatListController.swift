import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import TelegramCore
import SyncCore
import TelegramPresentationData
import TelegramUIPreferences
import TelegramBaseController
import OverlayStatusController
import AccountContext
import AlertUI
import PresentationDataUtils
import UndoUI
import TelegramNotices
import SearchUI
import DeleteChatPeerActionSheetItem
import LanguageSuggestionUI
import ContextUI
import AppBundle
import LocalizedPeerData
import TelegramIntents

private func fixListNodeScrolling(_ listNode: ListView, searchNode: NavigationBarSearchContentNode) -> Bool {
    if listNode.scroller.isDragging {
        return false
    }
    if searchNode.expansionProgress > 0.0 && searchNode.expansionProgress < 1.0 {
        let scrollToItem: ListViewScrollToItem
        let targetProgress: CGFloat
        let offset: CGFloat
        if searchNode.expansionProgress < 0.6 {
            scrollToItem = ListViewScrollToItem(index: 0, position: .top(-navigationBarSearchContentHeight), animated: true, curve: .Default(duration: nil), directionHint: .Up)
            targetProgress = 0.0
            offset = navigationBarSearchContentHeight
        } else {
            scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: .Default(duration: nil), directionHint: .Up)
            targetProgress = 1.0
            offset = 0.0
        }
        //searchNode.updateExpansionProgress(targetProgress, animated: true)
        
        //listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: scrollToItem, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        listNode.scrollToOffsetFromTop(offset)
        return true
    } else if searchNode.expansionProgress == 1.0 {
        var sortItemNode: ListViewItemNode?
        var nextItemNode: ListViewItemNode?
        
        listNode.forEachItemNode({ itemNode in
            if sortItemNode == nil, let itemNode = itemNode as? ChatListItemNode, let item = itemNode.item, case .groupReference = item.content {
                sortItemNode = itemNode
            } else if sortItemNode != nil && nextItemNode == nil {
                nextItemNode = itemNode as? ListViewItemNode
            }
        })
        
        if false, let sortItemNode = sortItemNode {
            let itemFrame = sortItemNode.apparentFrame
            if itemFrame.contains(CGPoint(x: 0.0, y: listNode.insets.top)) {
                var scrollToItem: ListViewScrollToItem?
                if itemFrame.minY + itemFrame.height * 0.6 < listNode.insets.top {
                    scrollToItem = ListViewScrollToItem(index: 0, position: .top(-76.0), animated: true, curve: .Default(duration: 0.3), directionHint: .Up)
                } else {
                    scrollToItem = ListViewScrollToItem(index: 0, position: .top(0), animated: true, curve: .Default(duration: 0.3), directionHint: .Up)
                }
                listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: scrollToItem, updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                return true
            }
        }
    }
    return false
}

private final class ContextControllerContentSourceImpl: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    
    let navigationController: NavigationController?
    
    let passthroughTouches: Bool = true
    
    init(controller: ViewController, sourceNode: ASDisplayNode?, navigationController: NavigationController?) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.navigationController = navigationController
    }
    
    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceNode = self.sourceNode
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceNode = sourceNode {
                return (sourceNode, sourceNode.bounds)
            } else {
                return nil
            }
        })
    }
    
    func animatedIn() {
    }
}

public class ChatListControllerImpl: TelegramBaseController, ChatListController, UIViewControllerPreviewingDelegate {
    private var validLayout: ContainerViewLayout?
    
    public let context: AccountContext
    private let controlsHistoryPreload: Bool
    private let hideNetworkActivityStatus: Bool
    
    public let groupId: PeerGroupId
    public let filter: ChatListFilter?
    public let previewing: Bool
    
    let openMessageFromSearchDisposable: MetaDisposable = MetaDisposable()
    
    private var chatListDisplayNode: ChatListControllerNode {
        return super.displayNode as! ChatListControllerNode
    }
    
    private let titleView: ChatListTitleView
    private var proxyUnavailableTooltipController: TooltipController?
    private var didShowProxyUnavailableTooltipController = false
    
    private var titleDisposable: Disposable?
    private var badgeDisposable: Disposable?
    private var badgeIconDisposable: Disposable?
    
    private var dismissSearchOnDisappear = false
        
    private var passcodeLockTooltipDisposable = MetaDisposable()
    private var didShowPasscodeLockTooltipController = false
    
    private var suggestLocalizationDisposable = MetaDisposable()
    private var didSuggestLocalization = false
    
    private var presentationData: PresentationData
    private let presentationDataValue = Promise<PresentationData>()
    private var presentationDataDisposable: Disposable?
    
    private let stateDisposable = MetaDisposable()
    private var filterDisposable: Disposable?
    
    private var searchContentNode: NavigationBarSearchContentNode?
    
    private let tabContainerNode: ChatListFilterTabContainerNode
    private var tabContainerData: [ChatListFilterTabEntry]?
    
    public override func updateNavigationCustomData(_ data: Any?, progress: CGFloat, transition: ContainedViewLayoutTransition) {
        if self.isNodeLoaded {
            self.chatListDisplayNode.containerNode.updateSelectedChatLocation(data: data as? ChatLocation, progress: progress, transition: transition)
        }
    }
    
    public init(context: AccountContext, groupId: PeerGroupId, filter: ChatListFilter? = nil, controlsHistoryPreload: Bool, hideNetworkActivityStatus: Bool = false, previewing: Bool = false, enableDebugActions: Bool) {
        self.context = context
        self.controlsHistoryPreload = controlsHistoryPreload
        self.hideNetworkActivityStatus = hideNetworkActivityStatus
        
        self.groupId = groupId
        self.filter = filter
        self.previewing = previewing
        
        self.presentationData = (context.sharedContext.currentPresentationData.with { $0 })
        self.presentationDataValue.set(.single(self.presentationData))
        
        self.titleView = ChatListTitleView(theme: self.presentationData.theme, strings: self.presentationData.strings)
        
        self.tabContainerNode = ChatListFilterTabContainerNode()
        
        super.init(context: context, navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData), mediaAccessoryPanelVisibility: .always, locationBroadcastPanelSource: .summary)
        
        self.hasTabBarItemContextAction = true
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        
        let title: String
        if let filter = self.filter {
            title = filter.title ?? ""
        } else if self.groupId == .root {
            title = self.presentationData.strings.DialogList_Title
            self.navigationBar?.item = nil
        } else {
            title = self.presentationData.strings.ChatList_ArchivedChatsTitle
        }
        
        self.titleView.title = NetworkStatusTitle(text: title, activity: false, hasProxy: false, connectsViaProxy: false, isPasscodeSet: false, isManuallyLocked: false)
        self.navigationItem.titleView = self.titleView
        
        if !previewing {
            if self.groupId == .root && self.filter == nil {
                self.tabBarItem.title = self.presentationData.strings.DialogList_Title
                
                let icon: UIImage?
                if useSpecialTabBarIcons() {
                    icon = UIImage(bundleImageName: "Chat List/Tabs/Holiday/IconChats")
                } else {
                    icon = UIImage(bundleImageName: "Chat List/Tabs/IconChats")
                }
                
                self.tabBarItem.image = icon
                self.tabBarItem.selectedImage = icon
                
                let leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))
                leftBarButtonItem.accessibilityLabel = self.presentationData.strings.Common_Edit
                self.navigationItem.leftBarButtonItem = leftBarButtonItem
                
                let rightBarButtonItem = UIBarButtonItem(image: PresentationResourcesRootController.navigationComposeIcon(self.presentationData.theme), style: .plain, target: self, action: #selector(self.composePressed))
                rightBarButtonItem.accessibilityLabel = self.presentationData.strings.VoiceOver_Navigation_Compose
                self.navigationItem.rightBarButtonItem = rightBarButtonItem
                let backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.DialogList_Title, style: .plain, target: nil, action: nil)
                backBarButtonItem.accessibilityLabel = self.presentationData.strings.Common_Back
                self.navigationItem.backBarButtonItem = backBarButtonItem
            } else {
                let rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))
                rightBarButtonItem.accessibilityLabel = self.presentationData.strings.Common_Edit
                self.navigationItem.rightBarButtonItem = rightBarButtonItem
                let backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
                backBarButtonItem.accessibilityLabel = self.presentationData.strings.Common_Back
                self.navigationItem.backBarButtonItem = backBarButtonItem
            }
        }
        
        self.scrollToTop = { [weak self] in
            if let strongSelf = self {
                if let searchContentNode = strongSelf.searchContentNode {
                    searchContentNode.updateExpansionProgress(1.0, animated: true)
                }
                strongSelf.chatListDisplayNode.scrollToTop()
            }
        }
        self.scrollToTopWithTabBar = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.chatListDisplayNode.searchDisplayController != nil {
                strongSelf.deactivateSearch(animated: true)
            } else {
                switch strongSelf.chatListDisplayNode.containerNode.currentItemNode.visibleContentOffset() {
                case .none, .unknown:
                    if let searchContentNode = strongSelf.searchContentNode {
                        searchContentNode.updateExpansionProgress(1.0, animated: true)
                    }
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.scrollToPosition(.top)
                case let .known(offset):
                    if offset <= navigationBarSearchContentHeight + 1.0 {
                        strongSelf.tabContainerNode.tabSelected?(.all)
                    } else {
                        if let searchContentNode = strongSelf.searchContentNode {
                            searchContentNode.updateExpansionProgress(1.0, animated: true)
                        }
                        strongSelf.chatListDisplayNode.containerNode.currentItemNode.scrollToPosition(.top)
                    }
                }
            }
        }
        
        let hasProxy = context.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> map { sharedData -> (Bool, Bool) in
            if let settings = sharedData.entries[SharedDataKeys.proxySettings] as? ProxySettings {
                return (!settings.servers.isEmpty, settings.enabled)
            } else {
                return (false, false)
            }
        }
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            return lhs == rhs
        })
        
        let passcode = context.sharedContext.accountManager.accessChallengeData()
        |> map { view -> (Bool, Bool) in
            let data = view.data
            return (data.isLockable, false)
        }
        
        if !self.hideNetworkActivityStatus {
            self.titleDisposable = combineLatest(queue: .mainQueue(),
                context.account.networkState,
                hasProxy,
                passcode,
                self.chatListDisplayNode.containerNode.currentItemState
            ).start(next: { [weak self] networkState, proxy, passcode, state in
                if let strongSelf = self {
                    let defaultTitle: String
                    if strongSelf.groupId == .root {
                        defaultTitle = strongSelf.presentationData.strings.DialogList_Title
                    } else {
                        defaultTitle = strongSelf.presentationData.strings.ChatList_ArchivedChatsTitle
                    }
                    if state.editing {
                        if strongSelf.groupId == .root {
                            strongSelf.navigationItem.rightBarButtonItem = nil
                        }
                        
                        let title = !state.selectedPeerIds.isEmpty ? strongSelf.presentationData.strings.ChatList_SelectedChats(Int32(state.selectedPeerIds.count)) : defaultTitle
                        strongSelf.titleView.title = NetworkStatusTitle(text: title, activity: false, hasProxy: false, connectsViaProxy: false, isPasscodeSet: false, isManuallyLocked: false)
                    } else {
                        var isRoot = false
                        if case .root = strongSelf.groupId {
                            isRoot = true
                            let rightBarButtonItem = UIBarButtonItem(image: PresentationResourcesRootController.navigationComposeIcon(strongSelf.presentationData.theme), style: .plain, target: strongSelf, action: #selector(strongSelf.composePressed))
                            rightBarButtonItem.accessibilityLabel = strongSelf.presentationData.strings.VoiceOver_Navigation_Compose
                            strongSelf.navigationItem.rightBarButtonItem = rightBarButtonItem
                        }
                        
                        let (hasProxy, connectsViaProxy) = proxy
                        let (isPasscodeSet, isManuallyLocked) = passcode
                        var checkProxy = false
                        switch networkState {
                            case .waitingForNetwork:
                                strongSelf.titleView.title = NetworkStatusTitle(text: strongSelf.presentationData.strings.State_WaitingForNetwork, activity: true, hasProxy: false, connectsViaProxy: connectsViaProxy, isPasscodeSet: isRoot && isPasscodeSet, isManuallyLocked: isRoot && isManuallyLocked)
                            case let .connecting(proxy):
                                var text = strongSelf.presentationData.strings.State_Connecting
                                if let layout = strongSelf.validLayout, proxy != nil && layout.metrics.widthClass != .regular && layout.size.width > 320.0 {
                                    text = strongSelf.presentationData.strings.State_ConnectingToProxy
                                }
                                if let proxy = proxy, proxy.hasConnectionIssues {
                                    checkProxy = true
                                }
                                strongSelf.titleView.title = NetworkStatusTitle(text: text, activity: true, hasProxy: isRoot && hasProxy, connectsViaProxy: connectsViaProxy, isPasscodeSet: isRoot && isPasscodeSet, isManuallyLocked: isRoot && isManuallyLocked)
                            case .updating:
                                strongSelf.titleView.title = NetworkStatusTitle(text: strongSelf.presentationData.strings.State_Updating, activity: true, hasProxy: isRoot && hasProxy, connectsViaProxy: connectsViaProxy, isPasscodeSet: isRoot && isPasscodeSet, isManuallyLocked: isRoot && isManuallyLocked)
                            case .online:
                                strongSelf.titleView.title = NetworkStatusTitle(text: defaultTitle, activity: false, hasProxy: isRoot && hasProxy, connectsViaProxy: connectsViaProxy, isPasscodeSet: isRoot && isPasscodeSet, isManuallyLocked: isRoot && isManuallyLocked)
                        }
                        if groupId == .root && filter == nil && checkProxy {
                            if strongSelf.proxyUnavailableTooltipController == nil && !strongSelf.didShowProxyUnavailableTooltipController && strongSelf.isNodeLoaded && strongSelf.displayNode.view.window != nil && strongSelf.navigationController?.topViewController === self {
                                strongSelf.didShowProxyUnavailableTooltipController = true
                                let tooltipController = TooltipController(content: .text(strongSelf.presentationData.strings.Proxy_TooltipUnavailable), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, timeout: 60.0, dismissByTapOutside: true)
                                strongSelf.proxyUnavailableTooltipController = tooltipController
                                tooltipController.dismissed = { [weak tooltipController] _ in
                                    if let strongSelf = self, let tooltipController = tooltipController, strongSelf.proxyUnavailableTooltipController === tooltipController {
                                        strongSelf.proxyUnavailableTooltipController = nil
                                    }
                                }
                                strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceViewAndRect: {
                                    if let strongSelf = self, let rect = strongSelf.titleView.proxyButtonFrame {
                                        return (strongSelf.titleView, rect.insetBy(dx: 0.0, dy: -4.0))
                                    }
                                    return nil
                                }))
                            }
                        } else {
                            strongSelf.didShowProxyUnavailableTooltipController = false
                            if let proxyUnavailableTooltipController = strongSelf.proxyUnavailableTooltipController {
                                strongSelf.proxyUnavailableTooltipController = nil
                                proxyUnavailableTooltipController.dismiss()
                            }
                        }
                    }
                }
            })
        }
        
        self.badgeDisposable = (combineLatest(renderedTotalUnreadCount(accountManager: context.sharedContext.accountManager, postbox: context.account.postbox), self.presentationDataValue.get()) |> deliverOnMainQueue).start(next: { [weak self] count, presentationData in
            if let strongSelf = self {
                if count.0 == 0 {
                    strongSelf.tabBarItem.badgeValue = ""
                } else {
                    strongSelf.tabBarItem.badgeValue = compactNumericCountString(Int(count.0), decimalSeparator: presentationData.dateTimeFormat.decimalSeparator)
                }
            }
        })
        
        self.titleView.toggleIsLocked = { [weak self] in
            if let strongSelf = self {
                strongSelf.context.sharedContext.appLockContext.lock()
            }
        }
        
        self.titleView.openProxySettings = { [weak self] in
            if let strongSelf = self {
                (strongSelf.navigationController as? NavigationController)?.pushViewController(context.sharedContext.makeProxySettingsController(context: context))
            }
        }
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                strongSelf.presentationDataValue.set(.single(presentationData))
                
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        })
        
        if !previewing {
            self.searchContentNode = NavigationBarSearchContentNode(theme: self.presentationData.theme, placeholder: self.presentationData.strings.DialogList_SearchLabel, activate: { [weak self] in
                self?.activateSearch()
            })
            self.searchContentNode?.updateExpansionProgress(0.0)
            self.navigationBar?.setContentNode(self.searchContentNode, animated: false)
        }
        
        if enableDebugActions {
            self.tabBarItemDebugTapAction = {
                preconditionFailure("debug tap")
            }
        }
        
        if self.filter == nil {
            self.chatListDisplayNode.containerNode.currentItemFilterUpdated = { [weak self] filter, fraction, transition in
                guard let strongSelf = self else {
                    return
                }
                guard let layout = strongSelf.validLayout else {
                    return
                }
                guard let tabContainerData = strongSelf.tabContainerData else {
                    return
                }
                strongSelf.tabContainerNode.update(size: CGSize(width: layout.size.width, height: 46.0), sideInset: layout.safeInsets.left, filters: tabContainerData, selectedFilter: filter, transitionFraction: fraction, presentationData: strongSelf.presentationData, transition: transition)
            }
            let preferencesKey: PostboxViewKey = .preferences(keys: Set([
                ApplicationSpecificPreferencesKeys.chatListFilterSettings
            ]))
            let filterItems = chatListFilterItems(context: context)
            self.filterDisposable = (combineLatest(queue: .mainQueue(),
                    context.account.postbox.combinedView(keys: [
                    preferencesKey
                ]),
                filterItems
            )
            |> deliverOnMainQueue).start(next: { [weak self] combinedView, countAndFilterItems in
                guard let strongSelf = self else {
                    return
                }
                let (totalCount, items) = countAndFilterItems
                var filterItems: [ChatListFilterTabEntry] = []
                filterItems.append(.all(unreadCount: 0))
                for (filter, unreadCount) in items {
                    filterItems.append(.filter(id: filter.id, text: filter.title, unreadCount: unreadCount))
                }
                
                var filterSettings: ChatListFilterSettings = .default
                if let preferencesView = combinedView.views[preferencesKey] as? PreferencesView {
                    if let value = preferencesView.values[ApplicationSpecificPreferencesKeys.chatListFilterSettings] as? ChatListFilterSettings {
                        filterSettings = value
                    }
                }
                
                var resolvedItems = filterItems
                if !filterSettings.displayTabs || groupId != .root {
                    resolvedItems = []
                }
                
                var wasEmpty = false
                if let tabContainerData = strongSelf.tabContainerData {
                    wasEmpty = tabContainerData.count <= 1
                } else {
                    wasEmpty = true
                }
                let selectedEntryId = strongSelf.chatListDisplayNode.containerNode.currentItemFilter
                strongSelf.tabContainerData = resolvedItems
                var availableFilters: [ChatListContainerNodeFilter] = []
                availableFilters.append(.all)
                for item in items {
                    availableFilters.append(.filter(item.0))
                }
                strongSelf.chatListDisplayNode.containerNode.updateAvailableFilters(availableFilters)
                
                let isEmpty = resolvedItems.count <= 1
                
                if wasEmpty != isEmpty {
                    strongSelf.navigationBar?.setSecondaryContentNode(isEmpty ? nil : strongSelf.tabContainerNode)
                    if let parentController = strongSelf.parent as? TabBarController {
                        parentController.navigationBar?.setSecondaryContentNode(isEmpty ? nil : strongSelf.tabContainerNode)
                    }
                }
                
                if let layout = strongSelf.validLayout {
                    if wasEmpty != isEmpty {
                        strongSelf.containerLayoutUpdated(layout, transition: .immediate)
                        (strongSelf.parent as? TabBarController)?.updateLayout()
                    } else {
                        strongSelf.tabContainerNode.update(size: CGSize(width: layout.size.width, height: 46.0), sideInset: layout.safeInsets.left, filters: resolvedItems, selectedFilter: selectedEntryId, transitionFraction: strongSelf.chatListDisplayNode.containerNode.transitionFraction, presentationData: strongSelf.presentationData, transition: .animated(duration: 0.4, curve: .spring))
                    }
                }
            })
        }
        
        self.tabContainerNode.tabSelected = { [weak self] id in
            guard let strongSelf = self else {
                return
            }
            let _ = (strongSelf.context.account.postbox.transaction { transaction -> [ChatListFilter] in
                let settings = transaction.getPreferencesEntry(key: PreferencesKeys.chatListFilters) as? ChatListFiltersState ?? ChatListFiltersState.default
                return settings.filters
            }
            |> deliverOnMainQueue).start(next: { [weak self] filters in
                guard let strongSelf = self else {
                    return
                }
                let previousFilter = strongSelf.chatListDisplayNode.containerNode.currentItemNode.chatListFilter
                let updatedFilter: ChatListFilter?
                switch id {
                case .all:
                    updatedFilter = nil
                case let .filter(id):
                    var found = false
                    var foundValue: ChatListFilter?
                    for filter in filters {
                        if filter.id == id {
                            foundValue = filter
                            found = true
                            break
                        }
                    }
                    if found {
                        updatedFilter = foundValue
                    } else {
                        updatedFilter = nil
                    }
                }
                strongSelf.chatListDisplayNode.containerNode.switchToFilter(id: updatedFilter.flatMap { .filter($0.id) } ?? .all)
            })
        }
        
        self.tabContainerNode.addFilter = { [weak self] in
            self?.openFilterSettings()
        }
        
        self.tabContainerNode.contextGesture = { [weak self] id, sourceNode, gesture in
            guard let strongSelf = self else {
                return
            }
            let _ = (strongSelf.context.account.postbox.transaction { transaction -> [ChatListFilter] in
                let settings = transaction.getPreferencesEntry(key: PreferencesKeys.chatListFilters) as? ChatListFiltersState ?? ChatListFiltersState.default
                return settings.filters
            }
            |> deliverOnMainQueue).start(next: { [weak self] filters in
                guard let strongSelf = self else {
                    return
                }
                var items: [ContextMenuItem] = []
                items.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.Common_Edit, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.contextMenu.primaryColor)
                }, action: { c, f in
                    c.dismiss(completion: {
                        guard let strongSelf = self else {
                            return
                        }
                        let _ = (strongSelf.context.account.postbox.transaction { transaction -> [ChatListFilter] in
                            let settings = transaction.getPreferencesEntry(key: PreferencesKeys.chatListFilters) as? ChatListFiltersState ?? ChatListFiltersState.default
                            return settings.filters
                        }
                        |> deliverOnMainQueue).start(next: { presetList in
                            guard let strongSelf = self else {
                                return
                            }
                            var found = false
                            for filter in presetList {
                                if filter.id == id {
                                    strongSelf.push(chatListFilterPresetController(context: strongSelf.context, currentPreset: filter, updated: { _ in }))
                                    f(.dismissWithoutContent)
                                    found = true
                                    break
                                }
                            }
                        })
                    })
                })))
                if let filter = filters.first(where: { $0.id == id }), filter.data.includePeers.count < 100 {
                    //TODO:localization
                    items.append(.action(ContextMenuActionItem(text: "Add Chats", icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: theme.contextMenu.primaryColor)
                    }, action: { c, f in
                        c.dismiss(completion: {
                            guard let strongSelf = self else {
                                return
                            }
                            let _ = (strongSelf.context.account.postbox.transaction { transaction -> [ChatListFilter] in
                                let settings = transaction.getPreferencesEntry(key: PreferencesKeys.chatListFilters) as? ChatListFiltersState ?? ChatListFiltersState.default
                                return settings.filters
                            }
                            |> deliverOnMainQueue).start(next: { presetList in
                                guard let strongSelf = self else {
                                    return
                                }
                                var found = false
                                for filter in presetList {
                                    if filter.id == id {
                                        strongSelf.push(chatListFilterAddChatsController(context: strongSelf.context, filter: filter))
                                        f(.dismissWithoutContent)
                                        found = true
                                        break
                                    }
                                }
                            })
                        })
                    })))
                    items.append(.action(ContextMenuActionItem(text: "Delete", textColor: .destructive, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
                    }, action: { c, f in
                        c.dismiss(completion: {
                            guard let strongSelf = self else {
                                return
                            }
                            let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                            
                            actionSheet.setItemGroups([
                                ActionSheetItemGroup(items: [
                                    ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Delete, color: .destructive, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                        
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        let _ = updateChatListFilterSettingsInteractively(postbox: strongSelf.context.account.postbox, { settings in
                                            var settings = settings
                                            settings.filters = settings.filters.filter({ $0.id != id })
                                            return settings
                                        }).start()
                                        let _ = replaceRemoteChatListFilters(account: strongSelf.context.account).start()
                                    })
                                ]),
                                ActionSheetItemGroup(items: [
                                    ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                    })
                                ])
                            ])
                            strongSelf.present(actionSheet, in: .window(.root))
                        })
                    })))
                }
                
                let controller = ContextController(account: strongSelf.context.account, presentationData: strongSelf.presentationData, source: .extracted(ChatListHeaderBarContextExtractedContentSource(controller: strongSelf, sourceNode: sourceNode)), items: .single(items), reactionItems: [], recognizer: nil, gesture: gesture)
                strongSelf.context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
            })
        }
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.openMessageFromSearchDisposable.dispose()
        self.titleDisposable?.dispose()
        self.badgeDisposable?.dispose()
        self.badgeIconDisposable?.dispose()
        self.passcodeLockTooltipDisposable.dispose()
        self.suggestLocalizationDisposable.dispose()
        self.presentationDataDisposable?.dispose()
        self.stateDisposable.dispose()
        self.filterDisposable?.dispose()
    }
    
    private func updateThemeAndStrings() {
        if case .root = self.groupId {
            self.tabBarItem.title = self.presentationData.strings.DialogList_Title
            let backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.DialogList_Title, style: .plain, target: nil, action: nil)
            backBarButtonItem.accessibilityLabel = self.presentationData.strings.Common_Back
            self.navigationItem.backBarButtonItem = backBarButtonItem
        } else {
            let backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
            backBarButtonItem.accessibilityLabel = self.presentationData.strings.Common_Back
            self.navigationItem.backBarButtonItem = backBarButtonItem
        }
        
        self.searchContentNode?.updateThemeAndPlaceholder(theme: self.presentationData.theme, placeholder: self.presentationData.strings.DialogList_SearchLabel)
        let editing = self.chatListDisplayNode.containerNode.currentItemNode.currentState.editing
        let editItem: UIBarButtonItem
        if editing {
            editItem = UIBarButtonItem(title: self.presentationData.strings.Common_Done, style: .done, target: self, action: #selector(self.donePressed))
            editItem.accessibilityLabel = self.presentationData.strings.Common_Done
        } else {
            editItem = UIBarButtonItem(title: self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))
            editItem.accessibilityLabel = self.presentationData.strings.Common_Edit
        }
        if self.groupId == .root && self.filter == nil {
            self.navigationItem.leftBarButtonItem = editItem
            let rightBarButtonItem = UIBarButtonItem(image: PresentationResourcesRootController.navigationComposeIcon(self.presentationData.theme), style: .plain, target: self, action: #selector(self.composePressed))
            rightBarButtonItem.accessibilityLabel = self.presentationData.strings.VoiceOver_Navigation_Compose
            self.navigationItem.rightBarButtonItem = rightBarButtonItem
        } else {
            self.navigationItem.rightBarButtonItem = editItem
        }
        
        self.titleView.theme = self.presentationData.theme
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData))
        
        if self.isNodeLoaded {
            self.chatListDisplayNode.updatePresentationData(self.presentationData)
        }
    }
    
    override public func loadDisplayNode() {
        self.displayNode = ChatListControllerNode(context: self.context, groupId: self.groupId, filter: self.filter, previewing: self.previewing, controlsHistoryPreload: self.controlsHistoryPreload, presentationData: self.presentationData, controller: self)
        
        self.chatListDisplayNode.navigationBar = self.navigationBar
        
        self.chatListDisplayNode.requestDeactivateSearch = { [weak self] in
            self?.deactivateSearch(animated: true)
        }
        
        self.chatListDisplayNode.containerNode.activateSearch = { [weak self] in
            self?.activateSearch()
        }
        
        self.chatListDisplayNode.containerNode.presentAlert = { [weak self] text in
            if let strongSelf = self {
                self?.present(textAlertController(context: strongSelf.context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
            }
        }
        
        self.chatListDisplayNode.containerNode.present = { [weak self] c in
            if let strongSelf = self {
                self?.present(c, in: .window(.root))
            }
        }
        
        self.chatListDisplayNode.containerNode.toggleArchivedFolderHiddenByDefault = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.toggleArchivedFolderHiddenByDefault()
        }
        
        self.chatListDisplayNode.containerNode.deletePeerChat = { [weak self] peerId in
            guard let strongSelf = self else {
                return
            }
            strongSelf.deletePeerChat(peerId: peerId)
        }
        
        self.chatListDisplayNode.containerNode.peerSelected = { [weak self] peer, animated, isAd in
            if let strongSelf = self {
                if let navigationController = strongSelf.navigationController as? NavigationController {
                    if isAd {
                        let _ = (ApplicationSpecificNotice.getProxyAdsAcknowledgment(accountManager: strongSelf.context.sharedContext.accountManager)
                        |> deliverOnMainQueue).start(next: { value in
                            guard let strongSelf = self else {
                                return
                            }
                            if !value {
                                strongSelf.present(textAlertController(context: strongSelf.context, title: nil, text: strongSelf.presentationData.strings.DialogList_AdNoticeAlert, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                                    if let strongSelf = self {
                                        let _ = ApplicationSpecificNotice.setProxyAdsAcknowledgment(accountManager: strongSelf.context.sharedContext.accountManager).start()
                                    }
                                })]), in: .window(.root))
                            }
                        })
                    }
                    
                    var scrollToEndIfExists = false
                    if let layout = strongSelf.validLayout, case .regular = layout.metrics.widthClass {
                        scrollToEndIfExists = true
                    }
                    
                    strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peer.id), scrollToEndIfExists: scrollToEndIfExists, options: strongSelf.groupId == PeerGroupId.root ? [.removeOnMasterDetails] : [], parentGroupId: strongSelf.groupId, completion: { [weak self] in
                        self?.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
                    }))
                }
            }
        }
        
        self.chatListDisplayNode.containerNode.groupSelected = { [weak self] groupId in
            if let strongSelf = self {
                if let navigationController = strongSelf.navigationController as? NavigationController {
                    let chatListController = ChatListControllerImpl(context: strongSelf.context, groupId: groupId, controlsHistoryPreload: false, enableDebugActions: false)
                    chatListController.navigationPresentation = .master
                    navigationController.pushViewController(chatListController)
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
                }
            }
        }
        
        self.chatListDisplayNode.containerNode.updatePeerGrouping = { [weak self] peerId, group in
            guard let strongSelf = self else {
                return
            }
            if group {
                strongSelf.archiveChats(peerIds: [peerId])
            } else {
                strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerId)
                let _ = updatePeerGroupIdInteractively(postbox: strongSelf.context.account.postbox, peerId: peerId, groupId: group ? Namespaces.PeerGroup.archive : .root).start(completed: {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
                })
            }
        }
        
        self.chatListDisplayNode.requestOpenMessageFromSearch = { [weak self] peer, messageId in
            if let strongSelf = self {
                strongSelf.openMessageFromSearchDisposable.set((storedMessageFromSearchPeer(account: strongSelf.context.account, peer: peer)
                |> deliverOnMainQueue).start(next: { [weak strongSelf] actualPeerId in
                    if let strongSelf = strongSelf {
                        if let navigationController = strongSelf.navigationController as? NavigationController {
                            var scrollToEndIfExists = false
                            if let layout = strongSelf.validLayout, case .regular = layout.metrics.widthClass {
                                scrollToEndIfExists = true
                            }
                            strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(actualPeerId), subject: .message(messageId), purposefulAction: {
                                self?.deactivateSearch(animated: false)
                            }, scrollToEndIfExists: scrollToEndIfExists, options:  strongSelf.groupId == PeerGroupId.root ? [.removeOnMasterDetails] : []))
                            strongSelf.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
                        }
                    }
                }))
            }
        }
        
        self.chatListDisplayNode.requestOpenPeerFromSearch = { [weak self] peer, dismissSearch in
            if let strongSelf = self {
                let storedPeer = strongSelf.context.account.postbox.transaction { transaction -> Void in
                    if transaction.getPeer(peer.id) == nil {
                        updatePeers(transaction: transaction, peers: [peer], update: { previousPeer, updatedPeer in
                            return updatedPeer
                        })
                    }
                }
                strongSelf.openMessageFromSearchDisposable.set((storedPeer |> deliverOnMainQueue).start(completed: { [weak strongSelf] in
                    if let strongSelf = strongSelf {
                        if dismissSearch {
                            strongSelf.deactivateSearch(animated: true)
                        }
                        var scrollToEndIfExists = false
                        if let layout = strongSelf.validLayout, case .regular = layout.metrics.widthClass {
                            scrollToEndIfExists = true
                        }
                        if let navigationController = strongSelf.navigationController as? NavigationController {
                            strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peer.id), purposefulAction: { [weak self] in
                                self?.deactivateSearch(animated: false)
                            }, scrollToEndIfExists: scrollToEndIfExists, options:  strongSelf.groupId == PeerGroupId.root ? [.removeOnMasterDetails] : []))
                            strongSelf.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
                        }
                    }
                }))
            }
        }
        
        self.chatListDisplayNode.requestOpenRecentPeerOptions = { [weak self] peer in
            if let strongSelf = self {
                strongSelf.view.window?.endEditing(true)
                let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                
                actionSheet.setItemGroups([
                    ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Delete, color: .destructive, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            
                            if let strongSelf = self {
                                let _ = removeRecentPeer(account: strongSelf.context.account, peerId: peer.id).start()
                            }
                        })
                    ]),
                    ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])
                ])
                strongSelf.present(actionSheet, in: .window(.root))
            }
        }
        
        self.chatListDisplayNode.requestAddContact = { [weak self] phoneNumber in
            if let strongSelf = self {
                strongSelf.view.endEditing(true)
                strongSelf.context.sharedContext.openAddContact(context: strongSelf.context, firstName: "", lastName: "", phoneNumber: phoneNumber, label: defaultContactLabel, present: { [weak self] controller, arguments in
                    self?.present(controller, in: .window(.root), with: arguments)
                }, pushController: { [weak self] controller in
                    (self?.navigationController as? NavigationController)?.pushViewController(controller)
                }, completed: {
                    self?.deactivateSearch(animated: false)
                })
            }
        }
        
        self.chatListDisplayNode.dismissSelf = { [weak self] in
            guard let strongSelf = self, let navigationController = strongSelf.navigationController as? NavigationController else {
                return
            }
            navigationController.filterController(strongSelf, animated: true)
        }
        
        self.chatListDisplayNode.containerNode.contentOffsetChanged = { [weak self] offset in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode, let validLayout = strongSelf.validLayout {
                var offset = offset
                if validLayout.inVoiceOver {
                    offset = .known(0.0)
                }
                searchContentNode.updateListVisibleContentOffset(offset)
            }
        }
        
        self.chatListDisplayNode.containerNode.contentScrollingEnded = { [weak self] listView in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                return fixListNodeScrolling(listView, searchNode: searchContentNode)
            } else {
                return false
            }
        }
        
        self.chatListDisplayNode.isEmptyUpdated = { [weak self] isEmpty in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode, let _ = strongSelf.validLayout {
                if isEmpty {
                    //searchContentNode.updateListVisibleContentOffset(.known(0.0))
                }
            }
        }
        
        self.chatListDisplayNode.emptyListAction = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if let filter = strongSelf.chatListDisplayNode.containerNode.currentItemNode.chatListFilter {
                strongSelf.push(chatListFilterPresetController(context: strongSelf.context, currentPreset: filter, updated: { _ in }))
            } else {
                strongSelf.composePressed()
            }
        }
        
        self.chatListDisplayNode.toolbarActionSelected = { [weak self] action in
            self?.toolbarActionSelected(action: action)
        }
        
        self.chatListDisplayNode.containerNode.activateChatPreview = { [weak self] item, node, gesture in
            guard let strongSelf = self else {
                gesture?.cancel()
                return
            }
            switch item.content {
            case let .groupReference(groupReference):
                let chatListController = ChatListControllerImpl(context: strongSelf.context, groupId: groupReference.groupId, controlsHistoryPreload: false, hideNetworkActivityStatus: true, previewing: true, enableDebugActions: false)
                chatListController.navigationPresentation = .master
                let contextController = ContextController(account: strongSelf.context.account, presentationData: strongSelf.presentationData, source: .controller(ContextControllerContentSourceImpl(controller: chatListController, sourceNode: node, navigationController: strongSelf.navigationController as? NavigationController)), items: archiveContextMenuItems(context: strongSelf.context, groupId: groupReference.groupId, chatListController: strongSelf), reactionItems: [], gesture: gesture)
                strongSelf.presentInGlobalOverlay(contextController)
            case let .peer(peer):
                let chatController = strongSelf.context.sharedContext.makeChatController(context: strongSelf.context, chatLocation: .peer(peer.peer.peerId), subject: nil, botStart: nil, mode: .standard(previewing: true))
                chatController.canReadHistory.set(false)
                let contextController = ContextController(account: strongSelf.context.account, presentationData: strongSelf.presentationData, source: .controller(ContextControllerContentSourceImpl(controller: chatController, sourceNode: node, navigationController: strongSelf.navigationController as? NavigationController)), items: chatContextMenuItems(context: strongSelf.context, peerId: peer.peer.peerId, source: .chatList, chatListController: strongSelf), reactionItems: [], gesture: gesture)
                strongSelf.presentInGlobalOverlay(contextController)
            }
        }
        
        self.chatListDisplayNode.peerContextAction = { [weak self] peer, source, node, gesture in
            guard let strongSelf = self else {
                gesture?.cancel()
                return
            }
            
            let chatController = strongSelf.context.sharedContext.makeChatController(context: strongSelf.context, chatLocation: .peer(peer.id), subject: nil, botStart: nil, mode: .standard(previewing: true))
            chatController.canReadHistory.set(false)
            let contextController = ContextController(account: strongSelf.context.account, presentationData: strongSelf.presentationData, source: .controller(ContextControllerContentSourceImpl(controller: chatController, sourceNode: node, navigationController: strongSelf.navigationController as? NavigationController)), items: chatContextMenuItems(context: strongSelf.context, peerId: peer.id, source: .search(source), chatListController: strongSelf), reactionItems: [], gesture: gesture)
            strongSelf.presentInGlobalOverlay(contextController)
        }
        
        let context = self.context
        let peerIdsAndOptions: Signal<(ChatListSelectionOptions, Set<PeerId>)?, NoError> = self.chatListDisplayNode.containerNode.currentItemState
        |> map { state -> Set<PeerId>? in
            if !state.editing {
                return nil
            }
            return state.selectedPeerIds
        }
        |> distinctUntilChanged
        |> mapToSignal { selectedPeerIds -> Signal<(ChatListSelectionOptions, Set<PeerId>)?, NoError> in
            if let selectedPeerIds = selectedPeerIds {
                return chatListSelectionOptions(postbox: context.account.postbox, peerIds: selectedPeerIds)
                |> map { options -> (ChatListSelectionOptions, Set<PeerId>)? in
                    return (options, selectedPeerIds)
                }
            } else {
                return .single(nil)
            }
        }
        
        self.stateDisposable.set(combineLatest(queue: .mainQueue(),
            self.presentationDataValue.get(),
            peerIdsAndOptions
        ).start(next: { [weak self] presentationData, peerIdsAndOptions in
            guard let strongSelf = self else {
                return
            }
            var toolbar: Toolbar?
            if case .root = strongSelf.groupId {
                if let (options, peerIds) = peerIdsAndOptions {
                    let leftAction: ToolbarAction
                    switch options.read {
                    case let .all(enabled):
                        leftAction = ToolbarAction(title: presentationData.strings.ChatList_ReadAll, isEnabled: enabled)
                    case let .selective(enabled):
                        leftAction = ToolbarAction(title: presentationData.strings.ChatList_Read, isEnabled: enabled)
                    }
                    var archiveEnabled = options.delete
                    if archiveEnabled && strongSelf.filter == nil {
                        for peerId in peerIds {
                            if peerId == PeerId(namespace: Namespaces.Peer.CloudUser, id: 777000) {
                                archiveEnabled = false
                                break
                            } else if peerId == strongSelf.context.account.peerId {
                                archiveEnabled = false
                                break
                            }
                        }
                    }
                    toolbar = Toolbar(leftAction: leftAction, rightAction: ToolbarAction(title: presentationData.strings.Common_Delete, isEnabled: options.delete), middleAction: strongSelf.chatListDisplayNode.containerNode.currentItemNode.chatListFilter != nil ? nil : ToolbarAction(title: presentationData.strings.ChatList_ArchiveAction, isEnabled: archiveEnabled))
                }
            } else {
                if let (options, peerIds) = peerIdsAndOptions {
                    let middleAction = ToolbarAction(title: presentationData.strings.ChatList_UnarchiveAction, isEnabled: !peerIds.isEmpty)
                    let leftAction: ToolbarAction
                    switch options.read {
                        case .all:
                            leftAction = ToolbarAction(title: presentationData.strings.ChatList_Read, isEnabled: false)
                        case let .selective(enabled):
                            leftAction = ToolbarAction(title: presentationData.strings.ChatList_Read, isEnabled: enabled)
                    }
                    toolbar = Toolbar(leftAction: leftAction, rightAction: ToolbarAction(title: presentationData.strings.Common_Delete, isEnabled: options.delete), middleAction: middleAction)
                }
            }
            strongSelf.setToolbar(toolbar, transition: .animated(duration: 0.3, curve: .easeInOut))
        }))
        
        self.ready.set(self.chatListDisplayNode.containerNode.ready)
        
        self.displayNodeDidLoad()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        guard case .root = self.groupId else {
            return
        }
        
        #if false && DEBUG
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.0, execute: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            let count = ChatControllerCount.with({ $0 })
            if count != 0 {
                strongSelf.present(textAlertController(context: strongSelf.context, title: "", text: "ChatControllerCount \(count)", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
            }
        })
        #endif

        if let lockViewFrame = self.titleView.lockViewFrame, !self.didShowPasscodeLockTooltipController {
            self.passcodeLockTooltipDisposable.set(combineLatest(queue: .mainQueue(), ApplicationSpecificNotice.getPasscodeLockTips(accountManager: self.context.sharedContext.accountManager), self.context.sharedContext.accountManager.accessChallengeData() |> take(1)).start(next: { [weak self] tooltipValue, passcodeView in
                    if let strongSelf = self {
                        if !tooltipValue {
                            let hasPasscode = passcodeView.data.isLockable
                            if hasPasscode {
                                let _ = ApplicationSpecificNotice.setPasscodeLockTips(accountManager: strongSelf.context.sharedContext.accountManager).start()
                                
                                let tooltipController = TooltipController(content: .text(strongSelf.presentationData.strings.DialogList_PasscodeLockHelp), baseFontSize: strongSelf.presentationData.listsFontSize.baseDisplaySize, dismissByTapOutside: true)
                                strongSelf.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceViewAndRect: { [weak self] in
                                    if let strongSelf = self {
                                        return (strongSelf.titleView, lockViewFrame.offsetBy(dx: 4.0, dy: 14.0))
                                    }
                                    return nil
                                }))
                                strongSelf.didShowPasscodeLockTooltipController = true
                            }
                        } else {
                            strongSelf.didShowPasscodeLockTooltipController = true
                        }
                    }
                }))
        }
        
        if !self.didSuggestLocalization {
            self.didSuggestLocalization = true
            
            let network = self.context.account.network
            let signal = combineLatest(self.context.sharedContext.accountManager.transaction { transaction -> String in
                let languageCode: String
                if let current = transaction.getSharedData(SharedDataKeys.localizationSettings) as? LocalizationSettings {
                    let code = current.primaryComponent.languageCode
                    let rawSuffix = "-raw"
                    if code.hasSuffix(rawSuffix) {
                        languageCode = String(code.dropLast(rawSuffix.count))
                    } else {
                        languageCode = code
                    }
                } else {
                    languageCode = "en"
                }
                return languageCode
            }, self.context.account.postbox.transaction { transaction -> SuggestedLocalizationEntry? in
                var suggestedLocalization: SuggestedLocalizationEntry?
                if let localization = transaction.getPreferencesEntry(key: PreferencesKeys.suggestedLocalization) as? SuggestedLocalizationEntry {
                    suggestedLocalization = localization
                }
                return suggestedLocalization
            })
            |> mapToSignal({ value -> Signal<(String, SuggestedLocalizationInfo)?, NoError> in
                guard let suggestedLocalization = value.1, !suggestedLocalization.isSeen && suggestedLocalization.languageCode != "en" && suggestedLocalization.languageCode != value.0 else {
                    return .single(nil)
                }
                return suggestedLocalizationInfo(network: network, languageCode: suggestedLocalization.languageCode, extractKeys: LanguageSuggestionControllerStrings.keys)
                |> map({ suggestedLocalization -> (String, SuggestedLocalizationInfo)? in
                    return (value.0, suggestedLocalization)
                })
            })
        
            self.suggestLocalizationDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] suggestedLocalization in
                guard let strongSelf = self, let (currentLanguageCode, suggestedLocalization) = suggestedLocalization else {
                    return
                }
                if let controller = languageSuggestionController(context: strongSelf.context, suggestedLocalization: suggestedLocalization, currentLanguageCode: currentLanguageCode, openSelection: { [weak self] in
                    if let strongSelf = self {
                        let controller = strongSelf.context.sharedContext.makeLocalizationListController(context: strongSelf.context)
                        (strongSelf.navigationController as? NavigationController)?.pushViewController(controller)
                    }
                }) {
                    strongSelf.present(controller, in: .window(.root))
                    _ = markSuggestedLocalizationAsSeenInteractively(postbox: strongSelf.context.account.postbox, languageCode: suggestedLocalization.languageCode).start()
                }
            }))
        }
        
        self.chatListDisplayNode.containerNode.addedVisibleChatsWithPeerIds = { [weak self] peerIds in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.forEachController({ controller in
                if let controller = controller as? UndoOverlayController {
                    switch controller.content {
                        case let .archivedChat(archivedChat):
                            if peerIds.contains(PeerId(archivedChat.peerId)) {
                                controller.dismiss()
                            }
                        default:
                            break
                    }
                }
                return true
            })
        }
    }
    
    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            return true
        })
    }
    
    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        if self.dismissSearchOnDisappear {
            self.dismissSearchOnDisappear = false
            self.deactivateSearch(animated: false)
        }
        
        self.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        let wasInVoiceOver = self.validLayout?.inVoiceOver ?? false
        
        self.validLayout = layout
        
        var tabContainerOffset: CGFloat = 0.0
        if !self.displayNavigationBar {
            tabContainerOffset += layout.statusBarHeight ?? 0.0
            tabContainerOffset += 44.0 + 44.0 + 44.0
        }
        
        transition.updateFrame(node: self.tabContainerNode, frame: CGRect(origin: CGPoint(x: 0.0, y: self.visualNavigationInsetHeight - self.additionalHeight - 46.0 + tabContainerOffset), size: CGSize(width: layout.size.width, height: 46.0)))
        self.tabContainerNode.update(size: CGSize(width: layout.size.width, height: 46.0), sideInset: layout.safeInsets.left, filters: self.tabContainerData ?? [], selectedFilter: self.chatListDisplayNode.containerNode.currentItemFilter, transitionFraction: self.chatListDisplayNode.containerNode.transitionFraction, presentationData: self.presentationData, transition: .animated(duration: 0.4, curve: .spring))
        
        if let searchContentNode = self.searchContentNode, layout.inVoiceOver != wasInVoiceOver {
            searchContentNode.updateListVisibleContentOffset(.known(0.0))
            self.chatListDisplayNode.scrollToTop()
        }
        
        self.chatListDisplayNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationInsetHeight, visualNavigationHeight: self.visualNavigationInsetHeight, cleanNavigationBarHeight: self.cleanNavigationHeight, transition: transition)
    }
    
    override public func navigationStackConfigurationUpdated(next: [ViewController]) {
        super.navigationStackConfigurationUpdated(next: next)
    }
    
    @objc private func editPressed() {
        let editItem = UIBarButtonItem(title: self.presentationData.strings.Common_Done, style: .done, target: self, action: #selector(self.donePressed))
        editItem.accessibilityLabel = self.presentationData.strings.Common_Done
        if case .root = self.groupId, self.filter == nil {
            self.navigationItem.leftBarButtonItem = editItem
            (self.navigationController as? NavigationController)?.updateMasterDetailsBlackout(.details, transition: .animated(duration: 0.5, curve: .spring))
        } else {
            self.navigationItem.rightBarButtonItem = editItem
            (self.navigationController as? NavigationController)?.updateMasterDetailsBlackout(.master, transition: .animated(duration: 0.5, curve: .spring))
        }
        self.searchContentNode?.setIsEnabled(false, animated: true)
        
        self.chatListDisplayNode.containerNode.updateState { state in
            var state = state
            state.editing = true
            state.peerIdWithRevealedOptions = nil
            return state
        }
    }
    
    @objc private func donePressed() {
        let editItem = UIBarButtonItem(title: self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))
        editItem.accessibilityLabel = self.presentationData.strings.Common_Edit
        if case .root = self.groupId, self.filter == nil {
            self.navigationItem.leftBarButtonItem = editItem
        } else {
            self.navigationItem.rightBarButtonItem = editItem
        }
        (self.navigationController as? NavigationController)?.updateMasterDetailsBlackout(nil, transition: .animated(duration: 0.4, curve: .spring))
        self.searchContentNode?.setIsEnabled(true, animated: true)
        self.chatListDisplayNode.containerNode.updateState { state in
            var state = state
            state.editing = false
            state.peerIdWithRevealedOptions = nil
            state.selectedPeerIds.removeAll()
            return state
        }
    }
    
    public func activateSearch() {
        if self.displayNavigationBar {
            let _ = (self.chatListDisplayNode.containerNode.currentItemNode.contentsReady
            |> take(1)
            |> deliverOnMainQueue).start(completed: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if let scrollToTop = strongSelf.scrollToTop {
                    scrollToTop()
                }
                if let searchContentNode = strongSelf.searchContentNode {
                    strongSelf.chatListDisplayNode.activateSearch(placeholderNode: searchContentNode.placeholderNode)
                }
                strongSelf.setDisplayNavigationBar(false, transition: .animated(duration: 0.5, curve: .spring))
            })
        }
    }
    
    public func deactivateSearch(animated: Bool) {
        if !self.displayNavigationBar {
            self.setDisplayNavigationBar(true, transition: animated ? .animated(duration: 0.5, curve: .spring) : .immediate)
            if let searchContentNode = self.searchContentNode {
                self.chatListDisplayNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode, animated: animated)
            }
        }
    }
    
    public func activateCompose() {
        self.composePressed()
    }
    
    @objc private func composePressed() {
        let controller = self.context.sharedContext.makeComposeController(context: self.context)
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }
    
    public func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController? {
        if #available(iOSApplicationExtension 9.0, iOS 9.0, *) {
            if let (controller, rect) = self.previewingController(from: previewingContext.sourceView, for: location) {
                previewingContext.sourceRect = rect
                return controller
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    func previewingController(from sourceView: UIView, for location: CGPoint) -> (UIViewController, CGRect)? {
        guard let layout = self.validLayout, case .phone = layout.deviceMetrics.type else {
            return nil
        }
        
        let boundsSize = self.view.bounds.size
        let contentSize: CGSize
        if case .unknown = layout.deviceMetrics {
            contentSize = boundsSize
        } else {
            contentSize = layout.deviceMetrics.previewingContentSize(inLandscape: boundsSize.width > boundsSize.height)
        }

        if let searchController = self.chatListDisplayNode.searchDisplayController {
            if let (view, bounds, action) = searchController.previewViewAndActionAtLocation(location) {
                if let peerId = action as? PeerId, peerId.namespace != Namespaces.Peer.SecretChat {
                    var sourceRect = view.superview!.convert(view.frame, to: sourceView)
                    sourceRect = CGRect(x: sourceRect.minX, y: sourceRect.minY + bounds.minY, width: bounds.width, height: bounds.height)
                    sourceRect.size.height -= UIScreenPixel
                    
                    let chatController = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(peerId), subject: nil, botStart: nil, mode: .standard(previewing: true))
                    chatController.canReadHistory.set(false)
                    chatController.containerLayoutUpdated(ContainerViewLayout(size: contentSize, metrics: LayoutMetrics(), deviceMetrics: layout.deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false), transition: .immediate)
                    return (chatController, sourceRect)
                } else if let messageId = action as? MessageId, messageId.peerId.namespace != Namespaces.Peer.SecretChat {
                    var sourceRect = view.superview!.convert(view.frame, to: sourceView)
                    sourceRect = CGRect(x: sourceRect.minX, y: sourceRect.minY + bounds.minY, width: bounds.width, height: bounds.height)
                    sourceRect.size.height -= UIScreenPixel
                    
                    let chatController = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(messageId.peerId), subject: .message(messageId), botStart: nil, mode: .standard(previewing: true))
                    chatController.canReadHistory.set(false)
                    chatController.containerLayoutUpdated(ContainerViewLayout(size: contentSize, metrics: LayoutMetrics(), deviceMetrics: layout.deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false), transition: .immediate)
                    return (chatController, sourceRect)
                }
            }
            return nil
        }
        
        let listLocation = self.view.convert(location, to: self.chatListDisplayNode.containerNode.currentItemNode.view)
        
        var selectedNode: ChatListItemNode?
        self.chatListDisplayNode.containerNode.currentItemNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ChatListItemNode, itemNode.frame.contains(listLocation), !itemNode.isDisplayingRevealedOptions {
                selectedNode = itemNode
            }
        }
        if let selectedNode = selectedNode, let item = selectedNode.item {
            var sourceRect = selectedNode.view.superview!.convert(selectedNode.frame, to: sourceView)
            sourceRect.size.height -= UIScreenPixel
            switch item.content {
                case let .peer(_, peer, _, _, _, _, _, _, _, _, _, _):
                    if peer.peerId.namespace != Namespaces.Peer.SecretChat {
                        let chatController = self.context.sharedContext.makeChatController(context: self.context, chatLocation: .peer(peer.peerId), subject: nil, botStart: nil, mode: .standard(previewing: true))
                        chatController.canReadHistory.set(false)
                        chatController.containerLayoutUpdated(ContainerViewLayout(size: contentSize, metrics: LayoutMetrics(), deviceMetrics: layout.deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false), transition: .immediate)
                        return (chatController, sourceRect)
                    } else {
                        return nil
                    }
                case let .groupReference(groupId, _, _, _, _):
                    let chatListController = ChatListControllerImpl(context: self.context, groupId: groupId, controlsHistoryPreload: false, enableDebugActions: false)
                    chatListController.navigationPresentation = .master
                    chatListController.containerLayoutUpdated(ContainerViewLayout(size: contentSize, metrics: LayoutMetrics(), deviceMetrics: layout.deviceMetrics, intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, inputHeightIsInteractivellyChanging: false, inVoiceOver: false), transition: .immediate)
                    return (chatListController, sourceRect)
            }
        } else {
            return nil
        }
    }
    
    public func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController) {
        self.previewingCommit(viewControllerToCommit)
    }
    
    func previewingCommit(_ viewControllerToCommit: UIViewController) {
        if let viewControllerToCommit = viewControllerToCommit as? ViewController {
            if let chatController = viewControllerToCommit as? ChatController {
                chatController.canReadHistory.set(true)
                chatController.updatePresentationMode(.standard(previewing: false))
                if let navigationController = self.navigationController as? NavigationController {
                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, chatController: chatController, context: self.context, chatLocation: chatController.chatLocation, animated: false))
                    self.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
                }
            } else if let chatListController = viewControllerToCommit as? ChatListController {
                if let navigationController = self.navigationController as? NavigationController {
                    navigationController.pushViewController(chatListController, animated: false, completion: {})
                    self.chatListDisplayNode.containerNode.currentItemNode.clearHighlightAnimated(true)
                }
            }
        }
    }
    
    public override var keyShortcuts: [KeyShortcut] {
        let strings = self.presentationData.strings
        
        let toggleSearch: () -> Void = { [weak self] in
            if let strongSelf = self {
                if strongSelf.displayNavigationBar {
                    strongSelf.activateSearch()
                } else {
                    strongSelf.deactivateSearch(animated: true)
                }
            }
        }
        
        let inputShortcuts: [KeyShortcut] = [
            KeyShortcut(title: strings.KeyCommand_JumpToPreviousChat, input: UIKeyCommand.inputUpArrow, modifiers: [.alternate], action: { [weak self] in
                if let strongSelf = self {
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.selectChat(.previous(unread: false))
                }
            }),
            KeyShortcut(title: strings.KeyCommand_JumpToNextChat, input: UIKeyCommand.inputDownArrow, modifiers: [.alternate], action: { [weak self] in
                if let strongSelf = self {
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.selectChat(.next(unread: false))
                }
            }),
            KeyShortcut(title: strings.KeyCommand_JumpToPreviousUnreadChat, input: UIKeyCommand.inputUpArrow, modifiers: [.alternate, .shift], action: { [weak self] in
                if let strongSelf = self {
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.selectChat(.previous(unread: true))
                }
            }),
            KeyShortcut(title: strings.KeyCommand_JumpToNextUnreadChat, input: UIKeyCommand.inputDownArrow, modifiers: [.alternate, .shift], action: { [weak self] in
                if let strongSelf = self {
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.selectChat(.next(unread: true))
                }
            }),
            KeyShortcut(title: strings.KeyCommand_NewMessage, input: "N", modifiers: [.command], action: { [weak self] in
                if let strongSelf = self {
                    strongSelf.composePressed()
                }
            }),
            KeyShortcut(title: strings.KeyCommand_Find, input: "\t", modifiers: [], action: toggleSearch),
            KeyShortcut(input: UIKeyCommand.inputEscape, modifiers: [], action: toggleSearch)
        ]
        
        let openChat: (Int) -> Void = { [weak self] index in
            if let strongSelf = self {
                if index == 0 {
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.selectChat(.peerId(strongSelf.context.account.peerId))
                } else {
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.selectChat(.index(index - 1))
                }
            }
        }
        
        let chatShortcuts: [KeyShortcut] = (0 ... 9).map { index in
            return KeyShortcut(input: "\(index)", modifiers: [.command], action: {
                openChat(index)
            })
        }
        
        return inputShortcuts + chatShortcuts
    }
    
    override public func toolbarActionSelected(action: ToolbarActionOption) {
        let peerIds = self.chatListDisplayNode.containerNode.currentItemNode.currentState.selectedPeerIds
        if case .left = action {
            let signal: Signal<Void, NoError>
            let context = self.context
            if !peerIds.isEmpty {
                signal = self.context.account.postbox.transaction { transaction -> Void in
                    for peerId in peerIds {
                        togglePeerUnreadMarkInteractively(transaction: transaction, viewTracker: context.account.viewTracker, peerId: peerId, setToValue: false)
                    }
                }
            } else {
                let groupId = self.groupId
                signal = self.context.account.postbox.transaction { transaction -> Void in
                    markAllChatsAsReadInteractively(transaction: transaction, viewTracker: context.account.viewTracker, groupId: groupId, filterPredicate: (self.chatListDisplayNode.containerNode.currentItemNode.chatListFilter?.data).flatMap(chatListFilterPredicate))
                }
            }
            let _ = (signal
            |> deliverOnMainQueue).start(completed: { [weak self] in
                self?.donePressed()
            })
        } else if case .right = action, !peerIds.isEmpty {
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            var items: [ActionSheetItem] = []
            items.append(ActionSheetButtonItem(title: self.presentationData.strings.ChatList_DeleteConfirmation(Int32(peerIds.count)), color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                
                guard let strongSelf = self else {
                    return
                }
                
                strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                    var state = state
                    for peerId in peerIds {
                        state.pendingRemovalPeerIds.insert(peerId)
                    }
                    return state
                })
                
                let text = strongSelf.presentationData.strings.ChatList_DeletedChats(Int32(peerIds.count))
                
                strongSelf.present(UndoOverlayController(presentationData: strongSelf.context.sharedContext.currentPresentationData.with { $0 }, content: .removedChat(text: text), elevatedLayout: false, animateInAsReplacement: true, action: { value in
                    guard let strongSelf = self else {
                        return false
                    }
                    if value == .commit {
                        let context = strongSelf.context
                        let presentationData = strongSelf.presentationData
                        let progressSignal = Signal<Never, NoError> { subscriber in
                            let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                            self?.present(controller, in: .window(.root))
                            return ActionDisposable { [weak controller] in
                                Queue.mainQueue().async() {
                                    controller?.dismiss()
                                }
                            }
                        }
                        |> runOn(Queue.mainQueue())
                        |> delay(0.8, queue: Queue.mainQueue())
                        let progressDisposable = progressSignal.start()
                        
                        let signal: Signal<Void, NoError> = strongSelf.context.account.postbox.transaction { transaction -> Void in
                            for peerId in peerIds {
                                removePeerChat(account: context.account, transaction: transaction, mediaBox: context.account.postbox.mediaBox, peerId: peerId, reportChatSpam: false, deleteGloballyIfPossible: false)
                            }
                        }
                        |> afterDisposed {
                            Queue.mainQueue().async {
                                progressDisposable.dispose()
                            }
                        }
                        let _ = (signal
                        |> deliverOnMainQueue).start()
                        return true
                    } else if value == .undo {
                        strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerIds.first!)
                        strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                            var state = state
                            for peerId in peerIds {
                                state.pendingRemovalPeerIds.remove(peerId)
                            }
                            return state
                        })
                        self?.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerIds.first!)
                        return true
                    }
                    return false
                }), in: .current)
                
                strongSelf.donePressed()
            }))
            
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])
            ])
            self.present(actionSheet, in: .window(.root))
        } else if case .middle = action, !peerIds.isEmpty {
            if case .root = self.groupId {
                self.donePressed()
                self.archiveChats(peerIds: Array(peerIds))
            } else {
                if !peerIds.isEmpty {
                    self.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerIds.first!)
                    let _ = (self.context.account.postbox.transaction { transaction -> Void in
                        for peerId in peerIds {
                            updatePeerGroupIdInteractively(transaction: transaction, peerId: peerId, groupId: .root)
                        }
                    }
                    |> deliverOnMainQueue).start(completed: { [weak self] in
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
                        strongSelf.donePressed()
                    })
                }
            }
        }
    }
    
    func toggleArchivedFolderHiddenByDefault() {
        let _ = (self.context.account.postbox.transaction { transaction -> Bool in
            var updatedValue = false
            updateChatArchiveSettings(transaction: transaction, { settings in
                var settings = settings
                settings.isHiddenByDefault = !settings.isHiddenByDefault
                updatedValue = settings.isHiddenByDefault
                return settings
            })
            return updatedValue
        }
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            strongSelf.chatListDisplayNode.containerNode.updateState { state in
                var state = state
                if value {
                    state.archiveShouldBeTemporaryRevealed = false
                }
                state.peerIdWithRevealedOptions = nil
                return state
            }
            strongSelf.forEachController({ controller in
                if let controller = controller as? UndoOverlayController {
                    controller.dismissWithCommitActionAndReplacementAnimation()
                }
                return true
            })
            
            if value {
                strongSelf.present(UndoOverlayController(presentationData: strongSelf.context.sharedContext.currentPresentationData.with { $0 }, content: .hidArchive(title: strongSelf.presentationData.strings.ChatList_UndoArchiveHiddenTitle, text: strongSelf.presentationData.strings.ChatList_UndoArchiveHiddenText, undo: false), elevatedLayout: false, animateInAsReplacement: true, action: { [weak self] value in
                    guard let strongSelf = self else {
                        return false
                    }
                    if value == .undo {
                        let _ = (strongSelf.context.account.postbox.transaction { transaction -> Bool in
                            var updatedValue = false
                            updateChatArchiveSettings(transaction: transaction, { settings in
                                var settings = settings
                                settings.isHiddenByDefault = false
                                updatedValue = settings.isHiddenByDefault
                                return settings
                            })
                            return updatedValue
                        }).start()
                        return true
                    }
                    return false
                }), in: .current)
            } else {
                strongSelf.present(UndoOverlayController(presentationData: strongSelf.context.sharedContext.currentPresentationData.with { $0 }, content: .revealedArchive(title: strongSelf.presentationData.strings.ChatList_UndoArchiveRevealedTitle, text: strongSelf.presentationData.strings.ChatList_UndoArchiveRevealedText, undo: false), elevatedLayout: false, animateInAsReplacement: true, action: { _ in return false
                }), in: .current)
            }
        })
    }
    
    func deletePeerChat(peerId: PeerId) {
        let _ = (self.context.account.postbox.transaction { transaction -> RenderedPeer? in
            guard let peer = transaction.getPeer(peerId) else {
                return nil
            }
            if let associatedPeerId = peer.associatedPeerId {
                if let associatedPeer = transaction.getPeer(associatedPeerId) {
                    return RenderedPeer(peerId: peerId, peers: SimpleDictionary([peer.id: peer, associatedPeer.id: associatedPeer]))
                } else {
                    return nil
                }
            } else {
                return RenderedPeer(peer: peer)
            }
        }
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let strongSelf = self, let peer = peer, let chatPeer = peer.peers[peer.peerId], let mainPeer = peer.chatMainPeer else {
                return
            }
            
            var canRemoveGlobally = false
            let limitsConfiguration = strongSelf.context.currentLimitsConfiguration.with { $0 }
            if peer.peerId.namespace == Namespaces.Peer.CloudUser && peer.peerId != strongSelf.context.account.peerId {
                if limitsConfiguration.maxMessageRevokeIntervalInPrivateChats == LimitsConfiguration.timeIntervalForever {
                    canRemoveGlobally = true
                }
            }
            
            if let user = chatPeer as? TelegramUser, user.botInfo == nil, canRemoveGlobally {
                strongSelf.maybeAskForPeerChatRemoval(peer: peer, completion: { _ in }, removed: {})
            } else {
                let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                var items: [ActionSheetItem] = []
                var canClear = true
                var canStop = false
                
                var deleteTitle = strongSelf.presentationData.strings.Common_Delete
                if let channel = chatPeer as? TelegramChannel {
                    if case .broadcast = channel.info {
                        canClear = false
                        deleteTitle = strongSelf.presentationData.strings.Channel_LeaveChannel
                    } else {
                        deleteTitle = strongSelf.presentationData.strings.Group_LeaveGroup
                    }
                    if let addressName = channel.addressName, !addressName.isEmpty {
                        canClear = false
                    }
                } else if let user = chatPeer as? TelegramUser, user.botInfo != nil {
                    canStop = !user.flags.contains(.isSupport)
                    canClear = user.botInfo == nil
                    deleteTitle = strongSelf.presentationData.strings.ChatList_DeleteChat
                } else if let _ = chatPeer as? TelegramSecretChat {
                    deleteTitle = strongSelf.presentationData.strings.ChatList_DeleteChat
                }
                
                var canRemoveGlobally = false
                let limitsConfiguration = strongSelf.context.currentLimitsConfiguration.with { $0 }
                if chatPeer is TelegramUser && chatPeer.id != strongSelf.context.account.peerId {
                    if limitsConfiguration.maxMessageRevokeIntervalInPrivateChats == LimitsConfiguration.timeIntervalForever {
                        canRemoveGlobally = true
                    }
                }
                
                items.append(DeleteChatPeerActionSheetItem(context: strongSelf.context, peer: mainPeer, chatPeer: chatPeer, action: .delete, strings: strongSelf.presentationData.strings, nameDisplayOrder: strongSelf.presentationData.nameDisplayOrder))
                if canClear {
                    items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.DialogList_ClearHistoryConfirmation, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        
                        guard let strongSelf = self else {
                            return
                        }
                        
                        let beginClear: (InteractiveHistoryClearingType) -> Void = { type in
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                                var state = state
                                state.pendingClearHistoryPeerIds.insert(peer.peerId)
                                return state
                            })
                            strongSelf.forEachController({ controller in
                                if let controller = controller as? UndoOverlayController {
                                    controller.dismissWithCommitActionAndReplacementAnimation()
                                }
                                return true
                            })
                            
                            strongSelf.present(UndoOverlayController(presentationData: strongSelf.context.sharedContext.currentPresentationData.with { $0 }, content: .removedChat(text: strongSelf.presentationData.strings.Undo_ChatCleared), elevatedLayout: false, animateInAsReplacement: true, action: { value in
                                guard let strongSelf = self else {
                                    return false
                                }
                                if value == .commit {
                                    let _ = clearHistoryInteractively(postbox: strongSelf.context.account.postbox, peerId: peerId, type: type).start(completed: {
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                                            var state = state
                                            state.pendingClearHistoryPeerIds.remove(peer.peerId)
                                            return state
                                        })
                                    })
                                    return true
                                } else if value == .undo {
                                    strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                                        var state = state
                                        state.pendingClearHistoryPeerIds.remove(peer.peerId)
                                        return state
                                    })
                                    return true
                                }
                                return false
                            }), in: .current)
                        }
                        
                        if canRemoveGlobally {
                            let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                            var items: [ActionSheetItem] = []
                            
                            items.append(DeleteChatPeerActionSheetItem(context: strongSelf.context, peer: mainPeer, chatPeer: chatPeer, action: .clearHistory, strings: strongSelf.presentationData.strings, nameDisplayOrder: strongSelf.presentationData.nameDisplayOrder))
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.ChatList_DeleteForEveryone(mainPeer.compactDisplayTitle).0, color: .destructive, action: { [weak actionSheet] in
                                beginClear(.forEveryone)
                                actionSheet?.dismissAnimated()
                            }))
                            items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.ChatList_DeleteForCurrentUser, color: .destructive, action: { [weak actionSheet] in
                                beginClear(.forLocalPeer)
                                actionSheet?.dismissAnimated()
                            }))
                            
                            actionSheet.setItemGroups([
                                ActionSheetItemGroup(items: items),
                                ActionSheetItemGroup(items: [
                                    ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                                        actionSheet?.dismissAnimated()
                                    })
                                ])
                            ])
                            strongSelf.present(actionSheet, in: .window(.root))
                        } else {
                            strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationTitle, text: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationText, actions: [
                                TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                                }),
                                TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationAction, action: {
                                    beginClear(.forLocalPeer)
                                })
                            ], parseMarkdown: true), in: .window(.root))
                        }
                    }))
                }
                
                items.append(ActionSheetButtonItem(title: deleteTitle, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let strongSelf = self else {
                        return
                    }
                    
                    strongSelf.maybeAskForPeerChatRemoval(peer: peer, completion: { _ in }, removed: {})
                }))
                
                if canStop {
                    items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.DialogList_DeleteBotConversationConfirmation, color: .destructive, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        
                        if let strongSelf = self {
                            strongSelf.maybeAskForPeerChatRemoval(peer: peer, completion: { _ in
                            }, removed: {
                                guard let strongSelf = self else {
                                    return
                                }
                                let _ = requestUpdatePeerIsBlocked(account: strongSelf.context.account, peerId: peer.peerId, isBlocked: true).start()
                            })
                        }
                    }))
                }
                
                actionSheet.setItemGroups([ActionSheetItemGroup(items: items),
                        ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])
                ])
                strongSelf.present(actionSheet, in: .window(.root))
            }
        })
    }
    
    public func maybeAskForPeerChatRemoval(peer: RenderedPeer, deleteGloballyIfPossible: Bool = false, completion: @escaping (Bool) -> Void, removed: @escaping () -> Void) {
        guard let chatPeer = peer.peers[peer.peerId], let mainPeer = peer.chatMainPeer else {
            completion(false)
            return
        }
        var canRemoveGlobally = false
        let limitsConfiguration = self.context.currentLimitsConfiguration.with { $0 }
        if peer.peerId.namespace == Namespaces.Peer.CloudUser && peer.peerId != self.context.account.peerId {
            if limitsConfiguration.maxMessageRevokeIntervalInPrivateChats == LimitsConfiguration.timeIntervalForever {
                canRemoveGlobally = true
            }
        }
        if let user = chatPeer as? TelegramUser, user.botInfo != nil {
            canRemoveGlobally = false
        }
        
        if canRemoveGlobally {
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            var items: [ActionSheetItem] = []
            
            items.append(DeleteChatPeerActionSheetItem(context: self.context, peer: mainPeer, chatPeer: chatPeer, action: .delete, strings: self.presentationData.strings, nameDisplayOrder: self.presentationData.nameDisplayOrder))
            items.append(ActionSheetButtonItem(title: self.presentationData.strings.ChatList_DeleteForEveryone(mainPeer.compactDisplayTitle).0, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                guard let strongSelf = self else {
                    return
                }
                strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: strongSelf.presentationData), title: strongSelf.presentationData.strings.ChatList_DeleteForEveryoneConfirmationTitle, text: strongSelf.presentationData.strings.ChatList_DeleteForEveryoneConfirmationText, actions: [
                    TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                        completion(false)
                    }),
                    TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.ChatList_DeleteForEveryoneConfirmationAction, action: {
                        self?.schedulePeerChatRemoval(peer: peer, type: .forEveryone, deleteGloballyIfPossible: deleteGloballyIfPossible, completion: {
                            removed()
                        })
                        completion(true)
                    })
                ], parseMarkdown: true), in: .window(.root))
            }))
            items.append(ActionSheetButtonItem(title: self.presentationData.strings.ChatList_DeleteForCurrentUser, color: .destructive, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.schedulePeerChatRemoval(peer: peer, type: .forLocalPeer, deleteGloballyIfPossible: deleteGloballyIfPossible, completion: {
                    removed()
                })
                completion(true)
            }))
            
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        completion(false)
                    })
                ])
            ])
            self.present(actionSheet, in: .window(.root))
        } else if peer.peerId == self.context.account.peerId {
            self.present(standardTextAlertController(theme: AlertControllerTheme(presentationData: self.presentationData), title: self.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationTitle, text: self.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationText, actions: [
                TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {
                    completion(false)
                }),
                TextAlertAction(type: .destructiveAction, title: self.presentationData.strings.ChatList_DeleteSavedMessagesConfirmationAction, action: { [weak self] in
                    self?.schedulePeerChatRemoval(peer: peer, type: .forEveryone, deleteGloballyIfPossible: deleteGloballyIfPossible, completion: {
                        removed()
                    })
                    completion(true)
                })
            ], parseMarkdown: true), in: .window(.root))
        } else {
            completion(true)
            self.schedulePeerChatRemoval(peer: peer, type: .forLocalPeer, deleteGloballyIfPossible: deleteGloballyIfPossible, completion: {
                removed()
            })
        }
    }
    
    func archiveChats(peerIds: [PeerId]) {
        guard !peerIds.isEmpty else {
            return
        }
        let postbox = self.context.account.postbox
        self.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerIds[0])
        let _ = (ApplicationSpecificNotice.incrementArchiveChatTips(accountManager: self.context.sharedContext.accountManager, count: 1)
        |> deliverOnMainQueue).start(next: { [weak self] previousHintCount in
            let _ = (postbox.transaction { transaction -> Void in
                for peerId in peerIds {
                    updatePeerGroupIdInteractively(transaction: transaction, peerId: peerId, groupId: Namespaces.PeerGroup.archive)
                }
            }
            |> deliverOnMainQueue).start(completed: {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
        
                for peerId in peerIds {
                    deleteSendMessageIntents(peerId: peerId)
                }
                
                let action: (UndoOverlayAction) -> Bool = { value in
                    guard let strongSelf = self else {
                        return false
                    }
                    if value == .undo {
                        strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerIds[0])
                        let _ = (postbox.transaction { transaction -> Void in
                            for peerId in peerIds {
                                updatePeerGroupIdInteractively(transaction: transaction, peerId: peerId, groupId: .root)
                            }
                        }
                        |> deliverOnMainQueue).start(completed: {
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
                        })
                        return true
                    } else {
                        return false
                    }
                }
        
                strongSelf.forEachController({ controller in
                    if let controller = controller as? UndoOverlayController {
                        controller.dismissWithCommitActionAndReplacementAnimation()
                    }
                    return true
                })
        
                var title = peerIds.count == 1 ? strongSelf.presentationData.strings.ChatList_UndoArchiveTitle : strongSelf.presentationData.strings.ChatList_UndoArchiveMultipleTitle
                let text: String
                let undo: Bool
                switch previousHintCount {
                    case 0:
                        text = strongSelf.presentationData.strings.ChatList_UndoArchiveText1
                        undo = false
                    default:
                        text = title
                        title = ""
                        undo = true
                }
                let controller = UndoOverlayController(presentationData: strongSelf.context.sharedContext.currentPresentationData.with { $0 }, content: .archivedChat(peerId: peerIds[0].toInt64(), title: title, text: text, undo: undo), elevatedLayout: false, animateInAsReplacement: true, action: action)
                strongSelf.present(controller, in: .current)
                
                strongSelf.chatListDisplayNode.playArchiveAnimation()
            })
        })
    }
    
    private func schedulePeerChatRemoval(peer: RenderedPeer, type: InteractiveMessagesDeletionType, deleteGloballyIfPossible: Bool, completion: @escaping () -> Void) {
        guard let chatPeer = peer.peers[peer.peerId] else {
            return
        }
        
        var deleteGloballyIfPossible = deleteGloballyIfPossible
        if case .forEveryone = type {
            deleteGloballyIfPossible = true
        }
        
        let peerId = peer.peerId
        self.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerId)
        self.chatListDisplayNode.containerNode.updateState({ state in
            var state = state
            state.pendingRemovalPeerIds.insert(peer.peerId)
            return state
        })
        self.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
        let statusText: String
        if let channel = chatPeer as? TelegramChannel {
            if deleteGloballyIfPossible {
                if case .broadcast = channel.info {
                    statusText = self.presentationData.strings.Undo_DeletedChannel
                } else {
                    statusText = self.presentationData.strings.Undo_DeletedGroup
                }
            } else {
                if case .broadcast = channel.info {
                    statusText = self.presentationData.strings.Undo_LeftChannel
                } else {
                    statusText = self.presentationData.strings.Undo_LeftGroup
                }
            }
        } else if let _ = chatPeer as? TelegramGroup {
            if deleteGloballyIfPossible {
                statusText = self.presentationData.strings.Undo_DeletedGroup
            } else {
                statusText = self.presentationData.strings.Undo_LeftGroup
            }
        } else if let _ = chatPeer as? TelegramSecretChat {
            statusText = self.presentationData.strings.Undo_SecretChatDeleted
        } else {
            if case .forEveryone = type {
                statusText = self.presentationData.strings.Undo_ChatDeletedForBothSides
            } else {
                statusText = self.presentationData.strings.Undo_ChatDeleted
            }
        }
        
        self.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitActionAndReplacementAnimation()
            }
            return true
        })
        
        self.present(UndoOverlayController(presentationData: self.context.sharedContext.currentPresentationData.with { $0 }, content: .removedChat(text: statusText), elevatedLayout: false, animateInAsReplacement: true, action: { [weak self] value in
            guard let strongSelf = self else {
                return false
            }
            if value == .commit {
                strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerId)
                if let channel = chatPeer as? TelegramChannel {
                    strongSelf.context.peerChannelMemberCategoriesContextsManager.externallyRemoved(peerId: channel.id, memberId: strongSelf.context.account.peerId)
                }
                let _ = removePeerChat(account: strongSelf.context.account, peerId: peerId, reportChatSpam: false, deleteGloballyIfPossible: deleteGloballyIfPossible).start(completed: {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                        var state = state
                        state.pendingRemovalPeerIds.remove(peer.peerId)
                        return state
                    })
                    strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
                    
                    deleteSendMessageIntents(peerId: peerId)
                })
                completion()
                return true
            } else if value == .undo {
                strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(peerId)
                strongSelf.chatListDisplayNode.containerNode.updateState({ state in
                    var state = state
                    state.pendingRemovalPeerIds.remove(peer.peerId)
                    return state
                })
                strongSelf.chatListDisplayNode.containerNode.currentItemNode.setCurrentRemovingPeerId(nil)
                return true
            }
            return false
        }), in: .current)
    }
    
    override public func setToolbar(_ toolbar: Toolbar?, transition: ContainedViewLayoutTransition) {
        if case .root = self.groupId, self.filter == nil {
            super.setToolbar(toolbar, transition: transition)
        } else {
            self.chatListDisplayNode.toolbar = toolbar
            self.requestLayout(transition: transition)
        }
    }
    
    public var lockViewFrame: CGRect? {
        if let lockViewFrame = self.titleView.lockViewFrame {
            return self.titleView.convert(lockViewFrame, to: self.view)
        } else {
            return nil
        }
    }
    
    private func openFilterSettings() {
        self.push(chatListFilterPresetListController(context: self.context, updated: { _ in
        }))
    }
    
    override public func tabBarItemContextAction(sourceNode: ContextExtractedContentContainingNode, gesture: ContextGesture) {
        let _ = (combineLatest(queue: .mainQueue(),
            self.context.account.postbox.transaction { transaction -> [ChatListFilter] in
                let settings = transaction.getPreferencesEntry(key: PreferencesKeys.chatListFilters) as? ChatListFiltersState ?? ChatListFiltersState.default
                return settings.filters
            },
            chatListFilterItems(context: self.context)
            |> take(1)
        )
        |> deliverOnMainQueue).start(next: { [weak self] presetList, filterItemsAndTotalCount in
            guard let strongSelf = self else {
                return
            }
            
            let (_, filterItems) = filterItemsAndTotalCount
            
            var items: [ContextMenuItem] = []
            items.append(.action(ContextMenuActionItem(text: presetList.isEmpty ? "Add Filter" : "Edit Filters", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: theme.contextMenu.primaryColor)
            }, action: { c, f in
                c.dismiss(completion: {
                    guard let strongSelf = self else {
                        return
                    }
                    if presetList.isEmpty {
                        if let navigationController = strongSelf.navigationController as? NavigationController {
                            var viewControllers = navigationController.viewControllers
                            //viewControllers.append(chatListFilterPresetListController(context: strongSelf.context, updated: { _ in }))
                            viewControllers.append(chatListFilterPresetController(context: strongSelf.context, currentPreset: nil, updated: { _ in }))
                            navigationController.setViewControllers(viewControllers, animated: true)
                        }
                    } else {
                        strongSelf.push(chatListFilterPresetListController(context: strongSelf.context, updated: { _ in }))
                    }
                })
            })))
            
            if strongSelf.chatListDisplayNode.containerNode.currentItemNode.chatListFilter != nil {
                items.append(.action(ContextMenuActionItem(text: "All Chats", icon: { theme in
                    return nil
                }, action: { c, f in
                    f(.dismissWithoutContent)
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.tabContainerNode.tabSelected?(.all)
                })))
            }
            
            if !presetList.isEmpty {
                items.append(.separator)
                
                for preset in presetList {
                    enum ChatListFilterType {
                        case generic
                        case unmuted
                        case unread
                        case channels
                        case groups
                        case bots
                        case secretChats
                        case privateChats
                    }
                    let filterType: ChatListFilterType
                    if preset.data.includePeers.isEmpty {
                        if preset.data.categories == .all {
                            if preset.data.excludeRead {
                                filterType = .unread
                            } else if preset.data.excludeMuted {
                                filterType = .unmuted
                            } else {
                                filterType = .generic
                            }
                        } else {
                            if preset.data.categories == .channels {
                                filterType = .channels
                            } else if preset.data.categories.isSubset(of: [.publicGroups, .privateGroups]) {
                                filterType = .groups
                            } else if preset.data.categories == .bots {
                                filterType = .bots
                            } else if preset.data.categories == .secretChats {
                                filterType = .secretChats
                            } else if preset.data.categories == .privateChats {
                                filterType = .privateChats
                            } else {
                                filterType = .generic
                            }
                        }
                    } else {
                        filterType = .generic
                    }
                    var badge = ""
                    for item in filterItems {
                        if item.0.id == preset.id && item.1 != 0 {
                            badge = "\(item.1)"
                        }
                    }
                    items.append(.action(ContextMenuActionItem(text: preset.title ?? "", badge: badge, icon: { theme in
                        let imageName: String
                        switch filterType {
                        case .generic:
                            imageName = "Chat/Context Menu/List"
                        case .unmuted:
                            imageName = "Chat/Context Menu/Unmute"
                        case .unread:
                            imageName = "Chat/Context Menu/MarkAsUnread"
                        case .channels:
                            imageName = "Chat/Context Menu/Channels"
                        case .groups:
                            imageName = "Chat/Context Menu/Groups"
                        case .bots:
                            imageName = "Chat/Context Menu/Bots"
                        case .secretChats:
                            imageName = "Chat/Context Menu/Timer"
                        case .privateChats:
                            imageName = "Chat/Context Menu/User"
                        }
                        return generateTintedImage(image: UIImage(bundleImageName: imageName), color: theme.contextMenu.primaryColor)
                    }, action: { _, f in
                        f(.dismissWithoutContent)
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.tabContainerNode.tabSelected?(.filter(preset.id))
                    })))
                }
            }
            
            let controller = ContextController(account: strongSelf.context.account, presentationData: strongSelf.presentationData, source: .extracted(ChatListTabBarContextExtractedContentSource(controller: strongSelf, sourceNode: sourceNode)), items: .single(items), reactionItems: [], recognizer: nil, gesture: gesture)
            strongSelf.context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
        })
    }
    
    override public func tabBarItemSwipeAction(direction: TabBarItemSwipeDirection) {
        guard let entries = self.tabContainerData, var index = entries.index(where: { $0.id == self.chatListDisplayNode.containerNode.currentItemFilter }) else {
            return
        }
        switch direction {
        case .right:
            if index == 0 {
                index = entries.count - 1
            } else {
                index -= 1
            }
        case .left:
            if index == entries.count - 1 {
                index = 0
            } else {
                index += 1
            }
        }
        self.tabContainerNode.tabSelected?(entries[index].id)
    }
}

private final class ChatListTabBarContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = true
    
    private let controller: ChatListController
    private let sourceNode: ContextExtractedContentContainingNode
    
    init(controller: ChatListController, sourceNode: ContextExtractedContentContainingNode) {
        self.controller = controller
        self.sourceNode = sourceNode
    }
    
    func takeView() -> ContextControllerTakeViewInfo? {
        return ContextControllerTakeViewInfo(contentContainingNode: self.sourceNode, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
    
    func putBack() -> ContextControllerPutBackViewInfo? {
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}

private final class ChatListHeaderBarContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    
    private let controller: ChatListController
    private let sourceNode: ContextExtractedContentContainingNode
    
    init(controller: ChatListController, sourceNode: ContextExtractedContentContainingNode) {
        self.controller = controller
        self.sourceNode = sourceNode
    }
    
    func takeView() -> ContextControllerTakeViewInfo? {
        return ContextControllerTakeViewInfo(contentContainingNode: self.sourceNode, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
    
    func putBack() -> ContextControllerPutBackViewInfo? {
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
