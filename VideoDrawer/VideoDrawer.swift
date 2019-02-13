//
//  VideoDrawer.swift
//  MoonPhases
//
//  Created by Fumiaki Yoshimatsu on 2/13/19.
//  Copyright © 2019 luckypines. All rights reserved.
//

import UIKit
import AVFoundation
import Photos

enum CommandType: String {
  case MoveTo = "M"
  case LineTo = "L"
  case QuadTo = "Q"
  case ClosePath = "Z"
}

struct Drawable {
  let command: CommandType
  let x: Double?
  let y: Double?
  let x1: Double?
  let y1: Double?
}

class VideoDrawer {
  
  private let videoFPS: Int32 = 60
  private let width: Int
  private let height: Int
  private let bitsPerComponent: Int
  private let bytePerRow: Int
  private let tempFileUrl: URL
  private let assetWriter: AVAssetWriter!
  private let videoWriterQueue = DispatchQueue(label: "VideoDrawer Media Writer Queue")
  private var discarded = false
  private var inProcess = false
  
  init(filename: String, width: Int, height: Int) {
    guard let url = try? VideoDrawer.nameToTempFileURL(filename) else {
      fatalError()
    }
    guard let assetWriter = try? VideoDrawer.initAssetWriter(fileUrl: url, width: width, height: height) else {
      fatalError()
    }
    self.tempFileUrl = url
    self.assetWriter = assetWriter
    self.width = width
    self.height = height
    self.bitsPerComponent = 8
    self.bytePerRow = 4 * width
  }
  
