# Fase 2b — A ponte de capacidades · CONTRATO CONGELADO

Branch `feat/mac-capability-bridge-phase2b`, empilhada sobre
`feat/mac-app-identity-phase2a` (PR 23) em `263ee5e1`.
Base de desenho: `plano-fase2-v2` (revisado 3/3) + o que a 2a **mediu**.

Mudança de assinatura passa pela celia antes — as fatias são escritas em
paralelo contra este documento.

## O que é a 2b

Um app instalado passa a poder **pedir coisas ao nativo**. Esta fase abre a
porta pela primeira vez, e a abre no ponto mais estreito possível: **uma
única capacidade, `metrics.read`, que não toca disco**.

A escolha é deliberada. Estrear a ponte com acesso a arquivos validaria dois
modos de falha ao mesmo tempo — o de identificar quem chama e o de confinar
o que é acessado. Estreando com métricas, só o primeiro está em jogo, e um
erro não vaza arquivo do usuário.

## O que a 2a MEDIU e que muda o desenho

Estes não são pressupostos; foram observados no app real:

- **Armazenamento persiste** em origem de esquema próprio ⇒ `kv.store` sai da
  lista de capacidades desta fase.
- **A origem é contexto seguro** (`isSecureContext` verdadeiro), ao contrário
  do que a literatura sobre esquemas próprios afirma ⇒ APIs modernas estão
  disponíveis; não precisamos contorná-las.
- **Script inline não executa** sob a CSP da 2a ⇒ ver o spike abaixo, porque
  isso pode alcançar a própria ponte.

## SPIKE BLOQUEANTE — a CSP alcança o script injetado?

**Nada é escrito na fatia da ponte antes disso.**

A ponte precisa de um relay: um `WKUserScript` injetado pelo nativo no mundo
isolado, porque o JS do app vive no mundo da página e não enxerga o handler.
A teoria diz que script injetado por `WKUserContentController` **não** passa
pela CSP do documento, por ser injeção de contexto e não carregamento de
recurso. **A teoria também dizia que a flag de symlink confinava o acesso, e
não confinava.**

Spike: app mínimo sob a CSP real da 2a, com um user script injetado no mundo
isolado que apenas chama o handler. Se a mensagem chega, a CSP não alcança a
injeção. Se não chega, o desenho muda — e a saída provável é a CSP declarar
um `nonce` para o nosso script, o que precisa ser decidido com o dado na mão.

Registrar o resultado com versão do sistema, como a 2a fez com storage.

### RESULTADO (2026-08-17): a CSP **não** alcança a injeção

Medido em macOS 26.4 / WebKit 21624.1.16.11.4, com a CSP real da 2a servida
como cabeçalho pelo handler de esquema. A ponte fica **sem nonce**.

O que sustenta a conclusão não é o caso positivo, é o **controle**: o script
**inline da página não executou**, provando que a CSP estava ativa e valendo
no momento do teste. Sem esse controle, "a injeção funcionou" seria
indistinguível de "a CSP não estava ligada" — que é exatamente o erro que a
literatura cometeu sobre a flag de confinamento.

Dois dados que o Contrato 2 passa a usar como fato, não suposição:

- **A tripla exata da origem** num esquema próprio chega como
  `("soyehtapp-<id>", "local", 0)` — protocolo, host `local`, porta zero.
  A comparação do passo 3 é contra estes três valores.
- **`message.world.name` é observável no handler**, então o passo 1 é uma
  comparação de verdade e não um ato de fé.

Nota de API medida no caminho: no macOS a forma disponível é a de **bloco**
(`userContentController(_:didReceive:replyHandler:)` registrada via
`addScriptMessageHandler(_:contentWorld:name:)`). A variante async não existe
no SDK. Sem impacto no desenho, apenas na assinatura.

## Contrato 1 — o envelope

Tipos puros, sem AppKit, no pacote de domínio para serem testáveis.

```swift
/// Comando é enum FECHADO. Nada de string despachada por tabela.
enum CapabilityCommand: String, Codable, CaseIterable {
    case metricsRead = "metrics.read"
}

struct CapabilityRequest: Codable, Hashable {
    let v: Int                 // 1
    let id: String             // correlação, opaco
    let command: CapabilityCommand
}

struct CapabilityFailure: Codable, Hashable {
    let code: CapabilityFailureCode   // ver desvio aprovado abaixo
    let message: String               // seguro para exibir; NUNCA caminho ou host
}
```

**Desvio aprovado (2026-08-17): `code` é enum, não `String`.** O esboço dizia
`String`. Medido no commit: o wire sai **idêntico** —
`{"code":"not_granted","message":"…"}` — mas nenhum produtor consegue cunhar
um código fora do vocabulário. Mesma forma do `PathScope` e do produtor único
de path: impossível por construção em vez de proibido por convenção. Não
reverter para `String` achando que segue o esboço.

- **Decodificação estrita explícita**: `Codable` sintetizado ignora chave
  extra. Rejeitar exige container aberto comparado ao conjunto conhecido do
  próprio tipo — a receita que a 2a já aplicou no manifesto, e que só
  funciona com container aberto (medido).
- **Limite de tamanho do corpo antes do parser**, não depois.
- Mensagem de erro **não vaza** caminho, host, nome de usuário nem existência
  de arquivo. Um app malicioso não deve conseguir usar erros como oráculo.

