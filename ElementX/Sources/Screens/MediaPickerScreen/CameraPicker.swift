//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import os.log
import SwiftUI
import UIKit

private let cameraLog = OSLog(subsystem: "ru.implica.stalk", category: "Camera")

// MARK: - Public API (unchanged for coordinator)

enum CameraPickerAction {
    case selectFile(URL)
    case cancel
    case error(CameraPickerError)
}

enum CameraPickerError: Error {
    case invalidJpegData
    case invalidOriginalImage
    case failedWritingToTemporaryDirectory
    case captureError(String)
    case noCamera
}

struct CameraPicker: UIViewControllerRepresentable {
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let callback: (CameraPickerAction) -> Void

    init(userIndicatorController: UserIndicatorControllerProtocol,
         callback: @escaping (CameraPickerAction) -> Void) {
        self.userIndicatorController = userIndicatorController
        self.callback = callback
    }

    func makeUIViewController(context: Context) -> StalkCameraViewController {
        let vc = StalkCameraViewController()
        vc.onResult = callback
        return vc
    }

    func updateUIViewController(_ uiViewController: StalkCameraViewController, context: Context) { }
}

// MARK: - Custom Full-Screen Camera (Telegram-style)

final class StalkCameraViewController: UIViewController {
    var onResult: ((CameraPickerAction) -> Void)?

    // Capture session
    private let session = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!

    // State
    private enum CaptureMode { case photo, video }
    private var captureMode: CaptureMode = .photo
    private var isRecording = false
    private var flashMode: AVCaptureDevice.FlashMode = .auto
    private var isUsingFrontCamera = false
    private var recordingTimer: Timer?
    private var recordingSeconds = 0
    private var zoomFactor: CGFloat = 1.0

    // UI elements
    private var previewView: UIView!
    private var shutterButton: ShutterButton!
    private var flashButton: UIButton!
    private var flipButton: UIButton!
    private var closeButton: UIButton!
    private var photoModeButton: UIButton!
    private var videoModeButton: UIButton!
    private var modeIndicator: UIView!
    private var timerLabel: UILabel!
    private var bottomBar: UIView!
    private var topBar: UIView!
    private var modeStack: UIStackView!

    // Zoom control (floats on preview)
    private var zoomContainer: UIView!
    private var zoomButtons: [UIButton] = []
    private let zoomLevels: [CGFloat] = [0.5, 1.0, 2.0, 5.0]
    private let zoomLabels = ["0,5", "1", "2", "5"]

    /// Zoom
    private var initialZoom: CGFloat = 1.0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupPreview()
        setupTopBar()
        setupBottomBar()
        setupGestures()
        checkPermissionsAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    // MARK: - Setup UI

    private func setupPreview() {
        previewView = UIView()
        previewView.backgroundColor = .black
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupTopBar() {
        topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Flash button — simple circle background
        flashButton = UIButton(type: .custom)
        flashButton.translatesAutoresizingMaskIntoConstraints = false
        flashButton.addTarget(self, action: #selector(toggleFlash), for: .touchUpInside)
        flashButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        flashButton.layer.cornerRadius = 20
        flashButton.clipsToBounds = true
        topBar.addSubview(flashButton)

        // Timer label (for video recording)
        timerLabel = UILabel()
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        timerLabel.textColor = .white
        timerLabel.textAlignment = .center
        timerLabel.isHidden = true
        topBar.addSubview(timerLabel)

        // Red dot for recording
        let recDot = UIView()
        recDot.tag = 999
        recDot.translatesAutoresizingMaskIntoConstraints = false
        recDot.backgroundColor = .systemRed
        recDot.layer.cornerRadius = 4
        recDot.isHidden = true
        topBar.addSubview(recDot)

        NSLayoutConstraint.activate([
            flashButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            flashButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            flashButton.widthAnchor.constraint(equalToConstant: 40),
            flashButton.heightAnchor.constraint(equalToConstant: 40),
            timerLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            timerLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            recDot.widthAnchor.constraint(equalToConstant: 8),
            recDot.heightAnchor.constraint(equalToConstant: 8),
            recDot.trailingAnchor.constraint(equalTo: timerLabel.leadingAnchor, constant: -6),
            recDot.centerYAnchor.constraint(equalTo: timerLabel.centerYAnchor)
        ])

        updateFlashIcon()
    }

    private func setupBottomBar() {
        bottomBar = UIView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 220)
        ])

