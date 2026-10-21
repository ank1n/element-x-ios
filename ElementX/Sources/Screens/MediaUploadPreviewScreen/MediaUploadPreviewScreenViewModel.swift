//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias MediaUploadPreviewScreenViewModelType = StateStoreViewModelV2<MediaUploadPreviewScreenViewState, MediaUploadPreviewScreenViewAction>

class MediaUploadPreviewScreenViewModel: MediaUploadPreviewScreenViewModelType, MediaUploadPreviewScreenViewModelProtocol {
    private let timelineController: TimelineControllerProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let mediaUploadingPreprocessor: MediaUploadingPreprocessor
    private var mediaURLs: [URL]
    
    private var processingTask: Task<Result<[MediaInfo], MediaUploadingPreprocessorError>, Never>
    private var requestHandle: SendAttachmentJoinHandleProtocol?
    private let roomProxy: JoinedRoomProxyProtocol?
    private var suggestionService: CompletionSuggestionService?
    private let clientProxy: ClientProxyProtocol
    
    private var actionsSubject: PassthroughSubject<MediaUploadPreviewScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<MediaUploadPreviewScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(mediaURLs: [URL],
         title: String?,
         isRoomEncrypted: Bool,
         shouldShowCaptionWarning: Bool,
         mediaUploadingPreprocessor: MediaUploadingPreprocessor,
         timelineController: TimelineControllerProtocol,
         clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         roomProxy: JoinedRoomProxyProtocol? = nil) {
        self.roomProxy = roomProxy
        self.mediaURLs = mediaURLs
        self.mediaUploadingPreprocessor = mediaUploadingPreprocessor
        self.timelineController = timelineController
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        
        // Start processing the media whilst the user is reviewing it/adding a caption.
        processingTask = Self.processMedia(at: mediaURLs, preprocessor: mediaUploadingPreprocessor, clientProxy: clientProxy)
        
        super.init(initialViewState: MediaUploadPreviewScreenViewState(mediaURLs: mediaURLs,
                                                                       title: title,
                                                                       shouldShowCaptionWarning: shouldShowCaptionWarning,
                                                                       isRoomEncrypted: isRoomEncrypted))
        if let roomProxy {
            let service = CompletionSuggestionService(roomProxy: roomProxy, roomListPublisher: Just([RoomSummary]()).eraseToAnyPublisher())
            suggestionService = service
            service.suggestionsPublisher.receive(on: DispatchQueue.main).sink { [weak self] items in
                self?.state.suggestions = items.filter { if case .room = $0.suggestionType { return false }; return true }
            }.store(in: &cancellables)
            Task { _ = await roomProxy.members() }
        }
    }
    
    override func process(viewAction: MediaUploadPreviewScreenViewAction) {
        // Get the current caption before all the processing starts.
        
        switch viewAction {
        case .captionChanged:
            suggestionService?.processTextMessage(state.bindings.caption.string, selectedRange: state.bindings.selectedRange)
        case .selectedSuggestion(let suggestion):
            selectSuggestion(suggestion)
        case .send:
            var caption = MediaUploadCaption(attributed: state.bindings.caption, allowRoomMention: roomProxy?.infoPublisher.value.powerLevels?.canOwnUserTriggerRoomNotification() == true)
            guard !state.shouldDisableInteraction else { return }
            startLoading()
            
            Task {
                defer { stopLoading() }
                
                switch await processingTask.value {
                case .success(let mediaInfos):
                    for mediaInfo in mediaInfos {
                        switch await sendAttachment(mediaInfo: mediaInfo, caption: caption) {
                        case .success:
                            caption = nil // Set the caption only on the first uploaded file.
                        case .failure(let error):
                            MXLog.error("Failed sending media with error: \(error)")
                            showError(label: L10n.screenMediaUploadPreviewErrorFailedSending)
                        }
                    }
                    
                    actionsSubject.send(.dismiss)
                case .failure(.maxUploadSizeUnknown):
                    showAlert(.maxUploadSizeUnknown)
                case .failure(.maxUploadSizeExceeded(let limit)):
                    showAlert(.maxUploadSizeExceeded(limit: limit))
                case .failure(let error):
                    MXLog.error("Failed processing media to upload with error: \(error)")
                    showError(label: L10n.screenMediaUploadPreviewErrorFailedProcessing)
                }
            }
        case .cancel:
            requestHandle?.cancel()
            actionsSubject.send(.dismiss)
        }
    }
    
