import Foundation
import Testing
@testable import NotProtonApp

@Suite("Highball runtime isolation")
struct HighballTests {
    // Contract: the setup copies a complete Highball engine without changing its
    // source, and a malformed replacement cannot destroy an existing runner.
    // Regression: copying only engine/ loses the frameworks, or replacing before
    // verification destroys a working clone. CrossOver-only clone tests do not
    // exercise Highball's sibling layout or independent source runtime.
    @Test("A Highball clone keeps runtime siblings and never replaces a valid copy with bad input")
    func cloneIsolation() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appending(path: "np-highball-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appending(path: "source")
        let root = source.appending(path: "engine")
        let loader = root.appending(path: "lib/wine/x86_64-unix/wine")
        let ntdll = root.appending(path: "lib/wine/x86_64-windows/ntdll.dll")
        for p in [loader, ntdll, source.appending(path: "frameworks/runtime"),
                  source.appending(path: "renderers/dxmt/wine/overlay")] {
            try fm.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(p.lastPathComponent.utf8).write(to: p)
        }
        let build = RunnerBuild(bundleVersion: "highball-fixture", releaseVersion: "fixture", flavor: nil,
            loaderSHA256: Digest.sha256IfPresent(loader)!,
            cleanNtdll: [.x86_64Windows: Digest.sha256IfPresent(ntdll)!], patchedNtdll: [:], provider: .highball)
        let install = CrossOverInstall(bundle: source, releaseVersion: "fixture", support: .supported(build), provider: .highball)
        let runners = temp.appending(path: "runners")
        _ = try RunnerInstaller.clone(from: install, runners: runners)
        let clone = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let clonedLoader = clone.appending(path: "lib/wine/x86_64-unix/wine")
        #expect(try Data(contentsOf: clonedLoader) == Data("wine".utf8))
        #expect(fm.fileExists(atPath: clone.deletingLastPathComponent().appending(path: "frameworks/runtime").path))
        #expect(fm.fileExists(atPath: clone.deletingLastPathComponent().appending(path: "renderers/dxmt/wine/overlay").path))
        try Data("bad update".utf8).write(to: loader)
        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners)
        }
        #expect(try Data(contentsOf: clonedLoader) == Data("wine".utf8))
        #expect(try Data(contentsOf: loader) == Data("bad update".utf8))
    }

    // Contract: runtime discovery respects a custom Highball home and rejects
    // engine builds for which the byte-specific patch is not validated.
    // Regression: a moved installation is missed, or an arbitrary Wine version
    // is treated as patchable. No existing tests discover Highball manifests.
    @Test("Discovery honors a configured home and refuses an unknown engine")
    func discovery() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "np-highball-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let config = temp.appending(path: "config.json")
        try Data("{\"home\":\"/Volumes/My Games/Highball\"}".utf8).write(to: config)
        #expect(HighballSource.home(environment: [:], config: config).path == "/Volumes/My Games/Highball")
        #expect(HighballSource.home(environment: ["HIGHBALL_HOME": "/custom"], config: config).path == "/custom")
        try Data("{\"id\":\"unknown-wine\",\"arch\":\"x86_64\"}".utf8).write(to: temp.appending(path: "manifest.json"))
        let result = HighballSource.inspect(engine: temp)
        #expect(!result.isUsable)
        #expect(result.support == .unsupportedBuild("unknown-wine"))
    }
}

