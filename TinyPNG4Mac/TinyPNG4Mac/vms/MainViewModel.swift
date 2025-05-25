//
//  MainViewModel.swift
//  TinyPNG4Mac
//
//  Created by kyleduo on 2024/11/17.
//

import SwiftUI
import UniformTypeIdentifiers

class MainViewModel: ObservableObject, TPClientCallback {
    @Published var tasks: [TaskInfo] = []
    @Published var monthlyUsedQuota: Int = -1
    @Published var restoreConfirmTask: TaskInfo?
    @Published var settingsNotReadyMessage: String? = nil
    @Published var showQuitWithRunningTasksAlert: Bool = false

    var totalOriginSize: UInt64 {
        tasks.reduce(0) { partialResult, task in
            partialResult + (task.originSize ?? 0)
        }
    }

    var totalFinalSize: UInt64 {
        tasks.filter { $0.status == .completed }
            .reduce(0) { partialResult, task in
                partialResult + (task.finalSize ?? 0)
            }
    }

    var completedTaskCount: Int {
        tasks.count { $0.status == .completed }
    }

    init() {
        TPClient.shared.callback = self
    }

    var failedTaskCount: Int {
        tasks.count { $0.status == .failed }
    }
    func processImageAndCompress(originUrl: URL) -> Data? {
        // 加载图片数据
        guard let imageData = loadImageData(from: originUrl) else {
            return nil
        }
        
        // 创建图片对象
        guard let image = NSImage(data: imageData) else {
            print("无效的图片数据: \(originUrl.lastPathComponent)")
            return imageData // 返回原始数据继续处理
        }
        
        // 压缩图片
        if let compressedData = compressImage(image) {
            // 保存压缩后的图片
            saveCompressedImage(compressedData, originUrl: originUrl)
            return compressedData
        } else {
            print("图片压缩失败: \(originUrl.lastPathComponent)")
            return imageData // 压缩失败，返回原始数据继续处理
        }
    }

    // 加载图片数据
    private func loadImageData(from url: URL) -> Data? {
        var loadedData: Data?
        var loadError: Error?
        
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { fileUrl in
            do {
                loadedData = try Data(contentsOf: fileUrl)
            } catch {
                loadError = error
            }
        }
        
        if let error = loadError {
            let task = TaskInfo(originUrl: url)
            task.updateError(error: TaskError.from(error: error))
            appendTask(task: task)
            print("加载图片数据失败: \(url.lastPathComponent), 错误: \(error.localizedDescription)")
            return nil
        }
        
        return loadedData
    }

