import Foundation
import UIKit

// =====================================================================
// Downloads: Filme und Folgen aufs iPhone laden und offline schauen.
// Lädt über eine Hintergrund-Sitzung (läuft weiter, wenn die App im Hintergrund ist).
// Die Liste liegt als JSON neben den Dateien (Application Support/Downloads, nicht im iCloud-Backup).
// Die Oberfläche (app.js) spricht über window.AndroidBridge.dl… damit (siehe WebApp.swift).
// =====================================================================

final class Downloads: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloads()

    /// Liste hat sich geändert (Fortschritt, fertig, Fehler) – die Oberfläche bekommt den neuen Stand
    var onChange: (() -> Void)?
    /// Vom System übergeben, wenn die App für fertige Hintergrund-Downloads geweckt wurde
    var backgroundCompletion: (() -> Void)?

    private let maxParallel = 2
    private var items: [[String: Any]] = []
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastSave = Date.distantPast

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }()
    private var listFile: URL { dir.appendingPathComponent("list.json") }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "tv.imperum.downloads")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        c.timeoutIntervalForRequest = 60
        c.httpMaximumConnectionsPerHost = maxParallel
        c.httpAdditionalHeaders = ["User-Agent": "ImperumTV/1.0 (iPhone)"]
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        load()
    }

    /// Beim Start: laufende Hintergrund-Downloads wieder zuordnen, Rest der Warteschlange starten
    func start() {
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for t in all {
                    guard let dt = t as? URLSessionDownloadTask, let id = dt.taskDescription else { continue }
                    if self.index(id) != nil && (t.state == .running || t.state == .suspended) { self.tasks[id] = dt } else { dt.cancel() }
                }
                // „lädt“, aber ohne Aufgabe (App wurde beendet): neu einreihen
                for i in self.items.indices where (self.items[i]["status"] as? String) == "loading" {
                    let id = self.items[i]["id"] as? String ?? ""
                    if self.tasks[id] == nil { self.items[i]["status"] = "queued" }
                }
                self.pump()
                self.changed(save: true)
            }
        }
    }

    // ---------- Liste ----------

    private func load() {
        guard let d = try? Data(contentsOf: listFile),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        items = arr
    }

    private func save() {
        lastSave = Date()
        if let d = try? JSONSerialization.data(withJSONObject: items) { try? d.write(to: listFile, options: .atomic) }
    }

    private func index(_ id: String) -> Int? { items.firstIndex { ($0["id"] as? String) == id } }

    private func changed(save now: Bool) {
        if now || Date().timeIntervalSince(lastSave) > 5 { save() }
        onChange?()
    }

    /// Liste für die Oberfläche (fertige Einträge mit Adresse der Datei)
    func json() -> String {
        let out: [[String: Any]] = items.map { o in
            var x = o
            x.removeValue(forKey: "url")
            if (o["status"] as? String) == "done", let f = o["file"] as? String { x["file"] = dir.appendingPathComponent(f).absoluteString }
            else { x.removeValue(forKey: "file") }
            return x
        }
        guard let d = try? JSONSerialization.data(withJSONObject: out), let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    func storageJSON() -> String {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = v?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        return "{\"free\":\(free),\"total\":\(total)}"
    }

    // ---------- Befehle aus der Oberfläche ----------

    func add(_ json: String) {
        guard let d = json.data(using: .utf8), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = o["id"] as? String, let url = o["url"] as? String, URL(string: url) != nil else { return }
        if let i = index(id) {
            if (items[i]["status"] as? String) == "failed" { retry(id) }
            return
        }
        o["status"] = "queued"; o["bytes"] = 0; o["total"] = 0
        if o["at"] == nil { o["at"] = Date().timeIntervalSince1970 * 1000 }
        items.append(o)
        pump()
        changed(save: true)
    }

    func delete(_ id: String) {
        if let t = tasks[id] { t.cancel(); tasks[id] = nil }
        if let i = index(id) {
            if let f = items[i]["file"] as? String { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            items.remove(at: i)
        }
        try? FileManager.default.removeItem(at: resumeFile(id))
        pump()
        changed(save: true)
    }

    func retry(_ id: String) {
        guard let i = index(id), (items[i]["status"] as? String) == "failed" else { return }
        items[i]["status"] = "queued"
        items[i].removeValue(forKey: "error")
        pump()
        changed(save: true)
    }

    // ---------- Laden ----------

    private func resumeFile(_ id: String) -> URL { dir.appendingPathComponent(safe(id) + ".resume") }
    private func safe(_ id: String) -> String { id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) }

    /// Nächste wartende Downloads starten (höchstens zwei gleichzeitig)
    private func pump() {
        var running = items.filter { ($0["status"] as? String) == "loading" }.count
        for i in items.indices where running < maxParallel && (items[i]["status"] as? String) == "queued" {
            guard let id = items[i]["id"] as? String, let s = items[i]["url"] as? String, let url = URL(string: s) else { continue }
            let task: URLSessionDownloadTask
            if let rd = try? Data(contentsOf: resumeFile(id)) {
                task = session.downloadTask(withResumeData: rd)
                try? FileManager.default.removeItem(at: resumeFile(id))
            } else {
                task = session.downloadTask(with: url)
            }
            task.taskDescription = id
            tasks[id] = task
            items[i]["status"] = "loading"
            task.resume()
            running += 1
        }
    }

    private func fail(_ id: String, _ msg: String) {
        guard let i = index(id) else { return }
        items[i]["status"] = "failed"
        items[i]["error"] = msg
        changed(save: true)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, let i = index(id) else { return }
        items[i]["status"] = "loading"
        items[i]["bytes"] = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { items[i]["total"] = totalBytesExpectedToWrite }
        changed(save: false)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let i = index(id) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let code = http?.statusCode ?? 200
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        if !(200...299).contains(code) { fail(id, "Server meldet HTTP \(code)"); return }
        if type.hasPrefix("text/") || type.contains("json") || size < 200_000 {
            fail(id, "Der Anbieter hat keine Videodatei geliefert"); return
        }
        let ext = (items[i]["ext"] as? String ?? "mp4").lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let name = safe(id) + "." + (ext.isEmpty ? "mp4" : ext)
        let target = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            fail(id, "Datei konnte nicht gespeichert werden (Speicher voll?)"); return
        }
        items[i]["status"] = "done"
        items[i]["file"] = name
        items[i]["bytes"] = size
        items[i]["total"] = size
        items[i].removeValue(forKey: "error")
        tasks[id] = nil
        pump()
        changed(save: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        tasks[id] = nil
        defer { pump() }
        guard let error = error as NSError?, let i = index(id) else { return }
        if error.code == NSURLErrorCancelled && (items[i]["status"] as? String) != "loading" { return }   // selbst abgebrochen/gelöscht
        // Später an derselben Stelle weitermachen
        if let rd = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? rd.write(to: resumeFile(id)) }
        let msg: String
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: msg = "Internet weg – tippe auf „Nochmal versuchen“"
        case NSURLErrorTimedOut: msg = "Der Anbieter antwortet nicht"
        default: msg = error.localizedDescription
        }
        fail(id, msg)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.save()
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
