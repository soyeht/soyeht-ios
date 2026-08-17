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

**Desvio aprovado (2026-08-17): `final class`, não `struct`.** O esboço
abaixo dizia `struct`; o tipo é de referência, e a razão é de correção, não
de estilo. Um `struct` copyable **fecharia o fd duas vezes** — a cópia e o
original — e um double-close é precisamente o modo de falha por reuso de
número que este desenho existe para evitar: fecha-se um descritor que outro
código já passou a usar. `deinit` num `struct` exigiria `~Copyable`, que não
aceita armazenamento comum no handler de esquema. **Posse única de descritor
é semântica de referência.** Assinaturas públicas permanecem idênticas.

```swift
/// Confinamento de acesso a um diretório, imposto pelo kernel.
/// Nunca compara caminhos como string para decidir acesso.
final class PathScope {
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

struct AppPublisher: Codable, Hashable {
    let id: String           // identificador estável, opaco na 2a: [a-z0-9-], 3...64
    let displayName: String  // DADO DE TERCEIRO — não-confiável na renderização
}
```

### Assinatura e proveniência (lacuna fechada 2026-08-17, achado da cassia)

**O manifesto NÃO tem campo de assinatura.** Esta é a decisão, e o motivo
importa mais que a regra:

Um artefato **não declara a própria confiabilidade**. Se o manifesto
carregasse `signature: String?`, a 2a teria um campo que ninguém verifica e
que, três meses depois, alguém trata como verificado. É a forma mais comum
de segurança de fachada. Além disso, uma assinatura *dentro* da estrutura que
ela assina exige canonicalização para ser coerente — e o repo já resolve isso
do jeito certo em outro lugar: `RelayStreamOfferContract` mantém o payload
canônico e a assinatura **fora** dele.

Portanto, proveniência é **derivada da instalação**, nunca declarada pelo
bundle:

```swift
/// Como este app entrou na máquina. Derivado pelo instalador, nunca lido
/// do manifesto. Desconhecido ⇒ não-verificado, por construção.
enum AppProvenance: String, Codable, Hashable {
    case localUnverified   // única aceita na 2a
}
```

- **Na 2a: apenas `localUnverified`.** Instalação é manual, não há raiz de
  confiança, não há verificação criptográfica. E isso fica **explícito no
  modelo e na UI** ("instalado localmente, não verificado"), em vez de
  implícito.
- `AppPublisher` na 2a é **transportado e exibido**, nunca autoridade: não
  concede nada, não é usado em decisão de acesso. Serve para o usuário saber
  o que instalou, e para o campo já existir quando a Fase 3 precisar dele.
- Quando a assinatura chegar (Fase 3), ela vem como **envelope externo** que
  cobre os bytes canônicos do manifesto **mais** o fingerprint do bundle, com
  a proveniência ganhando casos novos. O manifesto não muda de forma.
- Segue a lei já escrita em `docs/local-workspace-trust-model.md`: estado
  derivado de prova, nunca projeção gravável; ausente ⇒ fraco.

Registro do que **fica de fora da 2a**, para ninguém supor o contrário:
verificação criptográfica, raiz de confiança, revogação remota (kill switch)
e identidade de publicador com accountability. Tudo isso é Fase 3, e é o que
a decisão "qualquer usuário pagante publica" vai exigir.

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

### O fingerprint cobre TUDO que é servível (correção de 2026-08-17)

Achado medido na fronteira entre as fatias, e é a classe de defeito que não
mora dentro de nenhuma delas:

O cálculo pulava arquivos ocultos (`.skipsHiddenFiles`), e nem o handler de
esquema nem o `PathScope` recusam nome começando com ponto — o confinamento
só barra componente que comece com `..`. Somadas, as duas decisões — cada uma
razoável isolada — deixavam um `.payload.js` **servível para a webview e fora
do fingerprint**. Troca-se o conteúdo dele, o fingerprint não muda, a
concessão da 2c permanece válida, e o código executado é outro. Isso desmente
a defesa que justificamos por escrito contra o ataque "publica benigno,
atualiza malicioso".

Política, em três camadas baratas:
1. **O fingerprint cobre todo o conteúdo**, sem pular ocultos.
2. **A instalação recusa ou remove metadados que não são conteúdo de app**,
   com `.DS_Store` nomeado — senão o Finder tocando a pasta faz o app "mudar"
   sozinho.
3. **O handler recusa servir componente começando com ponto**, para que
   qualquer resíduo seja inerte mesmo se escapar das duas primeiras.

Invariante a preservar em qualquer mudança futura: **o conjunto servível e o
conjunto medido têm de ser o mesmo conjunto.** Divergência entre eles é o
buraco, independentemente de qual dos dois lados "está certo".

O percurso da árvore na instalação passa a usar o `PathScope`
(`openDirectoryForListing`) em vez de `FileManager` — é o caminho que recebe
um diretório apontado de fora e, portanto, o pior lugar do sistema para não
ter confinamento.

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
