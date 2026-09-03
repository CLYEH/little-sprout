// LS-146 — 合成一支最短、有效的 MP4（H.264），供審核用 demo 家庭的影片示範素材使用。
//
// 為什麼不用 `xcrun simctl io <udid> recordVideo`（票面原本建議的做法）：實測會撞
// CoreSimulator 的「Host recording」全域鎖（NSPOSIXErrorDomain code=16 "Resource busy"）
// ——這把鎖是整台主機層級的，不是每個模擬器各自獨立，其他 worktree／agent 同時在錄影
// （或前一次異常中止留下的殘留狀態）都會讓這裡卡死或報錯，而且清這把鎖需要
// `killall CoreSimulatorService`，會連帶影響其他 worktree 正在用的模擬器（違反「只關自己
// 的模擬器」的硬規則）。改用 AVFoundation 直接合成，不碰模擬器、不佔用那把全域鎖，
// 多個 agent 平行執行互不干擾。
//
// 用法：swift review-demo-genvideo.swift <output.mp4> [seconds，預設 2.0]
// 輸出：stdout 印一行整數秒數（與 App 端 VideoDurationFormat 同規則：max(1, floor(實測秒數))），
// 供呼叫端直接塞進 media.duration_seconds。
import AVFoundation
import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: review-demo-genvideo.swift <output.mp4> [seconds]\n".utf8))
    exit(1)
}
let outputPath = args[1]
let seconds = args.count >= 3 ? (Double(args[2]) ?? 2.0) : 2.0
let fps: Int32 = 10
let width = 640
let height = 480

let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: url)

guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
    FileHandle.standardError.write(Data("AVAssetWriter 建立失敗\n".utf8))
    exit(1)
}
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ]
)
writer.add(input)
// F6（merge-review R1）：startWriting() 的回傳值原本被丟棄——它回 false 時（例如輸出路徑
// 不可寫、codec 不支援），下面的 requestMediaDataWhenReady callback 可能一次都不會觸發，
// done.wait() 會永遠等不到訊號，把呼叫端（review-demo-seed.sh 的 `dur=$(swift …)`，本身
// 沒有 timeout）一起卡死。開工前先檢查，失敗就帶著 writer.error 立刻退出。
guard writer.startWriting() else {
    let msg = writer.error.map { "\($0)" } ?? "unknown"
    FileHandle.standardError.write(Data("startWriting 失敗：\(msg)\n".utf8))
    exit(1)
}
writer.startSession(atSourceTime: .zero)

let frameCount = max(2, Int(seconds * Double(fps)))
var frame = 0
let queue = DispatchQueue(label: "LS146.video")
let done = DispatchSemaphore(value: 0)

input.requestMediaDataWhenReady(on: queue) {
    while input.isReadyForMoreMediaData {
        if frame >= frameCount {
            input.markAsFinished()
            writer.finishWriting { done.signal() }
            return
        }
        var pixelBuffer: CVPixelBuffer?
        // F6（merge-review R1，PLAUSIBLE）：原本兩處失敗都 `continue`——frame 不前進、
        // while 條件不變，會是永不結束的忙迴圈，done.wait() 跟著永遠等不到訊號（同上）。
        // pool／buffer 配置失敗在實務上少見，但一旦發生就該立刻 fail loud，不是空轉。
        guard let pool = adaptor.pixelBufferPool else {
            FileHandle.standardError.write(Data("pixelBufferPool 為 nil（frame \(frame)）\n".utf8))
            exit(1)
        }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else {
            FileHandle.standardError.write(Data("CVPixelBufferPoolCreatePixelBuffer 失敗（frame \(frame)）\n".utf8))
            exit(1)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ptr = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let value = UInt8((frame * 200) / max(frameCount, 1)) + 40
            memset(ptr, Int32(value), bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = CMTimeMake(value: Int64(frame), timescale: fps)
        // N4（merge-review R2，PLAUSIBLE）：append 的回傳值原本被丟棄。若 writer 在
        // startWriting 成功之後才失敗（例如寫入途中磁碟滿），迴圈原本會照常跑完、
        // finishWriting 以 .failed 狀態回呼（done.signal() 照樣觸發，不會卡住——這點跟
        // F6 那三處不同），但呼叫端量到一個壞檔的 duration：量到 0 秒時靜默印 1、
        // exit 0（假裝成功），量到 NaN 時整數轉換直接 trap。失敗就立刻帶著
        // writer.error 退出，不要讓迴圈以為自己還在正常前進。
        guard adaptor.append(buffer, withPresentationTime: time) else {
            let msg = writer.error.map { "\($0)" } ?? "unknown"
            FileHandle.standardError.write(Data("adaptor.append 失敗（frame \(frame)）：\(msg)\n".utf8))
            exit(1)
        }
        frame += 1
    }
}
// F6（merge-review R1）：上面兩處已經把已知的忙迴圈成因收斂掉，這裡再加一道保險——
// 任何沒預期到的卡住（例如 finishWriting 的 completion handler 沒被呼叫）都有個上限，
// 不會把呼叫端（沒有自己 timeout 的 review-demo-seed.sh）一起無限期卡死。
if done.wait(timeout: .now() + 30) == .timedOut {
    FileHandle.standardError.write(Data("影片合成逾時（30 秒）：\(outputPath)\n".utf8))
    exit(1)
}

// 量測寫出結果的實際秒數：這支腳本是種子工具、不是 App 端程式碼，不受 App 的
// async-only lint 慣例約束，用同步 API 圖簡單。
let asset = AVURLAsset(url: url)
let durationSeconds = CMTimeGetSeconds(asset.duration)
let intDuration = max(1, Int(durationSeconds.rounded(.down)))
print(intDuration)