// Real-engine contract: the patched free Wine runtime boots a fresh prefix and
// loads both halves of the Steam bridge. Arbitrary DLL/header incompatibility
// can pass fixture-based hash and layout checks, so this owns the ABI risk.
@Suite("Highball real engine")
struct HighballLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_TEST_HIGHBALL_ENGINE"] != nil))
    func bootsAndLoadsBridge() throws {
        let source = URL(filePath: ProcessInfo.processInfo.environment["NOTPROTON_TEST_HIGHBALL_ENGINE"]!)
        let install = HighballSource.inspect(engine: source)
        #expect(install.isUsable)
        guard install.isUsable else { return }
        let temp = FileManager.default.temporaryDirectory.appending(path: "np-highball-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let runners = temp.appending(path: "runners")
        let bridge = temp.appending(path: "bridge")
        let build = try RunnerInstaller.clone(from: install, runners: runners)
        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        _ = try BridgePayload.stage(located: BridgePayload.locate(), bridge: bridge)
        _ = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: bridge)
        _ = try RunnerPatcher.install(build: build, root: root, bridge: bridge)
        #expect(RunnerPatcher.verify(build: build, root: root, bridge: bridge).isEmpty)
        let prefix = temp.appending(path: "prefix")
        var env = HighballSource.runtimeEnvironment(runner: root)
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all,+lsteamclient"
        env["WINEDLLOVERRIDES"] = "d3d11,dxgi=n,b;steamclient,steamclient64=n;lsteamclient=b"
        env["HOME"] = NSHomeDirectory()
        env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = SupportPaths.Steam.innerClient.path
        env["WINEDLLPATH"] = root.appending(path: "lib/wine/x86_64-windows").path + ":" + root.appending(path: "lib/wine/x86_64-unix").path
        env["WINEMSYNC"] = "0"
        env["WINELOADER"] = root.appending(path: "bin/wine").path
        env["WINESERVER"] = root.appending(path: "bin/wineserver").path
        defer { _ = try? Shell.run(root.appending(path: "bin/wineserver").path, ["-k"], environment: env) }
        let boot = try Shell.run(root.appending(path: "bin/wine").path, ["wineboot", "--init"], environment: env)
        try #require(boot.succeeded, Comment(rawValue: boot.stderr))
        _ = try Shell.check(root.appending(path: "bin/wineserver").path, ["-w"], environment: env)
        #expect(FileManager.default.fileExists(atPath: prefix.appending(path: "system.reg").path))
        // The native bridge's Wine unix-call binding is actually invoked, rather
        // than merely testing that the DLL exists or LoadLibrary returns a handle.
        let c = temp.appending(path: "probe.c")
        try Data("""
        #include <windows.h>
        #include <stdio.h>
        int main(int argc, char **argv) {
            HMODULE h = LoadLibraryA(argc > 1 ? argv[1] : "lsteamclient.dll");
            if (!h) { printf("load failed %lu\\n", GetLastError()); return 1; }
            typedef void *(__cdecl *factory)(const char *, int *);
            factory f = (factory)GetProcAddress(h, "CreateInterface");
            if (!f) return 2;
            if (argc > 1) {
                HMODULE bridge = GetModuleHandleA("lsteamclient.dll");
                void *target = bridge ? (void *)GetProcAddress(bridge, "CreateInterface") : NULL;
                unsigned char *code = (unsigned char *)f;
        #ifdef _WIN64
                if (!target || code[0] != 0x48 || code[1] != 0xb8 || *(void **)(code + 2) != target) return 4;
        #else
                if (!target || code[0] != 0xb8 || *(void **)(code + 1) != target) return 4;
        #endif
            }
            int result = -1;
            void *client = f("SteamClient020", &result);
            printf("bridge client=%s result=%d\\n", client ? "present" : "absent", result);
            return client ? 0 : 3;
        }
        """.utf8).write(to: c)
        // The foreground Mac launcher moves the unix loader beside runtime links.
        // Exercise that actual layout too; a bin/ loader copy cannot locate ../lib.
        let launcher = temp.appending(path: "Game.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: launcher, withIntermediateDirectories: true)
        let unixDir = root.appending(path: "lib/wine/x86_64-unix")
        for file in try FileManager.default.contentsOfDirectory(at: unixDir, includingPropertiesForKeys: nil) where file.lastPathComponent != "wine" {
            try FileManager.default.createSymbolicLink(at: launcher.appending(path: file.lastPathComponent), withDestinationURL: file)
        }
        let gameLoader = launcher.appending(path: "wine")
        try FileManager.default.copyItem(at: unixDir.appending(path: "wine"), to: gameLoader)
        for compiler in ["/opt/homebrew/bin/x86_64-w64-mingw32-gcc", "/opt/homebrew/bin/i686-w64-mingw32-gcc"] {
            let probe = temp.appending(path: compiler.contains("i686") ? "probe32.exe" : "probe64.exe")
            _ = try Shell.check(compiler, [c.path, "-o", probe.path])
            let valveDLL = SupportPaths.bridge.appending(path: compiler.contains("i686") ? "steamclient.dll" : "steamclient64.dll")
            try FileManager.default.copyItem(at: valveDLL, to: temp.appending(path: valveDLL.lastPathComponent))
            for loader in [root.appending(path: "bin/wine"), gameLoader] {
                env["WINELOADER"] = loader.path
                let result = try Shell.run(loader.path, [probe.path, valveDLL.lastPathComponent], environment: env)
                try #require(result.succeeded, Comment(rawValue: "\(compiler) via \(loader.path): " + result.stdout + String(result.stderr.suffix(14000))))
                #expect(result.stdout.contains("bridge client=present result=0"))
            }
        }
        // Copy isolation matters even after the loader is re-signed and ntdll patched.
        #expect(HighballSource.inspect(engine: source).isUsable)
    }
}