    func stopProcessing() {
        processingTask.cancel()
    }
    
    // MARK: - Private
    
    private static func processMedia(at urls: [URL],
                                     preprocessor: MediaUploadingPreprocessor,
                                     clientProxy: ClientProxyProtocol) -> Task<Result<[MediaInfo], MediaUploadingPreprocessorError>, Never> {
        Task {
            guard case let .success(maxUploadSize) = await clientProxy.maxMediaUploadSize else { return .failure(.maxUploadSizeUnknown) }
            return await preprocessor.processMedia(at: urls, maxUploadSize: maxUploadSize)
        }
    }
    
    private func sendAttachment(mediaInfo: MediaInfo, caption: MediaUploadCaption?) async -> Result<Void, TimelineControllerError> {
        let current = caption.map { value -> MediaUploadCaption in
            var value = value
            if roomProxy?.infoPublisher.value.powerLevels?.canOwnUserTriggerRoomNotification() != true {
                value.mentions = .init(userIDs: value.mentions.userIDs, atRoom: false)
            }
            return value
        }
        return await timelineController.sendAttachment(mediaInfo, caption: current) { [weak self] in self?.requestHandle = $0 }
    }

    private func selectSuggestion(_ suggestion: SuggestionItem) {
        let text = NSMutableAttributedString(attributedString: state.bindings.caption)
        guard suggestion.range.location >= 0, NSMaxRange(suggestion.range) <= text.length else { return }
        let builder = MentionBuilder()
        switch suggestion.suggestionType {
        case .user(let user):
            guard let url = try? URL(string: matrixToUserPermalink(userId: user.id)) else { return }
            builder.handleUserMention(for: text, in: suggestion.range, url: url, userID: user.id, userDisplayName: user.displayName)
        case .allUsers:
            guard roomProxy?.infoPublisher.value.powerLevels?.canOwnUserTriggerRoomNotification() == true else { return }
            builder.handleAllUsersMention(for: text, in: suggestion.range)
        case .room: return
        }
        state.bindings.caption = text
        state.bindings.selectedRange = NSRange(location: min(suggestion.range.location + 1, text.length), length: 0)
        suggestionService?.setSuggestionTrigger(nil)
        state.suggestions = []
    }

    private static let loadingIndicatorIdentifier = "\(MediaUploadPreviewScreenViewModel.self)-Loading"
    
    private func startLoading() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: false, allowsInteraction: true),
                                                              title: L10n.commonPreparing,
                                                              persistent: true),
                                                delay: .milliseconds(100))
        
        state.shouldDisableInteraction = true
    }
    
    private func stopLoading() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
        state.shouldDisableInteraction = false
        requestHandle = nil
    }
    
    private func showError(label: String) {
        userIndicatorController.submitIndicator(UserIndicator(title: label))
    }
    
    private func showAlert(_ alertType: MediaUploadPreviewAlertType) {
        switch alertType {
        case .maxUploadSizeUnknown:
            state.bindings.alertInfo = .init(id: alertType,
                                             title: L10n.commonSomethingWentWrong,
                                             message: L10n.screenMediaUploadPreviewErrorCouldNotBeUploaded,
                                             primaryButton: .init(title: L10n.actionTryAgain) { [weak self] in
                                                 guard let self else { return }
                                                 processingTask = Self.processMedia(at: mediaURLs, preprocessor: mediaUploadingPreprocessor, clientProxy: clientProxy)
                                                 process(viewAction: .send)
                                             },
                                             secondaryButton: .init(title: L10n.actionCancel, role: .cancel) { })
        case .maxUploadSizeExceeded(let limit):
            state.bindings.alertInfo = .init(id: alertType,
                                             title: L10n.screenMediaUploadPreviewErrorTooLargeTitle,
                                             message: L10n.screenMediaUploadPreviewErrorTooLargeMessage(limit.formatted(.byteCount(style: .file))),
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel) { })
        }
    }
}

extension NSAttributedString {
    var nonBlankString: String? {
        guard !string.isBlank else { return nil }
        return string
    }
}