        // Shutter button
        shutterButton = ShutterButton()
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(shutterLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        shutterButton.addGestureRecognizer(longPress)
        bottomBar.addSubview(shutterButton)

        // Close button — circle with X
        closeButton = UIButton(type: .custom)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let xConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        closeButton.layer.cornerRadius = 22
        closeButton.clipsToBounds = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        bottomBar.addSubview(closeButton)

        // Flip camera button — circle
        flipButton = UIButton(type: .custom)
        flipButton.translatesAutoresizingMaskIntoConstraints = false
        let flipConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        flipButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath", withConfiguration: flipConfig), for: .normal)
        flipButton.tintColor = .white
        flipButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        flipButton.layer.cornerRadius = 22
        flipButton.clipsToBounds = true
        flipButton.addTarget(self, action: #selector(flipCamera), for: .touchUpInside)
        bottomBar.addSubview(flipButton)

        // Mode selector (ВИДЕО / ФОТО)
        photoModeButton = makeModeButton(title: SL10n.cameraPhoto)
        videoModeButton = makeModeButton(title: SL10n.cameraVideo)
        photoModeButton.addTarget(self, action: #selector(selectPhotoMode), for: .touchUpInside)
        videoModeButton.addTarget(self, action: #selector(selectVideoMode), for: .touchUpInside)

        modeStack = UIStackView(arrangedSubviews: [videoModeButton, photoModeButton])
        modeStack.axis = .horizontal
        modeStack.spacing = 32
        modeStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(modeStack)

        // Mode underline indicator
        modeIndicator = UIView()
        modeIndicator.backgroundColor = .white
        modeIndicator.layer.cornerRadius = 1.5
        modeIndicator.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(modeIndicator)

        NSLayoutConstraint.activate([
            // Shutter — center
            shutterButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            shutterButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 48),
            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72),

            // Close — left of shutter
            closeButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 40),
            closeButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // Flip — right of shutter
            flipButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -40),
            flipButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            flipButton.widthAnchor.constraint(equalToConstant: 44),
            flipButton.heightAnchor.constraint(equalToConstant: 44),

            // Mode labels — below shutter
            modeStack.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            modeStack.topAnchor.constraint(equalTo: shutterButton.bottomAnchor, constant: 18),

            // Indicator
            modeIndicator.heightAnchor.constraint(equalToConstant: 3),
            modeIndicator.topAnchor.constraint(equalTo: modeStack.bottomAnchor, constant: 4)
        ])

        updateModeSelection(animated: false)