    // 压缩图片
    private func compressImage(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.5])
    }

    // 保存压缩后的图片
    private func saveCompressedImage(_ compressedData: Data, originUrl: URL) {
        let originalFileName = originUrl.deletingPathExtension().lastPathComponent
        let originalFileExtension = originUrl.pathExtension
        let compressedFileName = "\(originalFileName).\(originalFileExtension)"
        let outputDirectory = AppContext.shared.appConfig.outputDirectoryUrl ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let compressedFilePath = outputDirectory.appendingPathComponent(compressedFileName)
// let compressedFilePath = URL(string: "file:///Users/lu/Downloads/tinyimage_output/" + (compressedFileName))!
        do {
            try compressedData.write(to: compressedFilePath)
            print("图片压缩成功: \(compressedFilePath.lastPathComponent)")
        } catch {
            print("保存压缩图片失败: \(compressedFilePath.lastPathComponent), 错误: \(error.localizedDescription)")
        }
    }
    
    func createTasks(imageURLs: [URL: URL]) {
        if !validateSettingsBeforeStartTask() {
            return
        }

        Task {
            for (url, inputUrl) in imageURLs {
                let originUrl = url

                let exist = tasks.contains(where: { task in
                    task.originUrl == originUrl && !task.status.isFinished()
                })

                if exist {
                    continue
                }

                if !originUrl.fileExists() {
                    let task = TaskInfo(originUrl: originUrl)
                    task.updateError(error: TaskError.from(message: String(localized: "File does not exists")))
                    appendTask(task: task)
                    continue
                }

                let uuid = UUID().uuidString

                let backupUrl = FileUtils.getBackupUrl(id: uuid)
                do {
                    try originUrl.copyFileTo(backupUrl)
                } catch {
                    let task = TaskInfo(originUrl: originUrl)
                    task.updateError(error: TaskError.from(error: error))
                    appendTask(task: task)
                    continue
                }

                let downloadUrl = FileUtils.getDownloadUrl(id: uuid)
                let previewImage = loadImagePreviewUsingCGImageSource(from: originUrl, maxDimension: 200)

                let fileSize: UInt64
                do {
                    fileSize = try originUrl.sizeOfFile()
                } catch {
                    let task = TaskInfo(originUrl: originUrl)
                    task.updateError(error: TaskError.from(error: error))
                    appendTask(task: task)
                    continue
                }

                let outputUrl: URL
                if AppContext.shared.appConfig.isOverwriteMode() {
                    outputUrl = originUrl
                } else if let outputFolderUrl = AppContext.shared.appConfig.outputDirectoryUrl {
                    let relocatedUrl = FileUtils.getRelocatedRelativePath(of: originUrl, fromDir: inputUrl, toDir: outputFolderUrl)
                    outputUrl = relocatedUrl ?? outputFolderUrl.appendingPathComponent(originUrl.lastPathComponent)
                } else {
                    let task = TaskInfo(originUrl: originUrl)
                    task.updateError(error: TaskError.from(error: FileError.noOutput))
                    appendTask(task: task)
                    continue
                }

                let task = TaskInfo(
                    originUrl: originUrl,
                    backupUrl: backupUrl,
                    downloadUrl: downloadUrl,
                    outputUrl: outputUrl,
                    originSize: fileSize,
                    filePermission: originUrl.posixPermissionsOfFile() ?? 0x644,
                    previewImage: previewImage ?? NSImage(named: "placeholder")!
                )

                print("Task created: \(task)")

                appendTask(task: task)

                guard let _ = processImageAndCompress(originUrl: task.originUrl) else {
                    continue // 处理失败，跳过当前文件
                }
                TPClient.shared.addTask(task: task)
            }
        }
    }

    func retry(_ task: TaskInfo) {
        TPClient.shared.addTask(task: task)
    }

    func restore(_ task: TaskInfo) {
        guard task.status == .completed else {
            return
        }

        restoreConfirmTask = task
    }

    func clearAllTask() {
        TPClient.shared.stopAllTask()
        tasks.removeAll()
    }

    func clearFinishedTask() {
        tasks.removeAll { $0.status.isFinished() }
    }

    func retryAllFailedTask() {
        tasks.filter { $0.status == .failed }
            .forEach { task in
                retry(task)
            }
    }

    func restoreAll() {
        Task {
            for task in tasks {
                doRestore(task: task)
            }
        }
    }

    func restoreConfirmConfirmed() {
        guard let task = restoreConfirmTask else {
            return
        }

        defer { restoreConfirmTask = nil }

        Task {
            doRestore(task: task)
        }
    }

    func cancelAllTask() {
        TPClient.shared.stopAllTask()
    }

    func shouldTerminate() -> Bool {
        return TPClient.shared.runningTasks == 0
    }

    func showRunnningTasksAlert() {
        showQuitWithRunningTasksAlert = true
    }

    /// Validate settings before create tasks.
    /// - Returns true if the settings is valid
    private func validateSettingsBeforeStartTask() -> Bool {
        let config = AppContext.shared.appConfig
        if config.apiKey.isEmpty {
            DispatchQueue.main.async {
                self.settingsNotReadyMessage = String(localized: "Please set the API key first.")
            }
            return false
        }

        if config.isSaveAsMode() {
            if let outputFolderUrl = config.outputDirectoryUrl {
                if !outputFolderUrl.fileExists() {
                    do {
                        try outputFolderUrl.ensureDirectoryExists()
                        return true
                    } catch {
                        DispatchQueue.main.async {
                            self.settingsNotReadyMessage = String(localized: "Failed to create output directory: \(outputFolderUrl.rawPath()), please re-select the output directory.")
                        }
                        return false
                    }
                }

                if !FileUtils.hasReadAndWritePermission(path: outputFolderUrl.rawPath()) {
                    DispatchQueue.main.async {
                        self.settingsNotReadyMessage = String(localized: "No write permission of output folder \(outputFolderUrl.rawPath()), please re-select the output directory.")
                    }
                    return false
                }
            } else {
                DispatchQueue.main.async {
                    self.settingsNotReadyMessage = String(localized: "\"Save As Mode\" is selected. Please config the output directory first.")
                }
                return false
            }
        }

        return true
    }

    private func doRestore(task: TaskInfo) {
        if task.status != .completed {
            return
        }

        if let backupUrl = task.backupUrl {
            do {
                try backupUrl.copyFileTo(task.originUrl, override: true)
                print("restore success")
                DispatchQueue.main.async {
                    task.status = .restored
                    self.notifyTaskChanged(task: task)
                }
            } catch {
                print("restore fail \(error.localizedDescription)")
            }
        } else {
            print("backup not found")
        }
    }

    func restoreConfirmCancel() {
        restoreConfirmTask = nil
    }

    private func appendTask(task: TaskInfo) {
        DispatchQueue.main.async {
            self.tasks.append(task)
        }
    }

    private func loadImagePreviewUsingCGImageSource(from url: URL, maxDimension: CGFloat) -> NSImage? {
        // Create CGImageSource from the URL
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Get image properties to calculate aspect ratio
        guard let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = imageProperties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = imageProperties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        // Calculate aspect ratio
        let aspectRatio = width / height

        // Determine the size for the thumbnail while preserving the aspect ratio
        var thumbnailSize: CGSize
        if width > height {
            thumbnailSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
        } else {
            thumbnailSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
        }

        // Create options to generate thumbnail
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        ]

        // Generate the thumbnail image
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        // Create an NSImage from the CGImage
        return NSImage(cgImage: cgImage, size: thumbnailSize)
    }

    func onTaskChanged(task: TaskInfo) {
        print("onTaskStatusChanged, \(task)")

        notifyTaskChanged(task: task)
    }

    func onMonthlyUsedQuotaUpdated(quota: Int) {
        debugPrint("onMonthlyUsedQuotaUpdated \(quota)")
        monthlyUsedQuota = quota
    }

    private func notifyTaskChanged(task: TaskInfo) {
        if let index = tasks.firstIndex(where: { item in item.id == task.id }) {
            tasks[index] = task
            sortTasksInPlace(&tasks)
        }
    }

    private func sortTasksInPlace(_ tasks: inout [TaskInfo]) {
        tasks.sort { $0 < $1 }
    }
}

struct AlertInfo {
    var type: AlertType
    var title: String
    var message: String
}

enum AlertType {
    case restoreConfirm
}
