# Fase 1 — Pane `web` (Soyeht Apps) · CONTRATO CONGELADO

Branch: `feat/mac-web-pane-phase1` · base `origin/main` @ 3b7182cf
Worktree: um clone/worktree local desta branch
Revisão do plano: kairos, cassia, sia — 3/3 aprovaram (2026-08-17).

Este documento é o **contrato de interfaces**. Ele existe para que as três
fatias sejam escritas em paralelo sem esperar umas pelas outras. Se alguma
assinatura aqui precisar mudar, **avise a celia antes de mudar** — quem
depende dela está escrevendo código contra ela agora.

## O que é a Fase 1

Panes do Soyeht macOS passam a hospedar conteúdo web. Entrega: um novo kind
de pane `web` renderizado por `WKWebView`, o app "navegador" (barra de URL,
voltar/avançar/recarregar) e a tool MCP `open_web`.

**Apps ≠ Claw Store** (decisão de produto): claw é microVM Linux; app é
conteúdo HTML numa pane. Não encostar no catálogo/manifesto de claws.

Fora de escopo, não implementar nesta fase: bridge JS↔nativo, manifesto de
app, permissões, loja, `file://`, iOS. Sem `userContentController`, sem user
scripts, sem `evaluateJavaScript`.

## Contrato 1 — Modelo (`TerminalApp/SoyehtMac/Model/PaneContent.swift`)

```swift
enum PaneContentKind: String, Codable, Hashable {
    case terminal
    case editor
    case git
    case web            // NOVO
}

/// Identidade e estado corrente são campos SEPARADOS — ver "Por que anchorURL".
struct WebPaneState: Codable, Hashable {
    var anchorURL: String    // IMUTÁVEL após a criação. Define matchingKey.
    var url: String          // página corrente. Write-back + restore.
    var title: String?       // último título conhecido (header da pane).

    init(anchorURL: String, url: String? = nil, title: String? = nil)
    // url default = anchorURL
}
```

Braços exigidos em `PaneContent`:

| membro | valor para `.web` |
|---|---|
| `kind` | `.web` |
| `displayKind` | `"web"` |
| `primaryPath` | **`nil`** — não é caminho de arquivo; ver Contrato 4 |
| `matchingKey` | `"web:" + WebURLCanonicalizer.canonical(state.anchorURL)` |
| `init(from:)` / `encode(to:)` | chave `web`, padrão dos vizinhos |

### Por que `anchorURL` (correção obrigatória da revisão)

`installSpecialContent` (`PaneGrid/PaneViewController.swift`) só reaproveita
o view controller existente quando `existing.matchingKey == content.matchingKey`.
`ConversationStore` é `@Observable` com granularidade **per-property**
(documentado em `Store/ConversationStore.swift:11-18`): qualquer mutação
invalida e faz `rebindFromStore` → `configureContent` em todas as panes.

Logo, se `matchingKey` derivasse da URL **corrente**, cada navegação faria:
write-back → invalidação → keys divergentes → `removeSpecialContent`
(**WKWebView destruída**) → VC novo → página recarrega do zero, perdendo
scroll, formulário e histórico. Com `anchorURL` imutável a navegação cai no
branch same-key → `updateContent` in-place, exatamente como o `EditorPane`
(cuja key vem de `rootPath`, estável em uso).

**Loop-safety (obrigatório, os dois lados):**
- `WebPaneViewController.updateContent` é **no-op** quando a URL recebida já
  é a carregada (senão: update → load → didFinish → write-back → update…).
- o write-back é **pulado** quando o estado novo é igual ao que já está no
  store.

## Contrato 2 — Canonicalização e validação de URL

Arquivo novo: `TerminalApp/SoyehtMac/WebPane/WebURL.swift` (dono: cassia).

