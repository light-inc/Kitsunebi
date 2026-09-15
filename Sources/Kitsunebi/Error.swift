//
//  Error.swift
//  Kitsunebi
//
//  Created by Tomoya Hirano on 2018/04/13.
//

import CoreVideo
import Foundation

public enum Error: Swift.Error {
  case unknown(String)
  case cannotAddOutput
}

internal enum AssetError: Swift.Error {
  case readerWasStopped
  case readerNotReturnedImage
  /// 最終フレームまで読み切った正常終了。再生失敗と区別するため独立したケースにしている
  case readerReachedEnd
}

internal enum RenderError: Swift.Error {
  case applicationBackground
  case failedToFetchNextDrawable
}

enum CVMetalError: Swift.Error {
  case cvReturn(CVReturn)
}