        // Floating zoom control — sits on preview just above bottomBar
        setupZoomControl()
    }

    private func setupZoomControl() {
        zoomContainer = UIView()
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        zoomContainer.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        zoomContainer.layer.cornerRadius = 20
        zoomContainer.clipsToBounds = true
        view.addSubview(zoomContainer)

        let btnSize: CGFloat = 32

        for (i, label) in zoomLabels.enumerated() {
            let btn = makeZoomCircle(title: label)
            btn.tag = i
            btn.addTarget(self, action: #selector(zoomButtonTapped(_:)), for: .touchUpInside)
            zoomButtons.append(btn)
        }

        let stack = UIStackView(arrangedSubviews: zoomButtons)
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        zoomContainer.addSubview(stack)

        var btnConstraints: [NSLayoutConstraint] = []
        for btn in zoomButtons {
            btnConstraints.append(btn.widthAnchor.constraint(equalToConstant: btnSize))
            btnConstraints.append(btn.heightAnchor.constraint(equalToConstant: btnSize))
        }

        NSLayoutConstraint.activate(btnConstraints + [
            zoomContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            zoomContainer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),
            zoomContainer.heightAnchor.constraint(equalToConstant: 40),

            stack.leadingAnchor.constraint(equalTo: zoomContainer.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: zoomContainer.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: zoomContainer.centerYAnchor)
        ])

        updateZoomSelection()
    }

    @objc private func zoomButtonTapped(_ sender: UIButton) {
        let level = zoomLevels[sender.tag]
        setZoomLevel(level)
    }

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        previewView.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(flipCamera))
        doubleTap.numberOfTapsRequired = 2
        previewView.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        tap.require(toFail: doubleTap)
        previewView.addGestureRecognizer(tap)
    }

    // MARK: - Permissions & Session

    private func checkPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCaptureSession()
                    } else {
                        self?.onResult?(.cancel)
                    }
                }
            }
        default:
            onResult?(.cancel)
        }
    }

    private var audioInput: AVCaptureDeviceInput?

    private func setupCaptureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Start with wide angle (1x)
        guard let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            onResult?(.error(.noCamera))
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: wide)
            if session.canAddInput(input) {
                session.addInput(input)
                videoDeviceInput = input
            }
        } catch {
            onResult?(.error(.captureError(error.localizedDescription)))
            return
        }

        // Audio
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            audioInput = micInput
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = previewView.bounds
        previewView.layer.insertSublayer(previewLayer, at: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }

        // Log available cameras
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                                         mediaType: .video, position: .back)
        let available = discovery.devices.map(\.deviceType.rawValue)
        os_log("Available back cameras: %{public}@", log: cameraLog, type: .info, "\(available)")
    }

    /// Switch to a specific physical camera lens
    private func switchToCamera(type: AVCaptureDevice.DeviceType, digitalZoom: CGFloat = 1.0) {
        guard let newDevice = AVCaptureDevice.default(type, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
            os_log("Camera %{public}@ not available, using digital zoom", log: cameraLog, type: .info, type.rawValue)
            // Fallback: use current camera with digital zoom
            if let device = videoDeviceInput?.device {
                let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 15.0)
                applyZoom(min(digitalZoom, maxZoom))
            }
            return
        }

        guard let currentInput = videoDeviceInput, newDevice != currentInput.device else {
            // Same device — just adjust digital zoom
            applyZoom(digitalZoom)
            return
        }

        session.beginConfiguration()
        session.removeInput(currentInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoDeviceInput = newInput
            os_log("Switched to %{public}@", log: cameraLog, type: .info, type.rawValue)
        } else {
            session.addInput(currentInput) // rollback
            os_log("Failed to switch to %{public}@", log: cameraLog, type: .error, type.rawValue)
        }
        session.commitConfiguration()

        // Apply digital zoom on the new device
        if digitalZoom > 1.0 {
            applyZoom(digitalZoom)
        }
    }

    // MARK: - Actions

    @objc private func shutterTapped() {
        if captureMode == .photo {
            capturePhoto()
        } else {
            toggleVideoRecording()
        }
    }

    @objc private func shutterLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if !isRecording { startVideoRecording() }
        case .ended, .cancelled:
            if isRecording { stopVideoRecording() }
        default: break
        }
    }

    private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(flashMode), !isUsingFrontCamera {
            settings.flashMode = flashMode
        }
        photoOutput.capturePhoto(with: settings, delegate: self)

        // Visual flash
        UIView.animate(withDuration: 0.08) {
            self.previewView.alpha = 0
        } completion: { _ in
            UIView.animate(withDuration: 0.08) {
                self.previewView.alpha = 1
            }
        }
    }

    private func toggleVideoRecording() {
        isRecording ? stopVideoRecording() : startVideoRecording()
    }

    private func startVideoRecording() {
        guard !isRecording else { return }

        if let device = videoDeviceInput?.device, device.hasTorch {
            try? device.lockForConfiguration()
            switch flashMode {
            case .on: device.torchMode = .on
            case .auto: device.torchMode = .auto
            default: device.torchMode = .off
            }
            device.unlockForConfiguration()
        }

        let fileName = "\(Date.now.formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))).mov"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
        recordingSeconds = 0
        shutterButton.setRecording(true)
        timerLabel.isHidden = false
        timerLabel.text = "0:00"
        topBar.viewWithTag(999)?.isHidden = false

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingSeconds += 1
            self.timerLabel.text = String(format: "%d:%02d", self.recordingSeconds / 60, self.recordingSeconds % 60)
        }
    }

    private func stopVideoRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
        isRecording = false
        shutterButton.setRecording(false)
        recordingTimer?.invalidate()
        recordingTimer = nil
        timerLabel.isHidden = true
        topBar.viewWithTag(999)?.isHidden = true

        if let device = videoDeviceInput?.device, device.hasTorch {
            try? device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        }
    }

    @objc private func toggleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        default: flashMode = .auto
        }
        updateFlashIcon()
    }

    @objc private func flipCamera() {
        guard let currentInput = videoDeviceInput else { return }
        isUsingFrontCamera.toggle()

        let newPosition: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newCamera) else {
            isUsingFrontCamera.toggle()
            return
        }

        session.beginConfiguration()
        session.removeInput(currentInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoDeviceInput = newInput
        } else {
            session.addInput(currentInput)
            isUsingFrontCamera.toggle()
        }
        session.commitConfiguration()

        zoomFactor = 1.0
        applyZoom(1.0)
        updateZoomSelection()

        UIView.transition(with: previewView, duration: 0.3, options: .transitionFlipFromLeft, animations: nil)
    }

    @objc private func closeTapped() {
        session.stopRunning()
        onResult?(.cancel)
    }

    @objc private func selectPhotoMode() {
        guard captureMode != .photo else { return }
        captureMode = .photo
        updateModeSelection(animated: true)
    }

    @objc private func selectVideoMode() {
        guard captureMode != .video else { return }
        captureMode = .video
        updateModeSelection(animated: true)
    }

    // MARK: - Zoom

    private func setZoomLevel(_ level: CGFloat) {
        guard !isUsingFrontCamera else { return }

        switch level {
        case ...0.5:
            // Ultra-wide lens
            switchToCamera(type: .builtInUltraWideCamera)
        case 0.51...1.5:
            // Wide lens (1x), no digital zoom
            switchToCamera(type: .builtInWideAngleCamera)
        case 1.51...3.0:
            // Wide lens + digital zoom 2x
            switchToCamera(type: .builtInWideAngleCamera, digitalZoom: level)
        default:
            // Try telephoto, fallback to wide+digital
            switchToCamera(type: .builtInTelephotoCamera, digitalZoom: level / 5.0)
            // If telephoto was used, its 1x = 5x optical, so no extra digital zoom needed
            if videoDeviceInput?.device.deviceType == .builtInTelephotoCamera {
                applyZoom(1.0) // telephoto's native zoom IS 5x
            }
        }

        zoomFactor = level
        updateZoomSelection()

        os_log("Zoom set to %{public}f — active device: %{public}@", log: cameraLog, type: .info,
               level, videoDeviceInput?.device.deviceType.rawValue ?? "nil")
    }

    private func applyZoom(_ factor: CGFloat) {
        guard let device = videoDeviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        } catch { }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let device = videoDeviceInput?.device else { return }

        switch gesture.state {
        case .began:
            initialZoom = zoomFactor
        case .changed:
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)
            let minZoom = device.minAvailableVideoZoomFactor
            let newZoom = (initialZoom * gesture.scale).clamped(to: minZoom...maxZoom)
            applyZoom(newZoom)
            zoomFactor = newZoom
            updateZoomSelection()
        default:
            break
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let device = videoDeviceInput?.device, device.isFocusPointOfInterestSupported else { return }

        let point = gesture.location(in: previewView)
        let focusPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)

        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = focusPoint
            device.focusMode = .autoFocus
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        } catch { }

        showFocusIndicator(at: point)
    }

    private func showFocusIndicator(at point: CGPoint) {
        let size: CGFloat = 70
        let indicator = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        indicator.center = point
        indicator.layer.borderWidth = 1.5
        indicator.layer.borderColor = UIColor.white.cgColor
        indicator.layer.cornerRadius = 4
        indicator.alpha = 0
        previewView.addSubview(indicator)

        UIView.animate(withDuration: 0.15) {
            indicator.alpha = 1
            indicator.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0.5) {
                indicator.alpha = 0
            } completion: { _ in
                indicator.removeFromSuperview()
            }
        }
    }

    // MARK: - UI Helpers

    private func makeZoomCircle(title: String) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        btn.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .normal)
        btn.backgroundColor = .clear
        btn.layer.cornerRadius = 15
        btn.clipsToBounds = true
        return btn
    }

    private func makeModeButton(title: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        btn.tintColor = .white
        return btn
    }

    private func updateFlashIcon() {
        let symbolName: String
        let tintColor: UIColor

        switch flashMode {
        case .auto:
            symbolName = "bolt.fill"
            tintColor = .white
        case .on:
            symbolName = "bolt.fill"
            tintColor = .systemYellow
        default:
            symbolName = "bolt.slash.fill"
            tintColor = UIColor.white.withAlphaComponent(0.6)
        }

        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        flashButton.setImage(UIImage(systemName: symbolName, withConfiguration: config), for: .normal)
        flashButton.tintColor = tintColor

        // Yellow bg when ON
        flashButton.backgroundColor = (flashMode == .on)
            ? UIColor.systemYellow.withAlphaComponent(0.25)
            : UIColor.black.withAlphaComponent(0.35)
    }

    private func updateZoomSelection() {
        guard !zoomButtons.isEmpty else { return }

        // Find closest preset
        var activeIndex = 0
        var minDist = CGFloat.greatestFiniteMagnitude
        for (i, level) in zoomLevels.enumerated() {
            let dist = abs(zoomFactor - level)
            if dist < minDist { minDist = dist; activeIndex = i }
        }

        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            for (i, btn) in self.zoomButtons.enumerated() {
                if i == activeIndex {
                    btn.backgroundColor = UIColor.white.withAlphaComponent(0.2)
                    btn.setTitleColor(.systemYellow, for: .normal)
                    btn.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
                } else {
                    btn.backgroundColor = .clear
                    btn.setTitleColor(UIColor.white.withAlphaComponent(0.55), for: .normal)
                    btn.transform = .identity
                }
            }
        }
    }

    private func updateModeSelection(animated: Bool) {
        let selectedBtn = captureMode == .photo ? photoModeButton! : videoModeButton!
        let otherBtn = captureMode == .photo ? videoModeButton! : photoModeButton!

        let update = {
            selectedBtn.alpha = 1.0
            otherBtn.alpha = 0.45

            self.modeIndicator.frame = CGRect(x: selectedBtn.frame.minX + self.modeStack.frame.minX,
                                              y: self.modeStack.frame.maxY + 4,
                                              width: selectedBtn.frame.width,
                                              height: 3)

            self.shutterButton.setVideoMode(self.captureMode == .video)
        }

        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) { update() }
        } else {
            DispatchQueue.main.async { update() }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension StalkCameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            onResult?(.error(.captureError(error.localizedDescription)))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            onResult?(.error(.invalidJpegData))
            return
        }

        let fileName = "\(Date.now.formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))).jpg"
        do {
            let url = try FileManager.default.writeDataToTemporaryDirectory(data: data, fileName: fileName)
            session.stopRunning()
            onResult?(.selectFile(url))
        } catch {
            onResult?(.error(.failedWritingToTemporaryDirectory))
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension StalkCameraViewController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error {
            onResult?(.error(.captureError(error.localizedDescription)))
            return
        }
        session.stopRunning()
        onResult?(.selectFile(outputFileURL))
    }
}