```swift
enum WebURLError: Error, LocalizedError {
    case malformed(String)
    case unsupportedScheme(String)
    case missingHost(String)
    case credentialsInURL(String)
}

enum WebURL {
    /// Fail-closed. Única porta de entrada de URL do sistema.
    /// Aceita SOMENTE http/https absolutos, com host não-vazio e sem
    /// user/password embutidos. Qualquer outra coisa lança.
    static func validate(_ raw: String) throws -> URL

    /// Identidade estável para dedupe. NÃO é saneamento de segurança.
    /// Regras (decididas na revisão, cassia):
    ///   - lowercase SOMENTE em scheme e host
    ///   - preserva query, porta não-default, path case-sensitive e
    ///     percent-encoding
    ///   - remove fragmento
    ///   - equivale path "/" com path vazio (e SÓ esse caso — não remover
    ///     trailing slash de paths em geral, muda o recurso)
    static func canonical(_ raw: String) -> String
}
```

`WebURLCanonicalizer.canonical` no Contrato 1 = `WebURL.canonical`.

**Onde `validate` é obrigatório** (as quatro portas — omitir qualquer uma
anula as outras três):
1. router MCP (`handleOpenWeb`) — o script Python **não é fronteira de
   confiança**, a validação vale no Swift;
2. barra de URL da pane (entrada do usuário);
3. `WKNavigationDelegate.decidePolicyFor navigationAction` — **a cada
   navegação**, incluindo redirects. Permitir http/https e `about:blank`;
   `.cancel` para todo o resto (`mailto:`, `data:`, `javascript:`, `file:`,
   `itms:`, `intent:`, schemes custom). Sem isso o WKWebView entrega o
   scheme ao handler do sistema.
4. `createWebViewWith` (window.open / target=_blank) — navegar in-place
   apenas se validar; caso contrário ignorar.

**Downloads**: cancelar. Se um dia abrir externamente, `NSWorkspace.open` na
**URL do request já validada** — nunca no arquivo baixado (abrir o arquivo
baixado é execução de código adjacente).

## Contrato 3 — View controller (`TerminalApp/SoyehtMac/WebPane/`)

`WebPaneViewController: NSViewController, PaneContentViewControlling`.

- `contentKind` = `.web`; `matchingKey` = a do state; `headerAccessories` =
  `.specialDefault`.
- `headerTitle` = título da página (fallback: host); `headerSubtitle` = host.
- `WKWebViewConfiguration` com `websiteDataStore = .default()` (perfil único
  de navegador — decisão v1; sem perfis nem clear-data nesta fase).
- Write-back: no `didFinish` de navegação **main-frame**, atualizar o state
  interno **antes** de gravar via `convStore.updateContent`. Precedente
  direto: `EditorPaneViewController.swift` (:507, :910, :970).
- `prepareForClose()`: `stopLoading()`, delegates a nil, teardown da webview.

## Contrato 4 — Automação / MCP

- `SoyehtAutomationRequest.RequestType`: + `case openWeb = "open_web"`.
- `Payload`: + `url: String?`, + `newPane: Bool?`.
- Resposta: `SoyehtAutomationResponse.OpenedSpecialPane` ganha
  **`url: String?`** (opcional — não quebra os consumidores atuais).
  Motivo: `primaryPath` é `nil` para web e `path` cairia no diretório home,
  reportando dado errado (e desnecessário) no wire e em `list_panes`.
  Pane web **não** deve reportar o home como `working_directory`.
- `open_web` nunca anexa terminal stack (`attachTerminalStack: false`).
- Tool MCP `open_web` em `scripts/soyeht-mcp`: args `url` (obrigatório),
  `workspace_id`, `window_id`, `new_pane` (default false).

### Dedupe / reuse (decisão da revisão)

- reuse quando `canonical(anchorURL)` bate; `new_pane: true` salta o lookup
  e sempre cria.
- **escopo**: `createOrFocusSpecialPane` hoje procura em todos os workspaces
  visíveis, ignorando o `workspaceID` pedido. Para `open_web` o dedupe deve
  ser **no workspace alvo**.
- Efeito colateral desejado: um segundo `open_web` do mesmo anchor foca a
  pane **e navega de volta** para o anchor (comportamento de "aba").

## Contrato 5 — Resiliência de snapshot (guard R1)

