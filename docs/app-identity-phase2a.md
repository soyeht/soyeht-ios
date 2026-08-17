# Fase 2a — Identidade de app, capacidade zero · CONTRATO CONGELADO

Branch `feat/mac-app-identity-phase2a`, empilhada sobre
`feat/mac-web-pane-phase1` (PR 21) em `f9f0190f`.
Revisão do plano: kairos, cassia, sia — 3/3 com emendas, todas incorporadas.

Este documento é o **contrato de interfaces** da 2a. Mudança de assinatura
passa pela celia antes — as três fatias são escritas contra ele em paralelo.

## O que é a Fase 2a

Um **app** passa a existir como coisa própria: um bundle local de HTML/JS/CSS
com manifesto, servido numa **origem própria**, renderizado numa pane que é
uma **configuração distinta** da pane web da Fase 1.

**Capacidade: ZERO.** Nenhuma ponte, nenhum acesso nativo. Um app da 2a pode
*menos* que um site comum, porque não tem rede. O ganho é a fundação:
identidade, isolamento e o primitivo de confinamento de disco.

### Por que identidade antes de capacidade

A pane web da Fase 1 aceita qualquer `http/https` — abrimos uol.com.br e
chatgpt.com nela durante o E2E. Expor uma ponte "à pane web" daria acesso ao
disco para qualquer site. **Capacidade sem identidade não existe.** Por isso
a identidade, originalmente prevista para a Fase 3, sobe para cá.

### Decisão de produto que molda esta fase

Qualquer usuário pagante poderá publicar apps (a loja é Fase 3). Isso não
muda o escopo da 2a, mas torna quatro coisas **requisito duro** em vez de
boa prática, porque não se retrofita identidade depois:

- manifesto nasce com campos de **publicador** e **assinatura**;
- **CSP** e **proibição de código hospedado remotamente**;
- **rede é capacidade declarada e separada** de disco, desde o manifesto —
  a combinação das duas é o que permite exfiltração;
- nomes e versões de app são dados de terceiro: tratados como não-confiáveis
  na renderização.

## Contrato 1 — `PathScope`, o primitivo de confinamento

**Nasce aqui, não em 2c** (correção do kairos). O handler de esquema recebe
caminho **controlado pela página**; resolvê-lo com comparação de string
criaria a quinta reimplementação da regra frágil que já existe no repo, e a
primeira cujo input não vem do usuário.

```swift
/// Confinamento de acesso a um diretório, imposto pelo kernel.
/// Nunca compara caminhos como string para decidir acesso.
struct PathScope {
    /// fd do diretório raiz, aberto com O_DIRECTORY. Vive enquanto o escopo vive.
    private let rootFD: Int32

    init(rootDirectory: URL) throws
    func openFileForReading(relativePath: String) throws -> Int32
    func close()
}
```

Regras de imposição, **medidas nesta máquina** (teste em C, resultados
abaixo). Toda abertura usa:

```
openat(rootFD, rel, O_RDONLY | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY | O_CLOEXEC)
```

| caminho | `O_NOFOLLOW_ANY` | `O_RESOLVE_BENEATH` | ambas |
|---|---|---|---|
| `sub/file.txt` | abriu | abriu | abriu |
| `../outside/secret.txt` | **ABRIU** | recusou | recusou |
| symlink apontando para fora | recusou | recusou | recusou |
| `/etc/hosts` | recusou ⚠️ | recusou | recusou |
| `/private/etc/hosts` | **ABRIU** | recusou | recusou |

⚠️ **Não leia a coluna `O_NOFOLLOW_ANY` como "bloqueia absoluto".** A recusa
de `/etc/hosts` é acidente do macOS — `/etc` é symlink para `/private/etc` e
a flag pegou o symlink do primeiro componente. Com absoluto sem symlink no
caminho, essa flag **abre**. **`O_RESOLVE_BENEATH` é o único dos dois que
confina por desenho.** Esta nota existe para que ninguém "otimize" removendo
`BENEATH` por parecer redundante.

Ainda no contrato:
- Recusar antes da syscall, como camada de erro claro (não como imposição):
  caminho absoluto, componente vazio, e **componente que COMECE com `..`** —
  esta última forma fecha `..namedfork/rsrc` de graça, e não apenas o `..`
  literal.
