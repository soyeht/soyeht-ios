import XCTest

/// Runs the shell teardown script for real, in `--dry-run`, against a fixture
/// HOME — instead of matching its text.
///
/// The text guards in `MCPTeardownScriptGuardTests` are defeatable: a reviewer
/// demonstrated an edit that reassigns `SOYEHT_MCP_LAUNCHERS` to a single
/// element, keeps every string those guards look for, and silently stops
/// removing the development launcher. Only executing the script catches that.
final class MCPTeardownScriptExecutionTests: XCTestCase {

    private var fixtureHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("soyeht-teardown-fixture-\(UUID().uuidString)", isDirectory: true)

        let bin = fixtureHome.appendingPathComponent(".local/bin", isDirectory: true)
        let cache = fixtureHome
            .appendingPathComponent("Library/Caches/claude-cli-nodejs/-project", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // Ours, and two lookalikes that belong to somebody else.
        for launcher in ["soyeht-mcp", "soyeht-dev-mcp", "soyeht-mcp-someone-else"] {
            let url = bin.appendingPathComponent(launcher)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755 as Int16)], ofItemAtPath: url.path
            )
        }
        for dir in ["mcp-logs-soyeht", "mcp-logs-soyeht-dev",
                    "mcp-logs-soyeht-someone-else", "mcp-logs-soyehtfoo"] {
            try FileManager.default.createDirectory(
                at: cache.appendingPathComponent(dir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        if let fixtureHome { try? FileManager.default.removeItem(at: fixtureHome) }
        try super.tearDownWithError()
    }

    func testUninstallerRemovesBothIdentitiesAndSparesLookalikes() throws {
        let planned = try dryRunPlan()

        XCTAssertTrue(planned.contains { $0.hasSuffix("/.local/bin/soyeht-mcp") },
                      "não removeu o lançador de release; plano = \(planned)")
        XCTAssertTrue(planned.contains { $0.hasSuffix("/.local/bin/soyeht-dev-mcp") },
                      "não removeu o lançador de dev; plano = \(planned)")
        XCTAssertTrue(planned.contains { $0.hasSuffix("/mcp-logs-soyeht") },
                      "não removeu os logs de release; plano = \(planned)")
        XCTAssertTrue(planned.contains { $0.hasSuffix("/mcp-logs-soyeht-dev") },
                      "não removeu os logs de dev; plano = \(planned)")

        for alheio in ["soyeht-mcp-someone-else", "mcp-logs-soyeht-someone-else", "mcp-logs-soyehtfoo"] {
            XCTAssertFalse(planned.contains { $0.hasSuffix("/\(alheio)") },
                           "reclamou \(alheio), que não é nosso; plano = \(planned)")
        }
    }

    /// `--dry-run` must plan, never delete.
    func testDryRunTouchesNothingOnDisk() throws {
        _ = try dryRunPlan()
        for survivor in [".local/bin/soyeht-mcp",
                         ".local/bin/soyeht-dev-mcp",
                         "Library/Caches/claude-cli-nodejs/-project/mcp-logs-soyeht-dev"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixtureHome.appendingPathComponent(survivor).path),
                "o dry-run apagou \(survivor)"
            )
        }
    }

    // MARK: -

    /// The paths the script says it would remove, restricted to the fixture so
    /// anything it plans outside it (system paths on the developer's Mac) is
    /// ignored.
    private func dryRunPlan() throws -> [String] {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/uninstall-soyeht-macos.sh")
        if !FileManager.default.isReadableFile(atPath: script.path) {
            XCTFail("desinstalador ausente em \(script.path)")
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--dry-run", "--yes", "--keep-app"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = fixtureHome.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        // Read while it runs: the pipe buffer would deadlock a chatty script.
        var data = Data()
        let handle = output.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "o script saiu com \(process.terminationStatus)")

        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "[dry-run] rm -rf ") else { return nil }
                let path = String(line[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                return path.hasPrefix(fixtureHome.path) ? path : nil
            }
    }

    // MARK: - The repository installer, executed

    /// Running the MCP from a checkout is development, so the installer must
    /// write the development launcher unless told otherwise. Executed rather
    /// than matched, for the same reason as the teardown above.
    func testInstallerWritesTheLauncherOfTheRequestedIdentity() throws {
        let bin = fixtureHome.appendingPathComponent("install-target", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let byDefault = try runInstaller(identity: nil, binDirectory: bin)
        XCTAssertEqual(byDefault.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-dev-mcp").path),
                      "a omissão não escreveu o lançador de dev; saída = \(byDefault.text)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-mcp").path),
                       "a omissão escreveu o lançador da produção")
        XCTAssertTrue(byDefault.text.contains("soyeht-dev"), "não anunciou a chave a configurar")

        let release = try runInstaller(identity: "release", binDirectory: bin)
        XCTAssertEqual(release.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-mcp").path))
    }

    func testInstallerRefusesAnUnknownIdentityWithoutWritingAnything() throws {
        let bin = fixtureHome.appendingPathComponent("install-refuse", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let result = try runInstaller(identity: "producao", binDirectory: bin)
        XCTAssertEqual(result.status, 2, "devia sair com 2; saída = \(result.text)")
        let written = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        XCTAssertTrue(written.isEmpty, "escreveu \(written) apesar de recusar")
    }

    /// The installer must survive a broken `git`: a checkout that is not a
    /// repository, a worktree whose registration was removed, no git at all.
    /// It knows this failure mode because it happened — the worktree these
    /// tests run in lost its registration, every `git` call returned 128, and
    /// `set -euo pipefail` killed the script before it wrote anything.
    func testInstallerSurvivesABrokenGit() throws {
        let bin = fixtureHome.appendingPathComponent("install-nogit", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let result = try runInstaller(identity: nil, binDirectory: bin, sabotageGit: true)
        XCTAssertEqual(result.status, 0, "morreu com git avariado; saída = \(result.text)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bin.appendingPathComponent("soyeht-dev-mcp").path),
            "não escreveu o lançador com git avariado; saída = \(result.text)"
        )
    }

    /// A directory holding a `git` that always fails, to put first on PATH.
    private func brokenGitDirectory() throws -> URL {
        let dir = fixtureHome.appendingPathComponent("broken-git-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = dir.appendingPathComponent("git")
        try "#!/bin/sh\nexit 128\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755 as Int16)], ofItemAtPath: git.path
        )
        return dir
    }

    private func runInstaller(
        identity: String?,
        binDirectory: URL,
        sabotageGit: Bool = false,
        instaladorEm: URL? = nil
    ) throws -> (status: Int32, text: String) {
        let script = instaladorEm ?? repoRoot().appendingPathComponent("scripts/install-soyeht-mcp")
        // XCTFail, não XCTSkip: este ficheiro está no repositório e TEM de
        // existir. Saltar em silêncio deixaria a suite verde sem o testar.
        if !FileManager.default.isReadableFile(atPath: script.path) {
            XCTFail("instalador ausente em \(script.path)")
            return (-1, "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SOYEHT_MCP_BIN_DIR"] = binDirectory.path
        if let identity { environment["SOYEHT_MCP_IDENTITY"] = identity }
        else { environment.removeValue(forKey: "SOYEHT_MCP_IDENTITY") }
        if sabotageGit {
            let stub = try brokenGitDirectory().path
            environment["PATH"] = stub + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var data = Data()
        let handle = pipe.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - O lançador não pode servir o clone de outra pessoa

    /// Com o git avariado, `SOYEHT_GIT_COMMON_DIR` fica vazio no lançador
    /// gerado. Sem exigir que seja não-vazio, duas cadeias vazias comparam
    /// iguais e a guarda degenera de "este checkout pertence ao meu clone"
    /// para "qualquer repositório git com um scripts/soyeht-mcp executável".
    func testLauncherInstalledWithBrokenGitDoesNotServeAnotherClone() throws {
        let bin = fixtureHome.appendingPathComponent("guard-bin", isDirectory: true)
        let alheio = fixtureHome.appendingPathComponent("outro-clone/scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alheio, withIntermediateDirectories: true)

        let marcador = "SERVIDO-PELO-CLONE-ALHEIO"
        let intruso = alheio.appendingPathComponent("soyeht-mcp")
        try "#!/bin/sh\necho \(marcador)\n".write(to: intruso, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755 as Int16)], ofItemAtPath: intruso.path
        )

        // Tem MESMO que ser um repositório git: o lançador só avalia a guarda
        // quando `git rev-parse --show-toplevel` devolve alguma coisa. Sem
        // isto o teste passaria pelo motivo errado — verificado com mutante.
        let raizAlheia = alheio.deletingLastPathComponent()
        let iniciou = try correr("/usr/bin/env", ["git", "init", "-q", raizAlheia.path])
        XCTAssertEqual(iniciou.status, 0, "não consegui criar o repositório alheio: \(iniciou.text)")

        // A fonte da instalação também leva marcador. Sem isto, o estado
        // correto do teste seria saída VAZIA — e "serviu o servidor certo" e
        // "o lançador rebentou" ficariam indistinguíveis. Foi assim que este
        // teste começou, e um lançador com BASE_MCP inexistente passava.
        let marcadorLegitimo = "SERVIDO-PELO-CLONE-DE-INSTALACAO"
        let clonaDeInstalacao = try prepararCloneDeInstalacao(imprimindo: marcadorLegitimo)

        let instalacao = try runInstaller(
            identity: nil,
            binDirectory: bin,
            sabotageGit: true,
            instaladorEm: clonaDeInstalacao
        )
        XCTAssertEqual(instalacao.status, 0, "não instalou; saída = \(instalacao.text)")

        let saida = try executarLancador(
            bin.appendingPathComponent("soyeht-dev-mcp"),
            dentroDe: alheio.deletingLastPathComponent()
        )
        XCTAssertFalse(saida.contains(marcador),
                       "o lançador serviu o clone de outra pessoa; saída = \(saida)")
        XCTAssertTrue(saida.contains(marcadorLegitimo),
                      "o lançador não serviu o próprio checkout; saída = \(saida)")
    }

    /// Uma cópia do instalador real ao lado de um `scripts/soyeht-mcp` que
    /// imprime um marcador, para que o teste consiga distinguir "serviu o
    /// servidor certo" de "não serviu nada".
    private func prepararCloneDeInstalacao(imprimindo marcador: String) throws -> URL {
        let raiz = fixtureHome.appendingPathComponent("clone-instalacao", isDirectory: true)
        let scripts = raiz.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

        let instaladorReal = repoRoot().appendingPathComponent("scripts/install-soyeht-mcp")
        let destino = scripts.appendingPathComponent("install-soyeht-mcp")
        try? FileManager.default.removeItem(at: destino)
        try FileManager.default.copyItem(at: instaladorReal, to: destino)

        let servidor = scripts.appendingPathComponent("soyeht-mcp")
        try "#!/bin/sh\necho \(marcador)\n".write(to: servidor, atomically: true, encoding: .utf8)
        for url in [destino, servidor] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755 as Int16)], ofItemAtPath: url.path
            )
        }
        return destino
    }

    @discardableResult
    private func correr(_ executavel: String, _ argumentos: [String]) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executavel)
        process.arguments = argumentos
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var data = Data()
        let handle = pipe.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func executarLancador(_ lancador: URL, dentroDe diretorio: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [lancador.path, "--help"]
        process.currentDirectoryURL = diretorio
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var data = Data()
        let handle = pipe.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - O desinstalador em shell limpa as configurações dos agentes

    /// `clean_mcp_configs()` é um bloco Python embutido no script de shell, e
    /// removia só a chave de release nos quatro ficheiros de configuração —
    /// enquanto o mesmo script apagava o lançador de dev. Ficava uma entrada
    /// pendurada a apontar para um ficheiro que já não existe.
    func testShellUninstallerRemovesBothKeysFromEveryAgentConfig() throws {
        let claude = fixtureHome.appendingPathComponent(".claude.json")
        let factory = fixtureHome.appendingPathComponent(".factory/mcp.json")
        let opencode = fixtureHome.appendingPathComponent(".config/opencode/opencode.json")
        let codex = fixtureHome.appendingPathComponent(".codex/config.toml")
        for url in [factory, opencode, codex] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }

        let servidores = """
        {"mcpServers":{"soyeht":{"command":"a"},"soyeht-dev":{"command":"b"},"outro":{"command":"c"}}}
        """
        try servidores.write(to: claude, atomically: true, encoding: .utf8)
        try servidores.write(to: factory, atomically: true, encoding: .utf8)
        try """
        {"mcp":{"soyeht":{"command":["a"]},"soyeht-dev":{"command":["b"]},"outro":{"command":["c"]}}}
        """.write(to: opencode, atomically: true, encoding: .utf8)
        try """
        [mcp_servers.soyeht]
        command = "a"

        [mcp_servers.soyeht-dev]
        command = "b"

        [mcp_servers.soyeht-device]
        command = "alheio"

        [mcp_servers.outro]
        command = "c"
        """.write(to: codex, atomically: true, encoding: .utf8)

        // Corre APENAS o bloco Python embutido, extraído do próprio script:
        // executar o desinstalador inteiro apagaria caminhos reais fora deste
        // HOME de fixture, como o Homebrew do theyOS.
        let saida = try executarLimpezaDeConfigs()
        XCTAssertFalse(saida.contains("Traceback"), "o bloco Python rebentou: \(saida)")

        for url in [claude, factory, opencode] {
            let texto = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(texto.contains("\"soyeht\""), "\(url.lastPathComponent) manteve soyeht")
            XCTAssertFalse(texto.contains("\"soyeht-dev\""), "\(url.lastPathComponent) manteve soyeht-dev")
            XCTAssertTrue(texto.contains("\"outro\""), "\(url.lastPathComponent) apagou o que não é nosso")
        }
        let toml = try String(contentsOf: codex, encoding: .utf8)
        XCTAssertFalse(toml.contains("[mcp_servers.soyeht]"))
        XCTAssertFalse(toml.contains("[mcp_servers.soyeht-dev]"))
        XCTAssertTrue(toml.contains("[mcp_servers.soyeht-device]"), "apanhou um sósia")
        XCTAssertTrue(toml.contains("[mcp_servers.outro]"))
    }

    /// Extrai o heredoc `<<'PY' ... PY` de `clean_mcp_configs()` e corre-o com
    /// o HOME de fixture. É o mesmo texto que é entregue, sem os `rm -rf` do
    /// script que apontam para caminhos reais da máquina.
    private func executarLimpezaDeConfigs() throws -> String {
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/uninstall-soyeht-macos.sh"),
            encoding: .utf8
        )
        guard let inicio = script.range(of: "\"$py\" - \"$HOME\" \"$DRY_RUN\" <<'PY'\n"),
              let fim = script.range(of: "\nPY\n", range: inicio.upperBound..<script.endIndex)
        else {
            XCTFail("não encontrei o bloco Python de clean_mcp_configs")
            return ""
        }
        let corpo = String(script[inicio.upperBound..<fim.lowerBound])

        let temporario = fixtureHome.appendingPathComponent("clean_mcp_configs.py")
        try corpo.write(to: temporario, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", temporario.path, fixtureHome.path, "false"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var data = Data()
        let handle = pipe.fileHandleForReading
        try process.run()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