Problema medido: `WorkspaceStore.Snapshot` (`Store/WorkspaceStore.swift:1073`)
decodifica `conversations: [Conversation]?` de uma vez em `load()` (:1085,
decode em :1108). Um kind desconhecido lança `DataCorrupted` e cai em
`backupCorruptedFile` + reseed (:1110, :1216) — ou seja, **uma pane
desconhecida reseta todo o estado do app** (workspaces inteiros; o arquivo
antigo é preservado como backup, mas a sessão volta ao zero).

Isso não conserta binários já lançados. O valor é blindar o binário da Fase 1
contra os kinds das Fases 2/3 (ex.: um kind `app` no futuro, com downgrade).

Regra: decode tolerante **por conversa**, no nível do `Snapshot` — não dentro
de `PaneContent` (não fabricar um `.terminal` falso no lugar de um payload
que não entendemos).

**Ponto em aberto, decidir MEDINDO (dono: kairos):** conversa não-decodificável
deve ser *descartada* (com log) ou virar *placeholder*? Critério: o que
acontece com o layout tree quando um leaf de `PaneNode` aponta para uma
conversa inexistente. Se o grid já degrada de forma limpa (pane vazia,
reconciliação que remove o leaf), descartar é correto e mais honesto. Se um
leaf órfão quebra ou deixa buraco visual, placeholder é a escolha. Medir
antes de decidir; registrar a medição no PR.

## Divisão do trabalho

Todos na **mesma worktree/branch**, em arquivos disjuntos.

| Fatia | Dono | Arquivos |
|---|---|---|
| A — modelo + resiliência | **kairos** | `Model/PaneContent.swift`, `Store/WorkspaceStore.swift`, testes em `TerminalApp/SoyehtMacTests/` |
| B — view controller + janela | **cassia** | `WebPane/*` (novos), `PaneGrid/PaneViewController.swift` (1 braço no switch), `MainWindow/SoyehtMainWindowController.swift` (`openWebPane`), `SoyehtMac.xcodeproj/project.pbxproj` (+ linkar `WebKit.framework`) |
| C — automação + MCP | **sia** | `App/SoyehtAutomationService.swift`, `App/SoyehtAutomationRequestRouter.swift`, `scripts/soyeht-mcp` |
| integração + E2E | **celia** | build de integração, E2E no Dev.app, PR |

Regras de convivência na worktree:
- commits pequenos e frequentes na branch (não segurar trabalho local);
- **não rodar `xcodebuild` simultaneamente** — durante a onda 1, quem builda
  o app é a cassia; kairos usa o pacote SwiftPM de domínio
  (`TerminalApp/SoyehtMacTests`), sia testa o lado Python isolado;
- ninguém toca em arquivo fora da sua fatia sem avisar a celia;
- **nunca** tocar em `/Applications/Soyeht.app` (é o app de trabalho real do usuário). Toda
  validação de app roda no **Soyeht Dev.app**.

## Aceite (o E2E é obrigatório — pedido explícito do dono do produto)

1. Build do SoyehtMac verde (com WebKit linkado).
2. Testes de domínio **executados** (não só compilados): round-trip Codable
   de `.web`; `matchingKey` **estável** quando só `url`/`title` mudam;
   canonicalização (fragmento removido, host lowercase, query/porta/trailing
   slash preservados, credenciais rejeitadas); não-colisão com keys de
   editor/git; snapshot com kind desconhecido preserva as demais conversas.
3. E2E no Dev.app: `open_web` abre a pane; navegar **não recria a webview**
   (scroll preservado — é o teste da correção do `anchorURL`); segundo
   `open_web` do mesmo anchor foca e volta ao anchor; `new_pane: true`
   duplica; `workspace_id` explícito é respeitado.
4. Rejeições E2E: `open_web` com `file:`/`data:`/`javascript:`/scheme custom
   /sem host → erro; mesmo pela barra de URL; página que redireciona ou faz
   `window.open` para scheme estranho → cancelado.
5. Relaunch do Dev.app: a pane web restaura na última URL navegada.
6. `capture_pane` / `send_pane_input` na pane web → erro apropriado, sem crash.
7. Snapshot antigo (sem web) carrega intacto.
