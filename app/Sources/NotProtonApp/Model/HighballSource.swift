import Foundation

// Highball engines are independent, freely built Wine runtimes. The engine manifest,
// loader and PE ntdlls must all match before any build-specific patch is applied.
enum HighballSource {
    static let engineID = "x64-crossover26.3-r23"
    static let wineArchiveSHA256 = "51355c786168c5c84eec51e3bc364c8a1acd87437e1418b27887a51d42a5657b"
    static let build = RunnerBuild(
        bundleVersion: "highball-wine11-r23", releaseVersion: "Highball Wine 11 r23", flavor: nil,
        loaderSHA256: "ef45e2e94c0cab0eae1d20579850c45cd743cc142473b2118e1f3896ddb84da5",
        cleanNtdll: [
            .x86_64Windows: "513fa65b55c2c064e174fc9c797af75eced97c1de992aa7e4f7e228aa06e2e5b",
            .i386Windows: "ef5fec28279a8998c5fafbe68738b6b2658457d0bdc8eb03763124f8c2ef7733",
        ],
        patchedNtdll: [
            .x86_64Windows: "b132aafb1e100a74f3418a9adca4eaa63fa95270c966933c7b7f740f80340200",
            .i386Windows: "899d2929927747c83b2059ad5a5666de9011691b0586f53a67065bde57f7f394",
        ],
        tools: [CompatTool(name: "notproton-highball", flavor: .rosetta, display: "Highball Wine 11 r23 — Rosetta")],
        provider: .highball
    )

    static var defaultHome: URL { SupportPaths.applicationSupport.appending(path: "Highball") }

    static func home(environment: [String: String] = ProcessInfo.processInfo.environment,
                     config: URL = defaultHome.appending(path: "config.json")) -> URL {
        if let path = environment["HIGHBALL_HOME"], !path.isEmpty { return URL(filePath: path) }
        if let data = try? Data(contentsOf: config),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = object["home"] as? String, path.hasPrefix("/") {
            // Do not silently switch to a different home when a configured drive is absent.
            return URL(filePath: path)
        }
        return defaultHome
    }

    static func discover() -> [CrossOverInstall] {
        let engines = home().appending(path: "engines")
        let manual = CrossOverSource.manualBundles()
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
        let automatic = ((try? FileManager.default.contentsOfDirectory(at: engines, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            .filter { candidate in !manual.contains { CrossOverSource.same($0, candidate) } }
        return (manual.map { inspect(engine: $0, isManual: true) } + automatic.map { inspect(engine: $0) })
            .sorted(by: CrossOverSource.preferred)
    }

    static func inspect(engine: URL, isManual: Bool = false) -> CrossOverInstall {
        func result(_ support: CrossOverSupport, _ version: String? = nil) -> CrossOverInstall {
            CrossOverInstall(bundle: engine, releaseVersion: version, support: support,
                             isManual: isManual, provider: .highball)
        }
        guard let data = try? Data(contentsOf: engine.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = manifest["id"] as? String else { return result(.unreadable) }
        guard id == engineID, manifest["arch"] as? String == "x86_64",
              let components = manifest["components"] as? [String: [String: Any]],
              components["wine"]?["sha256"] as? String == wineArchiveSHA256 else {
            return result(.unsupportedBuild(id), id)
        }
        let root = engine.appending(path: "engine")
        guard Digest.sha256IfPresent(CrossOverSource.unixLoader(inRoot: root)) == build.loaderSHA256,
              (try? CrossOverSource.verifyPatchInputs(root: root, build: build)) != nil,
              FileManager.default.isExecutableFile(atPath: root.appending(path: "bin/wine").path),
              FileManager.default.isExecutableFile(atPath: root.appending(path: "bin/wineserver").path),
              FileManager.default.fileExists(atPath: engine.appending(path: "frameworks").path),
              FileManager.default.fileExists(atPath: engine.appending(path: "renderers/dxmt/wine/x86_64-windows/d3d11.dll").path)
        else { return result(.unsupportedBuild("\(id): incomplete or changed runtime"), id) }
        return result(.supported(build), build.releaseVersion)
    }

    static func clone(from install: CrossOverInstall, to staging: URL) throws {
        let source = install.bundle
        let fm = FileManager.default
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        var copied = try Shell.run("/bin/cp", ["-c", "-R", source.path, staging.path])
        if !copied.succeeded {
            try? fm.removeItem(at: staging)
            copied = try Shell.run("/bin/cp", ["-R", source.path, staging.path])
        }
        guard copied.succeeded else { throw StepFailure(step: "Copy Highball", detail: copied.stderr) }
        // Keep the existing private runner layout; relative runtime-library links still
        // resolve to the frameworks beside the engine. Never change Highball's source.
        try fm.moveItem(at: staging.appending(path: "engine"), to: staging.appending(path: "CrossOver"))
        // Patching must never follow an absolute runtime link back to Highball's
        // source, even if its contents happen to match the supported hashes.
        let privateRoot = staging.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for arch in ["x86_64-unix", "x86_64-windows", "i386-windows"] {
            let directory = staging.appending(path: "CrossOver/lib/wine/\(arch)")
            guard directory.resolvingSymlinksInPath().path.hasPrefix(privateRoot) else {
                throw StepFailure(step: "Copy Highball", detail: "The engine contains an external Wine runtime link.")
            }
            let file = directory.appending(path: arch.hasSuffix("unix") ? "wine" : "ntdll.dll")
            guard file.resolvingSymlinksInPath().path.hasPrefix(privateRoot) else {
                throw StepFailure(step: "Copy Highball", detail: "The engine contains an external Wine binary link.")
            }
        }
    }

    static func runtimeEnvironment(runner: URL) -> [String: String] {
        let root = runner.deletingLastPathComponent()
        let frameworks = root.appending(path: "frameworks").path
        return [
            "DYLD_FALLBACK_LIBRARY_PATH": "\(frameworks):\(frameworks)/GStreamer.framework/Versions/1.0/lib",
            "DYLD_FALLBACK_FRAMEWORK_PATH": frameworks,
            "GST_PLUGIN_PATH": "\(frameworks)/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
            "WINEDLLPATH_PREPEND": root.appending(path: "renderers/dxmt/wine").path,
            "WINEDLLOVERRIDES": "d3d11,dxgi=n,b",
            "DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN": "1",
            "CX_HOME": root.path,
        ]
    }
}
