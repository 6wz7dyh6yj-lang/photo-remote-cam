import AVFoundation
import UIKit
import Combine

/// 相机管理：负责最高分辨率拍照、对焦控制、低清预览帧
final class CameraManager: NSObject, ObservableObject {
    @Published var status: String = "初始化中…"
    @Published var resolutionText: String = "—"
    @Published var focusText: String = "—"
    @Published var previewImage: UIImage?
    @Published var shotCount: Int = 0

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "cam.session", qos: .userInitiated)
    private var videoDevice: AVCaptureDevice?
    private var photoCompletion: ((Data?) -> Void)?
    private var previewJPEG: Data = Data()
    private var previewLock = NSLock()
    private var lastPreviewTs: TimeInterval = 0

    override init() {
        super.init()
        checkAuthAndSetup()
    }

    // MARK: - 权限与会话
    private func checkAuthAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.setupSession()
                } else {
                    DispatchQueue.main.async { self?.status = "未授权相机权限" }
                }
            }
        default:
            DispatchQueue.main.async { self.status = "相机权限被拒，请在设置中开启" }
        }
    }

    private func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async { self.status = "未找到相机" }
                self.session.commitConfiguration()
                return
            }
            self.videoDevice = device

            // 选最高静态照片格式（iOS 16+ 用 supportedMaxPhotoDimensions）
            var selectedFormat: AVCaptureDevice.Format?
            if #available(iOS 16.0, *) {
                var maxPixels = 0
                for f in device.formats {
                    if let dim = f.supportedMaxPhotoDimensions.first {
                        let px = dim.width * dim.height
                        if px > maxPixels { maxPixels = px; selectedFormat = f }
                    }
                }
            } else {
                var maxArea: CMVideoDimensions?
                for f in device.formats {
                    let d = f.videoDimensions
                    if maxArea == nil || d.width * d.height > maxArea!.width * maxArea!.height {
                        maxArea = d
                        selectedFormat = f
                    }
                }
            }
            if let fmt = selectedFormat, try? device.lockForConfiguration() {
                device.activeFormat = fmt
                // 对焦模式设为连续自动对焦，便于随时触发
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            }

            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()
            self.session.startRunning()

            let res: String
            if #available(iOS 16.0, *) {
                let d = device.activeFormat.supportedMaxPhotoDimensions.first
                res = d.map { "\($0.width)×\($0.height)（\($0.width * $0.height / 1_000_000)MP）" } ?? "未知"
            } else {
                let d = device.activeFormat.videoDimensions
                res = "\(d.width)×\(d.height)"
            }
            DispatchQueue.main.async {
                self.status = "就绪"
                self.resolutionText = res
                self.focusText = "连续自动对焦"
            }
        }
    }

    // MARK: - 对焦
    /// 触发一次自动对焦。x/y 为 0~1 的归一化坐标（点按对焦），nil 则中心对焦
    func triggerFocus(x: Float? = nil, y: Float? = nil, wait: Bool = true) {
        guard let device = videoDevice else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            if let x = x, let y = y, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: CGFloat(x), y: CGFloat(y))
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.focusText = "对焦中…" }
            if wait {
                // 等待对焦稳定（最多 1.2 秒）
                Thread.sleep(forTimeInterval: 1.0)
                DispatchQueue.main.async {
                    self.focusText = "对焦完成" + (device.isFocusing ? "（进行中）" : "")
                }
            }
        }
    }

    // MARK: - 全分辨率拍照
    func captureFullResolution(completion: @escaping (Data?) -> Void) {
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            self.photoCompletion = completion
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func currentPreviewJPEG() -> Data {
        previewLock.lock()
        defer { previewLock.unlock() }
        return previewJPEG
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = (error == nil) ? photo.fileDataRepresentation() : nil
        let cb = photoCompletion
        photoCompletion = nil
        if data != nil {
            DispatchQueue.main.async { self.shotCount += 1 }
        }
        cb?(data)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date().timeIntervalSince1970
        if now - lastPreviewTs < 0.1 { return }
        lastPreviewTs = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        if let jpeg = image.jpegData(compressionQuality: 0.5) {
            previewLock.lock()
            previewJPEG = jpeg
            previewLock.unlock()
            DispatchQueue.main.async { self.previewImage = image }
        }
    }
}
