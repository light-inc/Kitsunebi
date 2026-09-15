//
//  VideoEngine.swift
//  Kitsunebi
//
//  Created by Tomoya Hirano on 2018/04/13.
//

import AVFoundation
import CoreImage

internal protocol VideoEngineUpdateDelegate: AnyObject {
  func didOutputFrame(_ frame: Frame)
  func didReceiveError(_ error: Swift.Error?)
  func didCompleted()
}

internal protocol VideoEngineDelegate: AnyObject {
  func didUpdateFrame(_ index: Int, engine: VideoEngine)
  func engineDidFinishPlaying(_ engine: VideoEngine)
}

enum VideoEngineAsset {
  case yCbCrWithA(yCbCr: Asset, a: Asset)
  case yCbCrA(yCbCrA: Asset)
}

internal class VideoEngine: NSObject {
  private let asset: VideoEngineAsset
  private let fpsKeeper: FPSKeeper
  private lazy var displayLink: CADisplayLink = .init(
    target: WeakProxy(target: self), selector: #selector(VideoEngine.update))
  internal weak var delegate: VideoEngineDelegate? = nil
  internal weak var updateDelegate: VideoEngineUpdateDelegate? = nil
  private var isRunningTheread = true
  private let wantsRunningLock = NSLock()
  private var _wantsRunning = false
  /// displayLinkを動かしたいかどうか。`displayLink.isPaused`への反映は描画スレッドに集約するため、他スレッドからはこのフラグのみを更新する
  private var wantsRunning: Bool {
    get {
      wantsRunningLock.lock()
      defer { wantsRunningLock.unlock() }
      return _wantsRunning
    }
    set {
      wantsRunningLock.lock()
      _wantsRunning = newValue
      wantsRunningLock.unlock()
    }
  }
  private lazy var renderThread: Thread = .init(
    target: WeakProxy(target: self), selector: #selector(VideoEngine.threadLoop), object: nil)
  private lazy var currentFrameIndex: Int = 0

  public init(base baseVideoURL: URL, alpha alphaVideoURL: URL, fps: Int) {
    // video range, full range両方くる可能性があるので、video rangeに統一
    let baseAsset = Asset(url: baseVideoURL, pixelFormatType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let alphaAsset = Asset(url: alphaVideoURL, pixelFormatType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    asset = .yCbCrWithA(yCbCr: baseAsset, a: alphaAsset)
    fpsKeeper = FPSKeeper(fps: fps)
    super.init()
    renderThread.start()
  }

  public init(hevcWithAlpha hevcWithAlphaVideoURL: URL, fps: Int) {
    // video range, full range両方くる可能性があるので、video rangeに統一
    let hevcWithAlphaAsset = Asset(url: hevcWithAlphaVideoURL, pixelFormatType: kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar)
    asset = .yCbCrA(yCbCrA: hevcWithAlphaAsset)
    fpsKeeper = FPSKeeper(fps: fps)
    super.init()
    renderThread.start()
  }

  @objc private func threadLoop() {
    displayLink.add(to: .current, forMode: .common)
    displayLink.isPaused = !wantsRunning
    if #available(iOS 10.0, *) {
      displayLink.preferredFramesPerSecond = 0
    } else {
      displayLink.frameInterval = 1
    }
    while isRunningTheread {
      // play()などがこのスレッドより先に呼ばれても一時停止のまま固着しないよう、期待状態との差分をここで解消する
      if displayLink.isPaused == wantsRunning {
        displayLink.isPaused = !wantsRunning
      }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 1 / 60))
    }
  }

  func purge() {
    isRunningTheread = false
  }

  deinit {
    displayLink.remove(from: .current, forMode: .common)
    displayLink.invalidate()
  }

  private func reset() throws {
    switch asset {
    case let .yCbCrA(yCbCrA):
      try yCbCrA.reset()
    case let .yCbCrWithA(yCbCr, a):
      try yCbCr.reset()
      try a.reset()
    }
  }

  private func cancelReading() {
    switch asset {
    case let .yCbCrA(yCbCrA):
      yCbCrA.cancelReading()
    case let .yCbCrWithA(yCbCr, a):
      yCbCr.cancelReading()
      a.cancelReading()
    }
  }

  public func play() throws {
    try reset()
    wantsRunning = true
  }

  public func pause() {
    guard !isCompleted else { return }
    wantsRunning = false
  }

  public func resume() {
    guard !isCompleted else { return }
    wantsRunning = true
  }

  private func finish() {
      wantsRunning = false
      DispatchQueue.main.async{
        self.fpsKeeper.clear()
        self.updateDelegate?.didCompleted()
        self.delegate?.engineDidFinishPlaying(self)
        self.purge()
      }
  }

  @objc private func update(_ link: CADisplayLink) {
    guard fpsKeeper.checkPast1Frame(link) else { return }

    #if DEBUG
      FPSDebugger.shared.update(link)
    #endif

    autoreleasepool(invoking: { [weak self] in
      self?.updateFrame()
    })
  }

  private var isCompleted: Bool {
    switch asset {
    case let .yCbCrA(yCbCrA):
      return yCbCrA.status == .completed
    case let .yCbCrWithA(yCbCr, a):
      return yCbCr.status == .completed || a.status == .completed
    }
  }

  private func updateFrame() {
    guard wantsRunning else { return }
    if isCompleted {
      finish()
      return
    }
    do {
      let frame = try copyNextFrame()
      updateDelegate?.didOutputFrame(frame)

      currentFrameIndex += 1
      delegate?.didUpdateFrame(currentFrameIndex, engine: self)
    } catch (let error) {
      // 最後まで読み終えた場合もreaderがnilを返すため、正常終了はエラーとして通知しない
      if !isEndOfStream(error) {
        updateDelegate?.didReceiveError(error)
      }
      finish()
    }
  }

  /// 読み込み済みのフレームを出し切った(EOF)ことによるエラーかどうか
  private func isEndOfStream(_ error: Swift.Error) -> Bool {
    guard case AssetError.readerNotReturnedImage = error else { return false }
    return isCompleted
  }

  private func copyNextFrame() throws -> Frame {
    switch asset {
    case let .yCbCrA(yCbCrA):
      let yCbCrABuffer = try yCbCrA.copyNextImageBuffer()
      return .yCbCrA(yCbCrA: yCbCrABuffer)
    case let .yCbCrWithA(yCbCr, a):
      let yCbCrBuffer = try yCbCr.copyNextImageBuffer()
      let aBuffer = try a.copyNextImageBuffer()
      return .yCbCrWithA(yCbCr: yCbCrBuffer, a: aBuffer)
    }
  }
}