  func makeVideo(drawables: [[Drawable]], completion: ((URL?, Error?) -> Void)?) {
    if discarded {
      completion?(nil, NSError(domain: #file, code: -1, userInfo: [NSLocalizedDescriptionKey:"Already discarded"]))
      return
    }
    if inProcess {
      completion?(nil, NSError(domain: #file, code: -2, userInfo: [NSLocalizedDescriptionKey:"Another session is writing video"]))
      return
    }
    inProcess = true
    
    let writerInput = assetWriter.inputs.filter{ $0.mediaType == AVMediaType.video }.first!
    let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
                                                                  sourcePixelBufferAttributes: [
                                                                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                                                                    kCVPixelBufferWidthKey as String: width,
                                                                    kCVPixelBufferHeightKey as String: height,
                                                                    ])
    
    assetWriter.startWriting()
    assetWriter.startSession(atSourceTime: CMTime.zero)
    
    // One frame for each duration
    let frameDuration = CMTimeMake(value: 1, timescale: videoFPS)
    var frameIndex = 0
    
    writerInput.requestMediaDataWhenReady(on: videoWriterQueue, using: { [weak self] in
      guard let welf = self else { return }
      while (writerInput.isReadyForMoreMediaData && frameIndex < drawables.count) {
        
        // CMTime for this frame
        let lastFrameTime = CMTimeMake(value: Int64(frameIndex), timescale: welf.videoFPS)
        let presentationTime = frameIndex == 0 ? lastFrameTime : CMTimeAdd(lastFrameTime, frameDuration)
        
        // Get the pool of buffers to write data to
        guard let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool else {
          DispatchQueue.main.async {
            completion?(nil, NSError(domain: #file, code: -3, userInfo: [NSLocalizedDescriptionKey:"Buffer pool was not allocated"]))
          }
          return
        }
        
        // Prepare a buffer from a pool to draw paths to
        var pixelBufferOut: CVPixelBuffer? = nil
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { continue }
        
        // Lock the buffer, draw the paths to the buffer and unlock the buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        if let error = welf.writeVideoFrame(drawables: drawables[0...frameIndex], to: pixelBuffer) {
          DispatchQueue.main.async {
            completion?(nil, error)
          }
          return
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        // Append the buffer to the video at the CMTime
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        
        frameIndex += 1
      }
      
      // Until all frames are drawn (i.e. until the `if` condition is met), continue the `while` loop
      if (frameIndex >= drawables.count) {
        // After all frames are drawn, finish the writing and let the caller know
        writerInput.markAsFinished()
        welf.discarded = true
        welf.assetWriter.finishWriting {
          if let error = welf.assetWriter.error {
            DispatchQueue.main.async {
              completion?(nil, error)
            }
          } else {
            DispatchQueue.main.async {
              completion?(welf.tempFileUrl, nil)
            }
          }
        }
      }
    })
  }
  
  /**
   Draw a frame to buffer
   */
  private func writeVideoFrame(drawables: ArraySlice<[Drawable]>, to buffer: CVPixelBuffer) -> Error? {
    let pxData = CVPixelBufferGetBaseAddress(buffer)
    let rgbColorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: pxData, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytePerRow, space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
      return NSError(domain: #file, code: -4, userInfo: [NSLocalizedDescriptionKey:"Context was not created"])
    }
    context.setFillColor(UIColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for d in drawables {
      draw(on: context, drawables: d)
    }
    return nil
  }
  
  /**
   Interpret the content of `Drawable` and translate it into commands to the context
   */
  private func draw(on context: CGContext, drawables: [Drawable]) {
    context.setFillColor(UIColor.black.cgColor)
    context.beginPath()
    var d = drawables
    // Always move to the first command point
    let first = d.removeFirst()
    context.move(to: CGPoint(x: first.x!, y: first.y!))
    for drawable in d {
      switch drawable.command {
      case .MoveTo:
        context.move(to: CGPoint(x: drawable.x!, y: drawable.y!))
      case .LineTo:
        context.addLine(to: CGPoint(x: drawable.x!, y: drawable.y!))
      case .QuadTo:
        context.addQuadCurve(to: CGPoint(x: drawable.x!, y: drawable.y!), control: CGPoint(x: drawable.x1!, y: drawable.y1!))
      case .ClosePath:
        context.closePath()
      }
    }
    context.fillPath()
  }
  
  /**
   Convenience function that returns a `URL` that may be used as the path to save a file
   temporarily in the cache directory of the device.
   
   - Parameters:
   - name: the name of the file
   
   - Throws: Whatever FileManager throws
   
   - Returns: A URL to the file in the cache directory of the device
   */
  private static func nameToTempFileURL(_ name: String) throws -> URL {
    let fileManager = FileManager.default
    let cacheDir = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let url = cacheDir.appendingPathComponent(name)
    print("Video file is going to be created in: \(url.absoluteString)")
    try? fileManager.removeItem(at: url)
    return url
  }
  
  /**
   Convenience function that creates an AVAssetWriter.
   
   - Parameters:
   - fileUrl: A URL (path to a file) where the writer writes data to
   - width: Width of the video
   - height: Height of the video
   
   - Throws: Whatever AVAssetWriter throws
   
   - Returns: an AVAssetWriter
   */
  private static func initAssetWriter(fileUrl: URL, width: Int, height: Int) throws -> AVAssetWriter? {
    let writer = try AVAssetWriter(outputURL: fileUrl, fileType: AVFileType.mp4)
    writer.add(AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecH264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      ]))
    return writer
  }
}

class VData {
  static let dimensions = [
    "h": CGPoint(x: 1480, y: 1712),
    "e": CGPoint(x: 1084, y: 1204),//{\"e\":[1084,1204]},
    "l": CGPoint(x: 768, y: 1712),//{\"l\":[768,1712]},
    "o": CGPoint(x: 945, y: 1204)//{\"o\":[945,1204]},
  ]
  static let charData: [String: String] = [
    "h": "[[{\"type\":\"M\",\"x\":-69,\"y\":0},{\"type\":\"L\",\"x\":-217,\"y\":0},{\"type\":\"L\",\"x\":406,\"y\":1712},{\"type\":\"L\",\"x\":555,\"y\":1712},{\"type\":\"L\",\"x\":-69,\"y\":0},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":206,\"y\":755},{\"type\":\"Q\",\"x1\":274,\"y1\":869,\"x\":335.5,\"y\":953.5},{\"type\":\"L\",\"x\":298.5,\"y\":841},{\"type\":\"Q\",\"x1\":226,\"y1\":731,\"x\":141,\"y\":574},{\"type\":\"L\",\"x\":141,\"y\":574},{\"type\":\"L\",\"x\":206,\"y\":755},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":335.5,\"y\":953.5},{\"type\":\"Q\",\"x1\":397,\"y1\":1038,\"x\":458,\"y\":1093.5},{\"type\":\"L\",\"x\":437.5,\"y\":1020.5},{\"type\":\"Q\",\"x1\":371,\"y1\":951,\"x\":298.5,\"y\":841},{\"type\":\"L\",\"x\":335.5,\"y\":953.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":458,\"y\":1093.5},{\"type\":\"Q\",\"x1\":519,\"y1\":1149,\"x\":583,\"y\":1176.5},{\"type\":\"L\",\"x\":567,\"y\":1122},{\"type\":\"Q\",\"x1\":504,\"y1\":1090,\"x\":437.5,\"y\":1020.5},{\"type\":\"L\",\"x\":458,\"y\":1093.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":583,\"y\":1176.5},{\"type\":\"Q\",\"x1\":647,\"y1\":1204,\"x\":720,\"y\":1204},{\"type\":\"L\",\"x\":720,\"y\":1204},{\"type\":\"L\",\"x\":698,\"y\":1154},{\"type\":\"L\",\"x\":698,\"y\":1154},{\"type\":\"Q\",\"x1\":630,\"y1\":1154,\"x\":567,\"y\":1122},{\"type\":\"L\",\"x\":583,\"y\":1176.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":720,\"y\":1204},{\"type\":\"Q\",\"x1\":781,\"y1\":1204,\"x\":827.5,\"y\":1184},{\"type\":\"L\",\"x\":811.5,\"y\":1108},{\"type\":\"Q\",\"x1\":775,\"y1\":1154,\"x\":698,\"y\":1154},{\"type\":\"L\",\"x\":720,\"y\":1204},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":827.5,\"y\":1184},{\"type\":\"Q\",\"x1\":874,\"y1\":1164,\"x\":905.5,\"y\":1127.5},{\"type\":\"L\",\"x\":848,\"y\":984},{\"type\":\"L\",\"x\":848,\"y\":984},{\"type\":\"Q\",\"x1\":848,\"y1\":1062,\"x\":811.5,\"y\":1108},{\"type\":\"L\",\"x\":827.5,\"y\":1184},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":905.5,\"y\":1127.5},{\"type\":\"Q\",\"x1\":937,\"y1\":1091,\"x\":953,\"y\":1040},{\"type\":\"L\",\"x\":848,\"y\":984},{\"type\":\"L\",\"x\":848,\"y\":984},{\"type\":\"Q\",\"x1\":848,\"y1\":1062,\"x\":811.5,\"y\":1108},{\"type\":\"L\",\"x\":905.5,\"y\":1127.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":953,\"y\":1040},{\"type\":\"Q\",\"x1\":969,\"y1\":989,\"x\":969,\"y\":926},{\"type\":\"L\",\"x\":969,\"y\":926},{\"type\":\"L\",\"x\":831.5,\"y\":886.5},{\"type\":\"Q\",\"x1\":848,\"y1\":945,\"x\":848,\"y\":984},{\"type\":\"L\",\"x\":953,\"y\":1040},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":969,\"y\":926},{\"type\":\"Q\",\"x1\":969,\"y1\":881,\"x\":952.5,\"y\":820},{\"type\":\"L\",\"x\":790,\"y\":760},{\"type\":\"Q\",\"x1\":815,\"y1\":828,\"x\":831.5,\"y\":886.5},{\"type\":\"L\",\"x\":969,\"y\":926},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":952.5,\"y\":820},{\"type\":\"Q\",\"x1\":936,\"y1\":759,\"x\":911,\"y\":690},{\"type\":\"L\",\"x\":790,\"y\":760},{\"type\":\"Q\",\"x1\":815,\"y1\":828,\"x\":831.5,\"y\":886.5},{\"type\":\"L\",\"x\":952.5,\"y\":820},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":911,\"y\":690},{\"type\":\"Q\",\"x1\":886,\"y1\":621,\"x\":857,\"y\":548.5},{\"type\":\"L\",\"x\":736,\"y\":618.5},{\"type\":\"Q\",\"x1\":765,\"y1\":692,\"x\":790,\"y\":760},{\"type\":\"L\",\"x\":911,\"y\":690},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":857,\"y\":548.5},{\"type\":\"Q\",\"x1\":828,\"y1\":476,\"x\":803,\"y\":408},{\"type\":\"L\",\"x\":682,\"y\":475},{\"type\":\"Q\",\"x1\":707,\"y1\":545,\"x\":736,\"y\":618.5},{\"type\":\"L\",\"x\":857,\"y\":548.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":803,\"y\":408},{\"type\":\"Q\",\"x1\":778,\"y1\":340,\"x\":761.5,\"y\":281.5},{\"type\":\"L\",\"x\":640.5,\"y\":344.5},{\"type\":\"Q\",\"x1\":657,\"y1\":405,\"x\":682,\"y\":475},{\"type\":\"L\",\"x\":803,\"y\":408},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":761.5,\"y\":281.5},{\"type\":\"Q\",\"x1\":745,\"y1\":223,\"x\":745,\"y\":182},{\"type\":\"L\",\"x\":745,\"y\":182},{\"type\":\"L\",\"x\":624,\"y\":241},{\"type\":\"L\",\"x\":624,\"y\":241},{\"type\":\"Q\",\"x1\":624,\"y1\":284,\"x\":640.5,\"y\":344.5},{\"type\":\"L\",\"x\":761.5,\"y\":281.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":745,\"y\":182},{\"type\":\"Q\",\"x1\":745,\"y1\":113,\"x\":781.5,\"y\":72},{\"type\":\"L\",\"x\":640,\"y\":134},{\"type\":\"Q\",\"x1\":624,\"y1\":182,\"x\":624,\"y\":241},{\"type\":\"L\",\"x\":745,\"y\":182},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":745,\"y\":182},{\"type\":\"Q\",\"x1\":745,\"y1\":113,\"x\":781.5,\"y\":72},{\"type\":\"L\",\"x\":687.5,\"y\":52},{\"type\":\"Q\",\"x1\":656,\"y1\":86,\"x\":640,\"y\":134},{\"type\":\"L\",\"x\":745,\"y\":182},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":781.5,\"y\":72},{\"type\":\"Q\",\"x1\":818,\"y1\":31,\"x\":895,\"y\":31},{\"type\":\"L\",\"x\":765.5,\"y\":-0.5},{\"type\":\"Q\",\"x1\":719,\"y1\":18,\"x\":687.5,\"y\":52},{\"type\":\"L\",\"x\":781.5,\"y\":72},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":781.5,\"y\":72},{\"type\":\"Q\",\"x1\":818,\"y1\":31,\"x\":895,\"y\":31},{\"type\":\"L\",\"x\":895,\"y\":31},{\"type\":\"L\",\"x\":873,\"y\":-19},{\"type\":\"L\",\"x\":873,\"y\":-19},{\"type\":\"Q\",\"x1\":812,\"y1\":-19,\"x\":765.5,\"y\":-0.5},{\"type\":\"L\",\"x\":781.5,\"y\":72},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":895,\"y\":31},{\"type\":\"Q\",\"x1\":962,\"y1\":31,\"x\":1024.5,\"y\":60},{\"type\":\"L\",\"x\":1020,\"y\":11},{\"type\":\"Q\",\"x1\":951,\"y1\":-19,\"x\":873,\"y\":-19},{\"type\":\"L\",\"x\":873,\"y\":-19},{\"type\":\"L\",\"x\":895,\"y\":31},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":1024.5,\"y\":60},{\"type\":\"Q\",\"x1\":1087,\"y1\":89,\"x\":1148.5,\"y\":147.5},{\"type\":\"L\",\"x\":1155.5,\"y\":102.5},{\"type\":\"Q\",\"x1\":1089,\"y1\":41,\"x\":1020,\"y\":11},{\"type\":\"L\",\"x\":1024.5,\"y\":60},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":1148.5,\"y\":147.5},{\"type\":\"Q\",\"x1\":1210,\"y1\":206,\"x\":1272,\"y\":294.5},{\"type\":\"L\",\"x\":1288.5,\"y\":258.5},{\"type\":\"Q\",\"x1\":1222,\"y1\":164,\"x\":1155.5,\"y\":102.5},{\"type\":\"L\",\"x\":1148.5,\"y\":147.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":1272,\"y\":294.5},{\"type\":\"Q\",\"x1\":1334,\"y1\":383,\"x\":1401,\"y\":501},{\"type\":\"L\",\"x\":1401,\"y\":501},{\"type\":\"L\",\"x\":1428,\"y\":482},{\"type\":\"Q\",\"x1\":1355,\"y1\":353,\"x\":1288.5,\"y\":258.5},{\"type\":\"L\",\"x\":1272,\"y\":294.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":1401,\"y\":501},{\"type\":\"L\",\"x\":1453,\"y\":593},{\"type\":\"L\",\"x\":1480,\"y\":574},{\"type\":\"L\",\"x\":1428,\"y\":482},{\"type\":\"L\",\"x\":1401,\"y\":501},{\"type\":\"Z\"}]]",
    "e": "[[{\"type\":\"M\",\"x\":195,\"y\":676},{\"type\":\"L\",\"x\":195,\"y\":676},{\"type\":\"Q\",\"x1\":305,\"y1\":678,\"x\":383,\"y\":695.5},{\"type\":\"L\",\"x\":397,\"y\":656.5},{\"type\":\"Q\",\"x1\":303,\"y1\":640,\"x\":183,\"y\":640},{\"type\":\"L\",\"x\":183,\"y\":640},{\"type\":\"L\",\"x\":195,\"y\":676},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":383,\"y\":695.5},{\"type\":\"Q\",\"x1\":461,\"y1\":713,\"x\":519,\"y\":740},{\"type\":\"L\",\"x\":519,\"y\":740},{\"type\":\"L\",\"x\":569,\"y\":706},{\"type\":\"L\",\"x\":569,\"y\":706},{\"type\":\"Q\",\"x1\":491,\"y1\":673,\"x\":397,\"y\":656.5},{\"type\":\"L\",\"x\":383,\"y\":695.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":519,\"y\":740},{\"type\":\"Q\",\"x1\":565,\"y1\":761,\"x\":608.5,\"y\":794.5},{\"type\":\"L\",\"x\":682.5,\"y\":767.5},{\"type\":\"Q\",\"x1\":632,\"y1\":732,\"x\":569,\"y\":706},{\"type\":\"L\",\"x\":569,\"y\":706},{\"type\":\"L\",\"x\":519,\"y\":740},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":608.5,\"y\":794.5},{\"type\":\"Q\",\"x1\":652,\"y1\":828,\"x\":685.5,\"y\":871},{\"type\":\"L\",\"x\":769,\"y\":844},{\"type\":\"Q\",\"x1\":733,\"y1\":803,\"x\":682.5,\"y\":767.5},{\"type\":\"L\",\"x\":608.5,\"y\":794.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":685.5,\"y\":871},{\"type\":\"Q\",\"x1\":719,\"y1\":914,\"x\":739.5,\"y\":964},{\"type\":\"L\",\"x\":824,\"y\":931},{\"type\":\"Q\",\"x1\":805,\"y1\":885,\"x\":769,\"y\":844},{\"type\":\"L\",\"x\":685.5,\"y\":871},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":739.5,\"y\":964},{\"type\":\"Q\",\"x1\":760,\"y1\":1014,\"x\":760,\"y\":1068},{\"type\":\"L\",\"x\":843,\"y\":1025},{\"type\":\"L\",\"x\":843,\"y\":1025},{\"type\":\"Q\",\"x1\":843,\"y1\":977,\"x\":824,\"y\":931},{\"type\":\"L\",\"x\":739.5,\"y\":964},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":760,\"y\":1068},{\"type\":\"Q\",\"x1\":760,\"y1\":1095,\"x\":752,\"y\":1113},{\"type\":\"L\",\"x\":785.5,\"y\":1157},{\"type\":\"Q\",\"x1\":843,\"y1\":1110,\"x\":843,\"y\":1025},{\"type\":\"L\",\"x\":843,\"y\":1025},{\"type\":\"L\",\"x\":760,\"y\":1068},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":752,\"y\":1113},{\"type\":\"Q\",\"x1\":744,\"y1\":1131,\"x\":730,\"y\":1142.5},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"Q\",\"x1\":728,\"y1\":1204,\"x\":785.5,\"y\":1157},{\"type\":\"L\",\"x\":752,\"y\":1113},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":730,\"y\":1142.5},{\"type\":\"Q\",\"x1\":716,\"y1\":1154,\"x\":697,\"y\":1159},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"Q\",\"x1\":728,\"y1\":1204,\"x\":785.5,\"y\":1157},{\"type\":\"L\",\"x\":730,\"y\":1142.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":697,\"y\":1159},{\"type\":\"Q\",\"x1\":678,\"y1\":1164,\"x\":656,\"y\":1164},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"Q\",\"x1\":728,\"y1\":1204,\"x\":785.5,\"y\":1157},{\"type\":\"L\",\"x\":697,\"y\":1159},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":656,\"y\":1164},{\"type\":\"Q\",\"x1\":593,\"y1\":1164,\"x\":527.5,\"y\":1127},{\"type\":\"L\",\"x\":431,\"y\":1157},{\"type\":\"Q\",\"x1\":529,\"y1\":1204,\"x\":628,\"y\":1204},{\"type\":\"L\",\"x\":628,\"y\":1204},{\"type\":\"L\",\"x\":656,\"y\":1164},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":527.5,\"y\":1127},{\"type\":\"Q\",\"x1\":462,\"y1\":1090,\"x\":401,\"y\":1024.5},{\"type\":\"L\",\"x\":248,\"y\":1027},{\"type\":\"Q\",\"x1\":333,\"y1\":1110,\"x\":431,\"y\":1157},{\"type\":\"L\",\"x\":527.5,\"y\":1127},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":401,\"y\":1024.5},{\"type\":\"Q\",\"x1\":340,\"y1\":959,\"x\":287,\"y\":870},{\"type\":\"L\",\"x\":97.5,\"y\":830},{\"type\":\"Q\",\"x1\":163,\"y1\":944,\"x\":248,\"y\":1027},{\"type\":\"L\",\"x\":401,\"y\":1024.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":287,\"y\":870},{\"type\":\"Q\",\"x1\":234,\"y1\":781,\"x\":195,\"y\":676},{\"type\":\"L\",\"x\":195,\"y\":676},{\"type\":\"L\",\"x\":-4,\"y\":582},{\"type\":\"L\",\"x\":-4,\"y\":582},{\"type\":\"Q\",\"x1\":32,\"y1\":716,\"x\":97.5,\"y\":830},{\"type\":\"L\",\"x\":287,\"y\":870},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":183,\"y\":640},{\"type\":\"L\",\"x\":195,\"y\":676},{\"type\":\"L\",\"x\":-4,\"y\":582},{\"type\":\"L\",\"x\":-4,\"y\":582},{\"type\":\"L\",\"x\":183,\"y\":640},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":183,\"y\":640},{\"type\":\"Q\",\"x1\":154,\"y1\":559,\"x\":137.5,\"y\":471.5},{\"type\":\"L\",\"x\":-27.5,\"y\":465},{\"type\":\"Q\",\"x1\":-20,\"y1\":522,\"x\":-4,\"y\":582},{\"type\":\"L\",\"x\":-4,\"y\":582},{\"type\":\"L\",\"x\":183,\"y\":640},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":137.5,\"y\":471.5},{\"type\":\"Q\",\"x1\":121,\"y1\":384,\"x\":121,\"y\":293},{\"type\":\"L\",\"x\":121,\"y\":293},{\"type\":\"L\",\"x\":-35,\"y\":357},{\"type\":\"L\",\"x\":-35,\"y\":357},{\"type\":\"Q\",\"x1\":-35,\"y1\":408,\"x\":-27.5,\"y\":465},{\"type\":\"L\",\"x\":137.5,\"y\":471.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":121,\"y\":293},{\"type\":\"L\",\"x\":121,\"y\":293},{\"type\":\"Q\",\"x1\":121,\"y1\":154,\"x\":179.5,\"y\":92.5},{\"type\":\"L\",\"x\":63,\"y\":75.5},{\"type\":\"Q\",\"x1\":-35,\"y1\":170,\"x\":-35,\"y\":357},{\"type\":\"Q\",\"x1\":-35,\"y1\":408,\"x\":-27.5,\"y\":465},{\"type\":\"L\",\"x\":121,\"y\":293},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":179.5,\"y\":92.5},{\"type\":\"Q\",\"x1\":238,\"y1\":31,\"x\":364,\"y\":31},{\"type\":\"L\",\"x\":364,\"y\":31},{\"type\":\"L\",\"x\":342,\"y\":-19},{\"type\":\"Q\",\"x1\":161,\"y1\":-19,\"x\":63,\"y\":75.5},{\"type\":\"L\",\"x\":179.5,\"y\":92.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":364,\"y\":31},{\"type\":\"L\",\"x\":364,\"y\":31},{\"type\":\"Q\",\"x1\":469,\"y1\":31,\"x\":564,\"y\":71.5},{\"type\":\"L\",\"x\":551.5,\"y\":18.5},{\"type\":\"Q\",\"x1\":453,\"y1\":-19,\"x\":342,\"y\":-19},{\"type\":\"L\",\"x\":364,\"y\":31},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":564,\"y\":71.5},{\"type\":\"Q\",\"x1\":659,\"y1\":112,\"x\":740,\"y\":178},{\"type\":\"L\",\"x\":736.5,\"y\":122.5},{\"type\":\"Q\",\"x1\":650,\"y1\":56,\"x\":551.5,\"y\":18.5},{\"type\":\"L\",\"x\":564,\"y\":71.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":740,\"y\":178},{\"type\":\"Q\",\"x1\":821,\"y1\":244,\"x\":888,\"y\":328.5},{\"type\":\"L\",\"x\":896.5,\"y\":281},{\"type\":\"Q\",\"x1\":823,\"y1\":189,\"x\":736.5,\"y\":122.5},{\"type\":\"L\",\"x\":740,\"y\":178},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":888,\"y\":328.5},{\"type\":\"Q\",\"x1\":955,\"y1\":413,\"x\":1005,\"y\":501},{\"type\":\"L\",\"x\":1005,\"y\":501},{\"type\":\"L\",\"x\":1032,\"y\":482},{\"type\":\"Q\",\"x1\":970,\"y1\":373,\"x\":896.5,\"y\":281},{\"type\":\"L\",\"x\":888,\"y\":328.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":1005,\"y\":501},{\"type\":\"L\",\"x\":1005,\"y\":501},{\"type\":\"L\",\"x\":1057,\"y\":593},{\"type\":\"L\",\"x\":1084,\"y\":574},{\"type\":\"L\",\"x\":1032,\"y\":482},{\"type\":\"L\",\"x\":1005,\"y\":501},{\"type\":\"Z\"}]]",
    "l": "[[{\"type\":\"M\",\"x\":-39,\"y\":485},{\"type\":\"L\",\"x\":407,\"y\":1712},{\"type\":\"L\",\"x\":556,\"y\":1712},{\"type\":\"L\",\"x\":109,\"y\":485},{\"type\":\"L\",\"x\":-39,\"y\":485},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":109,\"y\":485},{\"type\":\"Q\",\"x1\":95,\"y1\":446,\"x\":81,\"y\":405.5},{\"type\":\"L\",\"x\":-76,\"y\":354.5},{\"type\":\"Q\",\"x1\":-64,\"y1\":416,\"x\":-39,\"y\":485},{\"type\":\"L\",\"x\":109,\"y\":485},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":81,\"y\":405.5},{\"type\":\"Q\",\"x1\":67,\"y1\":365,\"x\":56.5,\"y\":325.5},{\"type\":\"L\",\"x\":-88,\"y\":241},{\"type\":\"Q\",\"x1\":-88,\"y1\":293,\"x\":-76,\"y\":354.5},{\"type\":\"L\",\"x\":81,\"y\":405.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":56.5,\"y\":325.5},{\"type\":\"Q\",\"x1\":46,\"y1\":286,\"x\":39.5,\"y\":249.5},{\"type\":\"L\",\"x\":-72,\"y\":134},{\"type\":\"Q\",\"x1\":-88,\"y1\":182,\"x\":-88,\"y\":241},{\"type\":\"L\",\"x\":56.5,\"y\":325.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":39.5,\"y\":249.5},{\"type\":\"Q\",\"x1\":33,\"y1\":213,\"x\":33,\"y\":182},{\"type\":\"L\",\"x\":-72,\"y\":134},{\"type\":\"Q\",\"x1\":-88,\"y1\":182,\"x\":-88,\"y\":241},{\"type\":\"L\",\"x\":39.5,\"y\":249.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":33,\"y\":182},{\"type\":\"Q\",\"x1\":33,\"y1\":113,\"x\":69.5,\"y\":72},{\"type\":\"L\",\"x\":-24.5,\"y\":52},{\"type\":\"Q\",\"x1\":-56,\"y1\":86,\"x\":-72,\"y\":134},{\"type\":\"L\",\"x\":33,\"y\":182},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":69.5,\"y\":72},{\"type\":\"Q\",\"x1\":106,\"y1\":31,\"x\":183,\"y\":31},{\"type\":\"L\",\"x\":53.5,\"y\":-0.5},{\"type\":\"Q\",\"x1\":7,\"y1\":18,\"x\":-24.5,\"y\":52},{\"type\":\"L\",\"x\":69.5,\"y\":72},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":183,\"y\":31},{\"type\":\"Q\",\"x1\":250,\"y1\":31,\"x\":312.5,\"y\":60},{\"type\":\"L\",\"x\":161,\"y\":-19},{\"type\":\"Q\",\"x1\":100,\"y1\":-19,\"x\":53.5,\"y\":-0.5},{\"type\":\"L\",\"x\":183,\"y\":31},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":183,\"y\":31},{\"type\":\"Q\",\"x1\":250,\"y1\":31,\"x\":312.5,\"y\":60},{\"type\":\"L\",\"x\":308,\"y\":11},{\"type\":\"Q\",\"x1\":239,\"y1\":-19,\"x\":161,\"y\":-19},{\"type\":\"L\",\"x\":183,\"y\":31},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":312.5,\"y\":60},{\"type\":\"Q\",\"x1\":375,\"y1\":89,\"x\":436.5,\"y\":147.5},{\"type\":\"L\",\"x\":443.5,\"y\":102.5},{\"type\":\"Q\",\"x1\":377,\"y1\":41,\"x\":308,\"y\":11},{\"type\":\"L\",\"x\":312.5,\"y\":60},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":436.5,\"y\":147.5},{\"type\":\"Q\",\"x1\":498,\"y1\":206,\"x\":560,\"y\":294.5},{\"type\":\"L\",\"x\":576.5,\"y\":258.5},{\"type\":\"Q\",\"x1\":510,\"y1\":164,\"x\":443.5,\"y\":102.5},{\"type\":\"L\",\"x\":436.5,\"y\":147.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":560,\"y\":294.5},{\"type\":\"Q\",\"x1\":622,\"y1\":383,\"x\":689,\"y\":501},{\"type\":\"L\",\"x\":716,\"y\":482},{\"type\":\"Q\",\"x1\":643,\"y1\":353,\"x\":576.5,\"y\":258.5},{\"type\":\"L\",\"x\":560,\"y\":294.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":689,\"y\":501},{\"type\":\"L\",\"x\":741,\"y\":593},{\"type\":\"L\",\"x\":768,\"y\":574},{\"type\":\"L\",\"x\":716,\"y\":482},{\"type\":\"L\",\"x\":689,\"y\":501},{\"type\":\"Z\"}]]",
    "o": "[[{\"type\":\"M\",\"x\":682,\"y\":1164},{\"type\":\"Q\",\"x1\":604,\"y1\":1164,\"x\":527.5,\"y\":1122.5},{\"type\":\"L\",\"x\":439.5,\"y\":1157},{\"type\":\"Q\",\"x1\":542,\"y1\":1204,\"x\":646,\"y\":1204},{\"type\":\"L\",\"x\":682,\"y\":1164},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":527.5,\"y\":1122.5},{\"type\":\"Q\",\"x1\":451,\"y1\":1081,\"x\":382.5,\"y\":1005.5},{\"type\":\"L\",\"x\":249.5,\"y\":1026.5},{\"type\":\"Q\",\"x1\":337,\"y1\":1110,\"x\":439.5,\"y\":1157},{\"type\":\"L\",\"x\":527.5,\"y\":1122.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":382.5,\"y\":1005.5},{\"type\":\"Q\",\"x1\":314,\"y1\":930,\"x\":258,\"y\":825},{\"type\":\"L\",\"x\":94.5,\"y\":829},{\"type\":\"Q\",\"x1\":162,\"y1\":943,\"x\":249.5,\"y\":1026.5},{\"type\":\"L\",\"x\":382.5,\"y\":1005.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":258,\"y\":825},{\"type\":\"Q\",\"x1\":202,\"y1\":720,\"x\":165,\"y\":593},{\"type\":\"L\",\"x\":-8,\"y\":581},{\"type\":\"Q\",\"x1\":27,\"y1\":715,\"x\":94.5,\"y\":829},{\"type\":\"L\",\"x\":258,\"y\":825},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":165,\"y\":593},{\"type\":\"Q\",\"x1\":140,\"y1\":508,\"x\":126.5,\"y\":422.5},{\"type\":\"L\",\"x\":-31,\"y\":466.5},{\"type\":\"Q\",\"x1\":-23,\"y1\":524,\"x\":-8,\"y\":581},{\"type\":\"L\",\"x\":165,\"y\":593},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":126.5,\"y\":422.5},{\"type\":\"Q\",\"x1\":113,\"y1\":337,\"x\":113,\"y\":267},{\"type\":\"L\",\"x\":-39,\"y\":354},{\"type\":\"Q\",\"x1\":-39,\"y1\":409,\"x\":-31,\"y\":466.5},{\"type\":\"L\",\"x\":126.5,\"y\":422.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":113,\"y\":267},{\"type\":\"Q\",\"x1\":113,\"y1\":31,\"x\":280,\"y\":31},{\"type\":\"L\",\"x\":-18,\"y\":197.5},{\"type\":\"Q\",\"x1\":-39,\"y1\":267,\"x\":-39,\"y\":354},{\"type\":\"L\",\"x\":113,\"y\":267},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":113,\"y\":267},{\"type\":\"Q\",\"x1\":113,\"y1\":31,\"x\":280,\"y\":31},{\"type\":\"L\",\"x\":42,\"y\":80},{\"type\":\"Q\",\"x1\":3,\"y1\":128,\"x\":-18,\"y\":197.5},{\"type\":\"L\",\"x\":113,\"y\":267},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":113,\"y\":267},{\"type\":\"Q\",\"x1\":113,\"y1\":31,\"x\":280,\"y\":31},{\"type\":\"L\",\"x\":137.5,\"y\":6.5},{\"type\":\"Q\",\"x1\":81,\"y1\":32,\"x\":42,\"y\":80},{\"type\":\"L\",\"x\":113,\"y\":267},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":113,\"y\":267},{\"type\":\"Q\",\"x1\":113,\"y1\":31,\"x\":280,\"y\":31},{\"type\":\"L\",\"x\":265,\"y\":-19},{\"type\":\"Q\",\"x1\":194,\"y1\":-19,\"x\":137.5,\"y\":6.5},{\"type\":\"L\",\"x\":113,\"y\":267},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":453,\"y\":24.5},{\"type\":\"Q\",\"x1\":359,\"y1\":-19,\"x\":265,\"y\":-19},{\"type\":\"L\",\"x\":280,\"y\":31},{\"type\":\"Q\",\"x1\":352,\"y1\":31,\"x\":426.5,\"y\":72},{\"type\":\"L\",\"x\":453,\"y\":24.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":630.5,\"y\":146},{\"type\":\"Q\",\"x1\":547,\"y1\":68,\"x\":453,\"y\":24.5},{\"type\":\"L\",\"x\":426.5,\"y\":72},{\"type\":\"Q\",\"x1\":501,\"y1\":113,\"x\":570.5,\"y\":186.5},{\"type\":\"L\",\"x\":630.5,\"y\":146},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":782,\"y\":330.5},{\"type\":\"Q\",\"x1\":714,\"y1\":224,\"x\":630.5,\"y\":146},{\"type\":\"L\",\"x\":570.5,\"y\":186.5},{\"type\":\"Q\",\"x1\":640,\"y1\":260,\"x\":700,\"y\":362},{\"type\":\"L\",\"x\":782,\"y\":330.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":893,\"y\":563},{\"type\":\"Q\",\"x1\":850,\"y1\":437,\"x\":782,\"y\":330.5},{\"type\":\"L\",\"x\":700,\"y\":362},{\"type\":\"Q\",\"x1\":760,\"y1\":464,\"x\":803,\"y\":586},{\"type\":\"L\",\"x\":893,\"y\":563},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":930.5,\"y\":706},{\"type\":\"Q\",\"x1\":916,\"y1\":631,\"x\":893,\"y\":563},{\"type\":\"L\",\"x\":803,\"y\":586},{\"type\":\"Q\",\"x1\":815,\"y1\":619,\"x\":826.5,\"y\":660},{\"type\":\"L\",\"x\":930.5,\"y\":706},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":930.5,\"y\":706},{\"type\":\"Q\",\"x1\":916,\"y1\":631,\"x\":893,\"y\":563},{\"type\":\"L\",\"x\":826.5,\"y\":660},{\"type\":\"Q\",\"x1\":838,\"y1\":701,\"x\":848,\"y\":745.5},{\"type\":\"L\",\"x\":930.5,\"y\":706},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":945,\"y\":856},{\"type\":\"Q\",\"x1\":945,\"y1\":781,\"x\":930.5,\"y\":706},{\"type\":\"L\",\"x\":848,\"y\":745.5},{\"type\":\"Q\",\"x1\":858,\"y1\":790,\"x\":864,\"y\":836.5},{\"type\":\"L\",\"x\":945,\"y\":856},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":930,\"y\":988},{\"type\":\"Q\",\"x1\":945,\"y1\":925,\"x\":945,\"y\":856},{\"type\":\"L\",\"x\":864,\"y\":836.5},{\"type\":\"Q\",\"x1\":870,\"y1\":883,\"x\":870,\"y\":927},{\"type\":\"L\",\"x\":930,\"y\":988},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":880,\"y\":1099},{\"type\":\"Q\",\"x1\":915,\"y1\":1051,\"x\":930,\"y\":988},{\"type\":\"L\",\"x\":870,\"y\":927},{\"type\":\"Q\",\"x1\":870,\"y1\":975,\"x\":861,\"y\":1018.5},{\"type\":\"L\",\"x\":880,\"y\":1099},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":787.5,\"y\":1175.5},{\"type\":\"Q\",\"x1\":845,\"y1\":1147,\"x\":880,\"y\":1099},{\"type\":\"L\",\"x\":861,\"y\":1018.5},{\"type\":\"Q\",\"x1\":852,\"y1\":1062,\"x\":830.5,\"y\":1094},{\"type\":\"L\",\"x\":787.5,\"y\":1175.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":787.5,\"y\":1175.5},{\"type\":\"Q\",\"x1\":845,\"y1\":1147,\"x\":880,\"y\":1099},{\"type\":\"L\",\"x\":830.5,\"y\":1094},{\"type\":\"Q\",\"x1\":809,\"y1\":1126,\"x\":772.5,\"y\":1145},{\"type\":\"L\",\"x\":787.5,\"y\":1175.5},{\"type\":\"Z\"}],[{\"type\":\"M\",\"x\":646,\"y\":1204},{\"type\":\"Q\",\"x1\":730,\"y1\":1204,\"x\":787.5,\"y\":1175.5},{\"type\":\"L\",\"x\":772.5,\"y\":1145},{\"type\":\"Q\",\"x1\":736,\"y1\":1164,\"x\":682,\"y\":1164},{\"type\":\"L\",\"x\":646,\"y\":1204},{\"type\":\"Z\"}]]"
  ]
  static func getData(text: String) -> [[Drawable]] {
    let decoder = JSONDecoder()
    let chars = charData.mapValues { (value) -> [[Command]] in
      return try! decoder.decode([[Command]].self, from: value.data(using: .utf8)!)
    }
    var ret: [[Drawable]] = []
    
    var offsetX: Double = 400
    var offsetY: Double = 1000
    for ch in Array(text) {
      let char = chars[String(ch)]!
      for shapes in char {
        var d: [Drawable] = []
        for shape in shapes {
          d.append(Drawable(command: CommandType(rawValue: shape.type)!, x: scale(shape.x, offsetX), y: scale(shape.y, offsetY), x1: scale(shape.x1, offsetX), y1: scale(shape.y1, offsetY)))
        }
        ret.append(d)
      }
      offsetX += Double(dimensions[String(ch)]!.x)
      //      offsetY = Double(dimensions[String(ch)]!.y)
    }
    
    return ret
  }
  
  static let unitsPerEm: Double = 2048
  static let fontSize: Double = 14
  static let emToPt: Double = 12
  static func scale(_ n: Double?, _ offset: Double?) -> Double? {
    if n == nil { return nil }
    let val: Double = n! + (offset ?? 0)
    return (1 / unitsPerEm * fontSize) * emToPt * val
  }
}

struct Command: Decodable {
  let type: String
  let x: Double?
  let y: Double?
  let x1: Double?
  let y1: Double?
}
