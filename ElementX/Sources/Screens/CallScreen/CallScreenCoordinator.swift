//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import SwiftUI

struct CallScreenCoordinatorParameters {
    let elementCallService: ElementCallServiceProtocol
    let configuration: ElementCallConfiguration
    let allowPictureInPicture: Bool
    let appSettings: AppSettings
    let appHooks: AppHooks
    let analytics: AnalyticsService
    let recordingService: RecordingServiceProtocol?
    let mediaProvider: MediaProviderProtocol?
    let localCallHistoryService: LocalCallHistoryServiceProtocol?
    let currentCallID: String?
    var startWithVideoEnabled = true
    /// STMOB-394: lets the call screen opt into landscape while the rest of the app stays portrait.
    let orientationManager: OrientationManagerProtocol
}

enum CallScreenCoordinatorAction {
    /// The call is able to be minimised to picture in picture with the provided controller.
    ///
    /// **Note:** Manually starting the PiP will not trigger the action below as we don't want
    /// to change the app's navigation when backgrounding the app with the call screen visible.
    case pictureInPictureIsAvailable(AVPictureInPictureController)
    /// The call is still ongoing but the user requested to navigate around the app.
    case pictureInPictureStarted
    /// The call is hidden and the user wishes to return to it.
    case pictureInPictureStopped
    /// The user pressed back but PiP is not available; minimize to overlay instead.
    case minimizeCall
    /// The call is finished and the screen is done with.
    case dismiss
}

final class CallScreenCoordinator: CoordinatorProtocol {
    private var viewModel: CallScreenViewModelProtocol
    private let orientationManager: OrientationManagerProtocol
    private let actionsSubject: PassthroughSubject<CallScreenCoordinatorAction, Never> = .init()

    /// sTalk: Current call elapsed time (for banner display)
    var callElapsedTime: TimeInterval {
        viewModel.context.viewState.callElapsedTime
    }

    /// sTalk: Restore call from minimized state (triggered by banner tap)
    func restoreFromMinimized() {
        viewModel.context.send(viewAction: .restoreFromMinimized)
    }
    
    private var cancellables: Set<AnyCancellable> = .init()
    var actions: AnyPublisher<CallScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: CallScreenCoordinatorParameters) {
        viewModel = CallScreenViewModel(elementCallService: parameters.elementCallService,
                                        configuration: parameters.configuration,
                                        allowPictureInPicture: parameters.allowPictureInPicture,
                                        appHooks: parameters.appHooks,
                                        appSettings: parameters.appSettings,
                                        analyticsService: parameters.analytics,
                                        recordingService: parameters.recordingService,
                                        mediaProvider: parameters.mediaProvider,
                                        localCallHistoryService: parameters.localCallHistoryService,
                                        currentCallID: parameters.currentCallID,
                                        startWithVideoEnabled: parameters.startWithVideoEnabled)
        orientationManager = parameters.orientationManager
    }
    
    func start() {
        viewModel.actions.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .pictureInPictureIsAvailable(let controller):
                actionsSubject.send(.pictureInPictureIsAvailable(controller))
            case .pictureInPictureStarted:
                actionsSubject.send(.pictureInPictureStarted)
            case .pictureInPictureStopped:
                actionsSubject.send(.pictureInPictureStopped)
            case .minimizeCall:
                actionsSubject.send(.minimizeCall)
            case .dismiss:
                actionsSubject.send(.dismiss)
            case .showRecordingConsent:
                // Handled in the view via sheet
                break
            }
        }
        .store(in: &cancellables)

        // STMOB-394: allow the device to rotate while the call is on screen
        // (portrait + both landscapes). The rest of the app stays portrait.
        orientationManager.lockOrientation(.allButUpsideDown)
    }

    func stop() {
        viewModel.stop()

        // STMOB-394: snap back to portrait and re-lock it when leaving the call.
        orientationManager.setOrientation(.portrait)
        orientationManager.lockOrientation(.portrait)
    }
        
    func toPresentable() -> AnyView {
        AnyView(CallScreen(context: viewModel.context))
    }
}