## Contrato 2 — a ponte, e o que a torna segura

`WKScriptMessageHandlerWithReply` registrado **num `WKContentWorld` nomeado**,
nunca no mundo da página. O JS recebe uma Promise: sem nome de callback, sem
interpolação de string em JS — a classe de falha que produziu o vazamento de
token OAuth no Home Assistant deixa de existir por construção.

**Ordem obrigatória de validação, antes de qualquer despacho:**
1. o mundo da mensagem é o mundo da ponte;
2. `frameInfo.isMainFrame`;
3. `frameInfo.securityOrigin` igual por **tripla exata** à origem com que a
   pane foi criada — nunca prefixo, que casaria `exemplo.com.atacante.com`;
4. a origem tem host não-vazio;
5. só então busca-se a permissão **pela origem observada nativamente**.

Nunca ler identificador de app, nome de capacidade ou token **do corpo da
mensagem** para decidir autoridade. Isso é o *confused deputy* por construção.

Dois fatos que tornam os passos acima obrigatórios, não zelo:
- handlers de mensagem são instalados em **todos os frames, sempre** — não
  existe restrição a frame principal para eles, só para user scripts;
- `about:blank` e `srcdoc` **herdam a origem do pai**, então passam na tripla
  exata; quem os barra é o teste de frame principal.

O relay é injetado com `forMainFrameOnly: true`. Assim um subframe não tem
código algum no mundo onde o handler vive, e a checagem de frame vira segunda
camada em vez de única.

**A pane web da Fase 1 não muda.** Ela continua sendo uma configuração que
**nunca chama `add(...)`** — a ausência do handler é o controle, não uma
condição que possa estar errada.

## Contrato 3 — `metrics.read`, deliberadamente pobre

Apenas **agregado de sistema**: carga de CPU, memória usada e livre, uptime.
Schema fechado.

**Fora, por decisão**: lista de processos, nomes de processo, hostname,
caminhos, interfaces de rede, número de série. Lista de processos não toca
disco, mas revela quais programas a pessoa usa — é divulgação de informação,
não medição de máquina.

Não existe coletor no repositório: é código novo. Limite de taxa por pane, e
o resultado não deve permitir inferir atividade de outros apps com precisão
de relógio.

## Contrato 4 — declaração, concessão e auditoria

- O manifesto declara `capabilities: ["metrics.read"]`. A 2a recusa manifesto
  com capacidade declarada; a 2b passa a **aceitar apenas as conhecidas**, e
  segue recusando desconhecidas — vocabulário fechado, como o comando.
- Nesta fase **não há prompt de consentimento**: métricas agregadas de sistema
  são de baixo risco, e um prompt aqui treinaria o usuário a clicar em "sim"
  antes de existir uma pergunta que mereça atenção. O consentimento nativo
  nasce com a capacidade de disco, onde ele importa.
- **Auditoria desde o primeiro dia**, e **negações também são registradas** —
  um log que só registra sucesso não detecta ataque. Cada entrada tem pane,
  origem, capacidade e resultado. Sem conteúdo, só metadados.

## Fatiamento

| Fatia | Dono | Conteúdo |
|---|---|---|
| A — envelope + coletor de métricas | **kairos** | tipos puros no domínio, decodificação estrita, coletor de sistema, testes |
| B — a ponte | **sia** | **spike primeiro**; mundo isolado, relay, `WithReply`, validação de principal, limite de taxa |
| C — declaração + auditoria | **cassia** | manifesto aceitando capacidade conhecida, política, log de auditoria com negações |
| integração + E2E | **celia** | build assinado, E2E no Dev.app, PR |

Regras herdadas, todas testadas na prática: commits pequenos; **só a sia roda
`xcodebuild`**; symlink dos arquivos novos no pacote de domínio **antes** do
primeiro commit, para todos terem compilador; deixar a árvore compilando a
cada commit; **caso novo em enum público é mudança de contrato** — avisar
quem consome no mesmo commit; e **commitado não é enviado**: confirmar o hash
no remoto antes de reportar.

## Aceite

O E2E usa um app-probe que **tenta o que não pode**, como na 2a.

1. Build e suítes executadas (inteiras, nunca filtradas).
2. App **sem** a capacidade declarada chama a ponte → **negado**, e a negação
   aparece na auditoria.
3. App **com** a capacidade → recebe métricas dentro do schema fechado.
4. **Um iframe dentro do app tenta chamar a ponte → negado.** É o teste mais
   importante da fase, e o que a origem herdada de `about:blank` exige.
5. A **pane web** da Fase 1 não tem ponte alguma: `window.webkit` não expõe o
   handler.
6. Corpo malformado, chave desconhecida, comando desconhecido e corpo acima
   do limite → recusados, cada um com seu erro.
7. Limite de taxa dispara e é registrado.
8. As defesas da 2a continuam válidas — nenhuma regressão de CSP ou origem.

## O que esta fase NÃO entrega

Acesso a arquivos, consentimento nativo, revogação de concessão, e qualquer
capacidade que permita ao app enviar dados para fora. A combinação de disco e
rede é o que torna exfiltração possível, e nenhuma das duas existe aqui.

— celia
