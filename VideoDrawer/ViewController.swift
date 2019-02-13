//
//  ViewController.swift
//  VideoDrawer
//
//  Created by Fumiaki Yoshimatsu on 2/13/19.
//  Copyright © 2019 luckypines. All rights reserved.
//

import UIKit
import Photos

class ViewController: UIViewController {

  override func viewDidLoad() {
    super.viewDidLoad()
    // Do any additional setup after loading the view, typically from a nib.
  }

  
  @IBAction func click(_ sender: Any) {
    let photos = PHPhotoLibrary.authorizationStatus()
    if photos == .notDetermined {
      PHPhotoLibrary.requestAuthorization({ [weak self] status in
        if status == .authorized {
          self?.writeVideo()
        } else {
          print("Permission denied to write video to a file")
        }
      })
    } else if photos == .authorized {
      writeVideo()
    }
  }

  private var videoDrawer: VideoDrawer? = nil
  private func writeVideo() {
    var drawables = VData.getData(text: "hello")
    drawables.insert([
      Drawable(command: .MoveTo, x: 0, y: 0, x1: nil, y1: nil),
      Drawable(command: .ClosePath, x: nil, y: nil, x1: nil, y1: nil),
      ], at: 0)
    videoDrawer = VideoDrawer(filename: "test.mp4", width: 560, height: 320)
    videoDrawer?.makeVideo(drawables: drawables, completion: { [weak self] (url, error) in
      if let error = error {
        print("\(error)")
      } else {
        self?.saveVideoToLibrary(videoURL: url!)
      }
    })
  }
  
  
  func saveVideoToLibrary(videoURL: URL) {
    PHPhotoLibrary.requestAuthorization { status in
      // Return if unauthorized
      guard status == .authorized else {
        print("Error saving video: unauthorized access")
        return
      }
      
      // If here, save video to library
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
      }) { success, error in
        if let error = error {
          print("Error saving video: \(error)")
        }
      }
    }
  }
}