- Falha por symlink devolve **erro explícito e distinguível** ("componente é
  symlink"), nunca falha silenciosa. Projetos reais têm symlink legítimo
  (`node_modules` de pnpm, dotfiles via stow): fail-closed é a decisão certa,
  mas o app precisa poder explicar ao usuário. Isso é **comportamento
  esperado no aceite**, não bug.
- Nada de `URL.path` + `FileManager` na leitura do bundle. Todo I/O pelo fd.

## Contrato 2 — manifesto do app

```swift
struct AppManifest: Codable, Hashable {
    let schemaVersion: Int          // 1
    let id: String                  // [a-z0-9-], 3...64
    let name: String                // dado de terceiro
    let version: String
    let entry: String               // caminho relativo, resolvido por PathScope
    let publisher: AppPublisher     // nasce agora (decisão de produto)
    let capabilities: [String]      // 2a: DEVE ser vazio
    let optionalCapabilities: [String]  // pré-declaração; 2a: vazio
}
```

- **Decodificação estrita explícita** (cassia): `Codable` sintetizado
  **ignora** chaves desconhecidas. Rejeitar chave extra exige decoder
  próprio, inclusive nos objetos aninhados. Limite de tamanho do arquivo
  **antes** do parser.
- `capabilities` não-vazio em 2a é **erro de instalação**, não aviso.
- `entry` é caminho relativo e só é aberto via `PathScope`.
- **Fingerprint do bundle** (hash do conteúdo) é calculado na instalação e
  guardado com o app. É a ele que as concessões da 2c ficarão atadas — sem
  isso, uma atualização silenciosa herdaria permissões concedidas a outro
  código.

## Contrato 3 — origem própria e serviço do bundle

Cada app instalado recebe **esquema próprio**: `soyehtapp-<id>://local/…`.
Consequências desejadas: a política de mesma origem isola apps entre si sem
código nosso, e o handler pode sintetizar cabeçalhos por resposta.

`AppBundleSchemeHandler: WKURLSchemeHandler`:
- resolve o caminho pedido **exclusivamente** por `PathScope`;
- responde com `Content-Type` derivado da extensão, `X-Content-Type-Options:
  nosniff`, e **CSP**: `default-src 'none'; script-src 'self'; style-src
  'self'; img-src 'self' data:; connect-src 'none'` — `connect-src 'none'`
  é o que torna a 2a incapaz de exfiltrar, e é o requisito duro citado acima;
- caminho fora do escopo, symlink ou arquivo ausente → resposta de erro,
  nunca exceção não tratada;
- `stop` cancela trabalho pendente (a task lança exceção ObjC se usada depois
  de parada — precedente já tratado no `ClawSiteURLSchemeHandler`).

## Contrato 4 — a pane de app é outra configuração

**Não** é a pane web com uma flag (regra que os três endossaram): são duas
funções de fábrica distintas. A configuração de app:
- registra o `AppBundleSchemeHandler` **antes** de construir a webview;
- **não registra handler de mensagem nenhum** — a ausência é o controle, e
  em 2b só a configuração de app ganhará a ponte;
- `websiteDataStore`: ver spike abaixo;
- navegação **travada ao próprio esquema do app** mais `about:blank`
  (emenda da sia): mais estrita que a Fase 1, que aceita qualquer http/https.
  `createWebViewWith` devolve `nil`.

Novo kind de pane `app(AppPaneState)`, seguindo o padrão da Fase 1, com a
mesma lição: **a identidade da pane não deriva de estado que muda**. Aqui a
identidade é o id da instalação.

## Contrato 5 — SPIKE obrigatório (bloqueia o congelamento do contrato da 2b)

**Armazenamento em origem de esquema custom** (sia). O WebKit trata origens
não-http(s) como opacas em algumas versões, e `localStorage`/IndexedDB podem
não persistir. Um editor que não guarda as próprias configurações é meio
editor.

Spike: app mínimo que escreve e lê `localStorage` e IndexedDB, fecha a pane,
reabre, e relança o app. **Resultado registrado no PR**, seja qual for. Se
não persistir, `kv.store` entra como capacidade da 2b — muda o *conteúdo* da
2b, não a ordem das fatias.

## Divisão do trabalho

| Fatia | Dono | Arquivos |
|---|---|---|
| A — `PathScope` + testes | **kairos** | `AppPlatform/PathScope.swift` (novo), testes em `SoyehtMacTests` |
| B — manifesto, instalação, fingerprint | **cassia** | `AppPlatform/AppManifest.swift`, `AppInstallStore.swift` (novos) + testes |
| C — esquema, CSP, pane de app, spike | **sia** | `AppPlatform/AppBundleSchemeHandler.swift`, `AppPaneViewController.swift`, `PaneContent` (case `app`), pbxproj |
| integração + E2E | **celia** | build assinado, E2E no Dev.app, PR |

Regras de convivência (herdadas da Fase 1, funcionaram): commits pequenos e
frequentes; **só a sia roda `xcodebuild`** nesta onda, os demais usam o
pacote SwiftPM de domínio; ninguém toca arquivo fora da própria fatia sem
avisar; **nunca** encostar no `/Applications/Soyeht.app` — validação só no
Soyeht Dev.app; **ninguém funde nada**.

E a regra de processo que a Fase 1 nos ensinou: *commitado não é enviado*.
Confirmar o hash no remoto antes de reportar uma fatia como pronta.

## Aceite

1. Build verde; testes de domínio **executados**.
2. `PathScope`: testes de fuga cobrindo `..`, absoluto com e **sem** symlink
   no caminho, symlink em cada componente, `..namedfork`, componente vazio.
   O teste que mais importa é o **negativo**: a fuga tem de falhar.
3. Manifesto: chave desconhecida **rejeitada**; `capabilities` não-vazio
   recusado; arquivo acima do limite recusado antes do parser.
4. E2E no Dev.app: app instalado manualmente abre em pane; CSP bloqueia
   script externo e `connect-src 'none'` bloqueia `fetch` para fora
   (verificar no console, não por inspeção de código); navegação para
   `https://` externo é recusada; a pane web da Fase 1 **continua
   funcionando igual**.
5. Spike de armazenamento com resultado registrado.
6. Duas panes de apps diferentes não compartilham origem.

— celia