// MARK: - Shutter Button (Telegram-style)

private final class ShutterButton: UIControl {
    private let outerRing = CAShapeLayer()
    private let innerCircle = CAShapeLayer()
    private var isVideoMode = false
    private var isCurrentlyRecording = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupLayers() {
        outerRing.fillColor = UIColor.clear.cgColor
        outerRing.strokeColor = UIColor.white.cgColor
        outerRing.lineWidth = 4
        layer.addSublayer(outerRing)

        innerCircle.fillColor = UIColor.white.cgColor
        layer.addSublayer(innerCircle)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outerRadius = min(bounds.width, bounds.height) / 2

        outerRing.path = UIBezierPath(arcCenter: center, radius: outerRadius - 2, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath

        if !isCurrentlyRecording {
            let innerRadius = outerRadius - 8
            let path = UIBezierPath(arcCenter: center, radius: innerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            innerCircle.path = path
        }
    }

    func setVideoMode(_ video: Bool) {
        isVideoMode = video
        guard !isCurrentlyRecording else { return }
        innerCircle.fillColor = (video ? UIColor.systemRed : UIColor.white).cgColor
    }

    func setRecording(_ recording: Bool) {
        isCurrentlyRecording = recording
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        if recording {
            let squareSize: CGFloat = 24
            let rect = CGRect(x: center.x - squareSize / 2, y: center.y - squareSize / 2, width: squareSize, height: squareSize)
            let newPath = UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath

            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = innerCircle.path
            anim.toValue = newPath
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            innerCircle.add(anim, forKey: "morph")
            innerCircle.path = newPath
            innerCircle.fillColor = UIColor.systemRed.cgColor

            UIView.animate(withDuration: 0.2) { self.transform = CGAffineTransform(scaleX: 1.12, y: 1.12) }
        } else {
            let outerRadius = min(bounds.width, bounds.height) / 2
            let innerRadius = outerRadius - 8
            let circlePath = UIBezierPath(arcCenter: center, radius: innerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath

            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = innerCircle.path
            anim.toValue = circlePath
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            innerCircle.add(anim, forKey: "morph")
            innerCircle.path = circlePath
            innerCircle.fillColor = (isVideoMode ? UIColor.systemRed : UIColor.white).cgColor

            UIView.animate(withDuration: 0.2) { self.transform = .identity }
        }
    }
}
