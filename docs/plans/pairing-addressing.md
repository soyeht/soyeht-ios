# Endereçamento e pareamento: desenho para revisão

Data: 2026-09-05. Autor: [jaime]. Revisão solicitada a [blaire] antes do código.

Crivo recebido: A aprovado para household; B aprovado com **preservação
obrigatória do pareamento por Wi-Fi puro**, já medido no aparelho; C aprovado
com release coordenado do iOS. Não usar as restrições atuais como justificativa
para retirar LAN de uma cerimônia suportada. Alterações necessárias de política
devem validar a intenção e a identidade, com regressões positivas e negativas.

Base lida: iSoyehtTerm `299555945fe426c4911dc9c742444dde0894bb90`; theyos
`eb96d375`. Este documento propõe a implementação; não registra testes E2E
executados nem atribui uma causa definitiva à ausência de tráfego relatada.

## Resultado e divisão do trabalho

Uma política em SoyehtCore escolhe o endereço que o iPhone tenta e conserva.
Ela recebe fatos do engine e do telefone, considera a operação pretendida e
produz uma decisão explicável ou uma indisponibilidade tipada. Descoberta,
QR, convite direto e confirmação de pareamento consomem essa mesma política.

[jaime] altera código e executa testes locais isolados nos dois repositórios.
[blaire] possui a faixa do iPhone Devs e do engine Dev e executa E2E. Não há
instalação, restart de engine, operação no aparelho, PR ou push nesta faixa.
Commits locais incluem somente os arquivos desta tarefa.

## Correções de premissa que afetam o escopo

1. `handlers_mobile.rs:252-304` já oferece LAN. `best_qr_host()` atende a API
   administrativa, incluindo `/api/v1/invites`; usa a porta administrativa.
   O QR de household usa **outro** seletor: `PairDeviceUriTail::resolve`, em
   `handlers_bootstrap.rs:1300`, que oferece somente tailnet. O ACK de claim
   ainda tem `tailnet_address::build_mac_engine_url`. Centralizar somente os
   quatro símbolos citados deixaria decisões ativas fora da refatoração.
2. `HouseholdPairingService.pair(reachedEndpoint:)` prefere incondicionalmente
   o endpoint já alcançado ao do QR. `HouseholdDevicePairingService` usa o
   endpoint do próprio link. Os dois precisam consumir a mesma decisão até
   a persistência; um teste de `ClaimEngineAddressChoice` sozinho não trava
   a preferência por tailnet no fluxo completo.
3. O payload `SetupInvitationPayload` atual **não declara bootstrap port nem
   perfil**, inclusive no envelope JSON. O iPhone filtra a URL recebida por
   porta; isso ocorre depois de o Mac já ter feito claim. D exige acrescentar
   o dado ao contrato, não somente comparar uma propriedade existente.
4. E já está implementado no gerador `EmbeddedEngineLaunchAgentSpec` e possui
   teste em `EngineSessionDomainTests`. Restam comentário e teste negativo.
   Preservar a garantia; plists instalados ficam com a faixa de [blaire].
5. A janela LAN confirma a concessão, não a conclusão do bind: o listener
   reage de forma assíncrona. `BoundSet` acompanha binds bem sucedidos, mas
   a tarefa de serve não remove hoje a entrada quando termina com erro.
6. Bind e autorização da operação são diferentes. `post_initialize` exige
   origem tailnet quando existe convite persistido. A política pode retirar
   LAN ao fechar a janela; terminal attach por LAN é negado explicitamente.
   Escolher LAN não transforma esses caminhos em operações suportadas.

**Ajuste de escopo proposto:** esta entrega unifica o endereçamento do
pareamento de household. Não migra os convites administrativos de instância
como se fossem o mesmo serviço. Essa separação terá teste de dependência e
teste de porta/serviço. Se A pretende também migrar todos os links da API
administrativa, precisamos acrescentar seus clientes web/CLI e contratos;
não vou declarar esse trabalho resolvido pela mudança do pareamento.

## Um decisor; produtores de fatos separados

O tipo puro `PairingAddressPolicy`, em SoyehtCore, tem três operações:

```swift
offer(engine: EnginePairingAddressSnapshot) -> PairingAddressOffer
choose(offer: PairingAddressOffer, phone: PhoneNetworkEvidence,
       operation: PairingOperation) -> PairingAddressResolution
confirm(decision: PairingAddressDecision,
        observation: PairingEndpointObservation) -> PairingAddressResolution
```

Os nomes são propostos; o contrato e os invariantes abaixo são os requisitos.
Coleta de interfaces, HTTP e relógio ficam fora do tipo e são injetáveis.

| Dado | Conteúdo e autoridade |
| --- | --- |
| Identidade | perfil, porta bootstrap esperada, identidade do engine/casa quando disponível; não confundir com porta administrativa ou da publicação no iPhone |
| Snapshot do engine | geração do processo/inventário, endpoints concretos que estão servindo, classe de transporte, operações admitidas pela política vigente e eventual prazo de exposição |
| Oferta | candidatos sem segredos, versão e procedência do snapshot; ausência de telefone significa alcance desconhecido |
| Evidência do telefone | interfaces/capacidades observadas e resultados recentes por candidato; ter IP tailnet não prova que aquele Mac está alcançável |
| Decisão | candidato escolhido, finalidade, motivo e identidade/geração a que a escolha pertence |
| Observação | endpoint efetivamente tentado, operação, resultado de transporte/protocolo e identidade comprovada quando o protocolo permite |

O engine continua dono de `HouseholdExposurePolicy`, binds e guards das rotas.
Ele publica fatos de disponibilidade; não escolhe por preferência do Mac nem
recebe ordens do telefone para abrir uma interface. `bonjour_trust` não vira
um ranqueador e suas regras de confiança não são ampliadas nesta mudança.

O snapshot só inclui binds concluídos. Remoção/erro da tarefa atualiza o
registro com identidade da inscrição, para uma tarefa antiga não apagar um
bind novo no mesmo endereço. A geração muda quando o conjunto relevante ou
a política muda. Snapshot é evidência datada, não promessa de conectividade:
a tentativa ainda pode falhar e essa falha precisa chegar tipada ao usuário.

Proposta de transporte: `GET /bootstrap/pairing-addresses`, envelope CBOR
`v: 1`, somente leitura. O Mac consulta pelo loopback; acesso pelo telefone
segue a autorização de descoberta correspondente, sem expor dados de outras
casas. A implementação define e testa o conjunto mínimo de campos antes de
publicar a rota. Endpoint público por proxy exige evidência própria de
encaminhamento; não basta inventar `https://host` a partir de um socket local.

### Regras que nenhuma camada pode contornar

- Perfil incompatível é rejeitado antes de claim, geração de segredo local,
  notificação ou alteração do estado do iPhone. Loopback nunca é destino
  oferecido a outro aparelho. Porta de outro serviço não é bootstrap.
- O iPhone com capacidade tailnet prefere o candidato tailnet admitido para
  a operação. A tentativa precisa confirmar alcance. LAN descoberta antes
  não pode sobrescrever silenciosamente a preferência ou o endpoint salvo.
- Se tailnet falhar, produzir falha concreta. Esta entrega não faz downgrade
  automático e permanente para LAN em um telefone com tailnet.
- Sem tailnet no telefone, LAN só é elegível quando bind e operação estão
  admitidos. Uma interface do Mac ou a abertura da janela não bastam.
  O pareamento por Wi-Fi puro é requisito aprovado do produto. Se uma etapa
  desse fluxo estiver bloqueada pela política atual, corrigir a autorização
  dessa etapa explicitamente, preservando prova/convite e perfil, em vez de
  devolver indisponibilidade para um caminho que já funcionava.
- LAN temporária não vira promessa de endereço permanente. A decisão registra
  sua validade; a UI não declara conexão de uso contínuo quando apenas uma
  etapa de pareamento é possível. Nenhuma ampliação de ACL está implícita.
- Sem telefone conhecido, produzir oferta de candidatos; não afirmar que
  determinado endereço é alcançável. No QR, a seleção definitiva ocorre no
  telefone após leitura, pela mesma política usada no convite direto.
- `noReachableAddress` não retorna uma URL de sucesso destinada a falhar.
  Use enum com decisão ou motivo de indisponibilidade.
- Provas criptográficas, nonce e identidade da casa permanecem vinculados à
  cerimônia. Endereços são rotas candidatas, não provas de identidade.

### Migração dos consumidores

`MacEngineAdvertisedURL` perde a prioridade própria e vira adaptador de
coleta/oferta. Preferences, `MacPairingAdvertisement` e
`SetupInvitationListener` compartilham a oferta; não reconstruem URLs.
`ClaimEngineAddressChoice` é substituído ou fica como adaptador temporário
para a política, sem uma segunda regra de seleção.

`AwaitingMacView`, `AwaitingNewMacView`, descoberta Bonjour, entrada por QR e
ambos os serviços de pairing levam a decisão até o transporte e a gravação
do endpoint. `reachedEndpoint` vira evidência de uma tentativa, não bypass.
O host de presença/attach do pareamento local continua com suas portas e
capacidades próprias; não é atualizado por substituição textual de URL.

O engine emite material de pareamento e candidatos; o Swift constrói a oferta
e escolhe. `PairDeviceUriTail` e o ACK de claim deixam de fazer seleção
independente. Se uma rota ainda renderizar o link com endereço, recebe a
decisão identificada e valida sua correspondência ao snapshot/serviço,
sem chamar um detector para escolher novamente. Cliente Linux não precisa
executar Swift no servidor: a escolha do destinatário continua no iPhone.

Um guard de dependência e testes de handler devem demonstrar que alterar a
preferência de `best_qr_host` não altera a oferta/decisão de household. Esse
helper permanece restrito às rotas administrativas legadas explicitadas.

Compatibilidade é parte do contrato: há decoders que rejeitam campos novos.
O novo envelope/forma de link terá versão suportada explicitamente nos
produtores e leitores; não adicionar campos cegamente a respostas v1. Um
link legado é convertido em oferta com evidência limitada e conserva a
validação de perfil. Nenhum fallback legado recebe garantia de bind que não
observou; versão incompatível produz pedido claro de atualização.

## Claim: distinguir inicialização de convite para casa existente

Eliminar `shouldProceedAfterClaimFailure`, inclusive a lista de códigos
legados que transforma erro em sucesso. Separar a orquestração de descoberta
da cerimônia, com dependências injetáveis para testes:

1. Descobrir e validar convite, perfil, validade e estado atual do engine.
2. **Engine novo:** claim confirmado pelo engine é pré-condição para enviar
   `bootstrapClaimAccepted`. Resposta tipada substitui o timestamp `0` usado
   como sucesso implícito pelo client. `invitation_not_recognized` pode ter
   retry limitado; esgotado o prazo, erro terminal da tentativa, sem notify.
3. **Casa nomeada/ready:** usar a oferta atual de pareamento, validada contra
   a identidade e estado do engine, e enviar `existingHouseOffered`. Não
   chamar claim de inicialização, cuja pré-condição não vale nesse estado.
4. `already_initialized` concorrente provoca nova leitura de estado e nova
   avaliação explícita. Só transita para oferta existente quando essa oferta
   foi obtida; o código de erro sozinho nunca autoriza sucesso.
5. Timeout após mutação é resultado incerto. Recuperar ACK da mesma intenção
   se o contrato provar que ela foi aceita; sem essa prova, falhar com motivo
   recuperável. Não fabricar confirmação nem consumir outro convite.
6. Notificação falha após claim aceito pode repetir a mesma notificação
   vinculada ao token/perfil. Não refazer claim a cada tentativa de notify.
   Reentrada do fluxo deve observar o claim persistido ou reiniciar de forma
   explícita; teste cobre resposta perdida e reinício da orquestração.

O iPhone recebe um evento discriminado, não deduz o significado de sucesso
pelo erro que o Mac ignorou. Cancelamento, expiração e nova tentativa invalidam
callbacks da tentativa anterior antes de qualquer gravação de segredo ou
latch de descoberta. Os guards existentes de identidade e "Not my Mac"
continuam obrigatórios.

## Perfil e erros observáveis

Adicionar perfil/porta bootstrap esperada a `SetupInvitationPayload`, JSON
direto, TXT/CBOR e verificação do convite. Validar na descoberta do Mac, no
claim do engine e no recebimento pelo iPhone, antes dos efeitos. A porta do
servidor de convite do iPhone é outro dado. O perfil é isolamento de produto,
não substitui autenticação do remetente ou prova de identidade da casa.

Proposta para payload legado sem perfil: não fazer claim automático. Oferecer
atualização/fluxo explícito compatível; não assumir produção silenciosamente.
O iOS de loja `com.soyeht.app 1.1.19 (20)` não envia perfil, segundo a revisão
de [blaire]. **Não publicar o enforcement no Mac/engine sem disponibilizar
o iOS correspondente e documentar a atualização necessária.** A validação Dev
usa o conjunto coordenado; release é outra etapa, fora desta faixa.
O backend valida o dado recebido contra sua configuração e o convite
verificado, não confia só na comparação feita pela GUI. Retentativas mantêm
a mesma identidade de convite e rejeitam perfil divergente também no callback.

Introduzir `PairingAttemptFailure` com etapa, endpoint sanitizado, causa e
recuperação. Causas incluem perfil, versão/decodificação, operação não
admitida, bind indisponível, DNS, conexão recusada, timeout, transporte,
rejeição do servidor, convite expirado, prova inválida, aprovação e storage.
Cancelamento permanece cancelamento. Erro desconhecido conserva domínio e
código; a UI dá uma ação útil sem inventar a causa.

A causa nasce no transporte/decodificação: não pode ser recuperada depois
que um serviço a reduz a `.networkUnavailable`. Remover esse achatamento
nos caminhos tocados, além do catch de `AwaitingMacView`. A mensagem sobre
Tailscale não será inferida apenas do host do QR: hoje ele pode diferir do
endpoint que `reachedEndpoint` fez o serviço tentar.

Logs correlacionam tentativa, perfil, operação, candidato selecionado,
endpoint efetivamente tentado, duração, status HTTP/código de erro e fase.
Nunca registram URI de pareamento completa, query com token, nonce, APNs ou
segredo local. A tela recebe mensagem curta e ação adequada; o diagnóstico
detalhado fica no log. Todo caminho termina em sucesso, falha, cancelamento
ou espera explícita com prazo/ação; erro não deixa spinner indefinido.

## Testes que atravessam o contrato

O teste atual de `local-network-visibility` é evidência útil, mas faz busca
textual e dá skip se o outro checkout não existe. O gate desta entrega
**exige os dois checkouts em revisões explícitas**. Ausência é erro do gate,
nunca verde por skip. Não depende de engine instalado ou do aparelho.

Manter um catálogo das rotas tocadas com método, caminho, content-type,
versão, perfil, campos/erros e permissões. O teste produz request pelo Swift
real, passa pelos routers/decoders Rust em processo de teste e devolve a
resposta serializada pelo Rust ao decoder Swift. Para callback, inverter o
produtor/consumidor. Reutilizar o transporte injetável e `Router::oneshot`;
não ligar o binário operacional. Fixtures persistidas são saídas verificadas
desses produtores, não exemplos inventados em cada repositório.

Cobertura mínima por rota do fluxo alterado:

| Fronteira | Rotas/materiais |
| --- | --- |
| Mac ↔ iPhone | GET `/setup-invitation`, verificação `/setup/verify`, POST `/setup-invitation/claimed`; perfil em TXT/CBOR/JSON |
| Mac ↔ engine | POST `/bootstrap/claim-setup-invitation`, GET `/bootstrap/status`, GET `/bootstrap/pairing-addresses`, POST `/bootstrap/local-network-visibility/open` e `/close` |
| Oferta/QR | GET `/bootstrap/pair-device-uri`; by-code/reissue e resposta de initialize se transportarem a nova oferta; parser Swift lendo URI/material emitido pelo Rust |
| iPhone ↔ engine | POST `/bootstrap/initialize`, POST `/api/v1/household/pair-device/confirm`, request/poll de device pairing nos caminhos usados pelos dois serviços |

As rotas adicionais só entram se forem alteradas ou consumidas pelo fluxo;
registrar a lista concreta no primeiro commit de contrato para não omitir
uma rota por ter um decoder em outro arquivo. Testes de ausência de chamada
comprovam que falha de claim/perfil não produz notify nem segredo.

Controles negativos obrigatórios: renomear a rota ou `expires_at_unix` num
fixture de teste isolado reprova o gate; ignorar perfil no produtor ou
consumidor reprova; selecionar endereço de outra porta/serviço reprova;
trocar a seleção final por `reachedEndpoint` reprova a preferência tailnet.
Sem editar os checkouts de trabalho para simular esses defeitos.

## Fatias e aceite

1. Catálogo de contrato + política pura: matriz de seleção, identidade/perfil,
   operação, ausência de bind, expiração e tailnet. Guardar o nome e ampliar
   `test_keepsTheTailnetAddressWhenThePhoneIsOnTheTailnet` até persistência.
2. Fatos reais de listener + contrato de oferta/claim/perfil no Rust e Swift;
   testar abertura assíncrona, bind falho, tarefa encerrada e geração antiga.
3. Migrar consumidores, QR e ambos os serviços; remover os seletores e o
   proceed-after-error. Erros tipados atravessam até as duas telas iOS.
4. Gate cruzado por rota, regressões de fingerprint/nonce/"Not my Mac",
   deadline/cancelamento e ausência da variável morta. Compilação local com
   diretórios de build próprios, sem o harness que baixa/inicia engine.
5. Handoff para [blaire] com os commits locais, comandos e matriz E2E:
   tailnet nos dois lados (incluindo endpoint salvo), telefone sem tailnet,
   engine sem tailnet, LAN fechada/expirada, bind falho, perfil cruzado nas
   duas direções, claim recusado, notify perdido, QR e descoberta, primeira
   pessoa e ingresso em casa existente. Cada resultado inclui tentativa,
   endpoint, resposta/erro e estado final; ausência de pacote não é causa.

"Ótima qualidade" significa que esses invariantes são observáveis e testados,
os consumidores não redecidem, e a pessoa recebe um desfecho útil. Não é uma
nota declarada pelo autor nem uma suíte verde que ignora a fronteira.

## G — primeiro iPhone e aprovação pelo Mac

O bloqueio de produto relatado é válido: uma folha não pode exigir outro
iPhone quando não há aprovador disponível. Entretanto, `device_count == 1`
não prova que só existe o Mac. `hh_info` (`handlers_bootstrap.rs:3369`)
transforma a presença de `current_owner_auth()` em 0/1; não enumera devices.
"No paired iPhone currently connected" também descreve presença, não a
ausência de autoridade estabelecida. Não usar nenhum desses dois dados como
permissão para substituir o dono de uma casa.

Há três estados, determinados por autoridade e capacidade comprovadas:

| Estado | Cerimônia e aprovador |
| --- | --- |
| Sem dono estabelecido | Primeiro dono pelo protocolo existente de nonce/prova, preservando a casa e seu conteúdo; não exige outro iPhone |
| Dono estabelecido e chave pessoal correspondente disponível neste Mac | O usuário aprova no Mac; usar a rota autenticada de device pairing existente |
| Dono estabelecido e Mac sem capacidade de assinar por ele | Recuperação de autoridade explícita; informar a ausência do aprovador, sem spinner e sem apagar a casa como resposta padrão |

O Mac já pode ser o primeiro dono (`AppDelegate.autoHouseholdPairDevice`).
`HouseholdDevicePairingService.approve` já assina o DeviceCert e o PoP com
`OwnerIdentitySigning`; o protocolo não exige que esse signer esteja em um
iPhone. Proposta de G: UI de pedidos no Mac, leitura autenticada dos pedidos,
revisão do aparelho/identidade, confirmação local e chamada desse serviço.
Não aprovar em background apenas porque o pedido chegou ou a LAN está aberta.

A capacidade local exige sessão da mesma casa, certificado do dono vigente
e prova de posse da chave pública correspondente. O engine verifica PoP e
vínculo do certificado aprovado à chave do pedido. A disponibilidade de uma
referência no Keychain não é prova de que a assinatura funcionará; erro de
acesso/cancelamento permanece visível e não altera a autoridade.

`hh_priv`, `m_priv` e chave pessoal do dono são autoridades distintas. O engine
pode ter a chave da casa e somente o **certificado público** do dono; isso não
significa que o Mac GUI possa assinar como aquele dono. Não reabrir a cerimônia
de primeiro dono porque o telefone foi perdido/desconectado. [blaire] verifica
em sua faixa qual capacidade existe no Mac do Caio, sem compartilhar segredos.

O desenho do terceiro estado deve considerar o mecanismo de recuperação
existente e a disponibilidade real de chaves antes de escolher uma operação.
Essa dependência não bloqueia A–F nem a aprovação pelo Mac quando ele já é o
dono; impede apenas um bypass de autoridade baseado no contador incorreto.
G permanece parte do aceite: o caso medido precisa terminar em pareamento
ou num caminho de recuperação concreto, sem destruição da casa.

Remover da folha normal o conselho de `Forget this home` e as afirmações de
que somente iPhones podem aprovar. Manter a ação destrutiva de esquecer a
casa como escolha explícita separada, sem executá-la nesta tarefa. Status de
pareamento usa request/resultado da cerimônia, não incremento de um contador
que é booleano e nunca chegará a 2.

Testes G: Mac dono aprova primeiro iPhone preservando hh_id/dados; sem dono
usa a cerimônia inicial; Mac somente máquina não consegue aprovar como dono;
assinatura/certificado de outra casa ou chave diferente do pedido é rejeitado;
cancelamento e expiração encerram a espera; contador 1 não concede autoridade;
dois pedidos não recebem aprovação por engano. Rota de listagem e aprovação
entra no gate cruzado. E2E da casa medida é responsabilidade de [blaire].


## Checkpoint de implementação — 2026-09-05

A oferta de listeners, perfil e recibo de claim está integrada aos consumidores
Swift. O QR transporta a oferta inteira; os dois serviços aplicam a política
antes de gravar a sessão. A oferta de casa existente usa evento próprio e não
passa por um claim recusado. O engine verifica perfil e token pelo callback do
iPhone, e a inicialização remota verifica token, expiração e origem novamente
sob a trava de mutação. O campo `claim_token` era enviado pelo Swift e ignorado
pelo decoder Rust; a promessa antiga de idempotência não correspondia ao
handler e foi removida. Repetir o claim conserva seu recibo; inicialização com
resultado incerto exige reconsultar o estado.

Validação local deste checkpoint: builds de Mac e iOS; 163 testes Swift do
núcleo, 44 do domínio Mac; 27 testes de contrato de claim Rust, 47 de listeners
e 77 de bootstrap. Um teste preexistente de distribuição de tempo continua
ignorado por ser caracterização especulativa, não gate de contrato. Estes
resultados não constituem o gate cruzado nem a validação E2E no aparelho.

Continuam obrigatórios: G (capacidade e aprovação pelo dono no Mac, recuperação
sem apagar a casa), gate executável por rota entre os dois checkouts e matriz
E2E conduzida por [blaire]. Nenhuma versão foi atualizada ou publicada.

### Checkpoint G — capacidade e aprovação no Mac

A capacidade local agora consulta a sessão sem interação, compara casa/pessoa/chave
com a autoridade atual do engine, abre a chave sem interação e verifica uma assinatura
P-256 de desafio aleatório com separação de domínio. Referência de keychain não é prova.
A leitura preserva os erros de Security/LocalAuthentication: item ausente, necessidade
de autenticação e erro operacional são estados distintos. A API usada para impedir
prompts é `LAContext.interactionNotAllowed`, conforme a documentação da Apple:
https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed

Add iPhone usa uma implementação. Removeu-se o controlador AppKit duplicado e os
usos de `deviceCount` como autorização ou sucesso. O Mac com a chave do dono lista
pedidos com PoP e aprova o pedido explicitamente escolhido. A observação automática
nunca pode solicitar autenticação; desbloqueio e aprovação exigem gesto na tela.
Depois de aprovar, a mensagem diz que a aprovação foi enviada e pede concluir no
telefone. Não inventa uma conexão ativa.

O pedido tem seis palavras próprias, distintas do código da oferta da casa. Elas
vinculam `request_id` e `d_pub` ao contexto da casa, por derivação única em
`DevicePairingReview`. Mac, proximidade no telefone, QR/link e aprovação por outro
iPhone usam a mesma derivação. Os emissores registram `pairing_review_digest`, SHA256
das palavras separadas por NUL, sem identificadores ou palavras no log. A comparação
é uma ação explícita antes da aprovação. Pedidos e esperas têm prazo.

Casa sem dono usa a cerimônia de primeiro dono já existente. Casa com dono e chave
comprovada no Mac usa aprovação neste Mac. Se a chave estiver em outro dispositivo,
o caminho preservado é aprovar naquele dispositivo; a tela identifica essa
necessidade. Ausência de chave não autoriza reabrir a cerimônia de primeiro dono.
Se nenhuma chave de dono estiver disponível, esta entrega não inventa recuperação
criptográfica: a casa permanece intacta e a limitação fica explícita. “Forget home”
foi separado do pareamento e deixou de ser instrução para adicionar um telefone.

O engine valida agora o certificado de pareamento no momento da aprovação e compara
chave/nome/plataforma com o pedido sob o mesmo lock que o finaliza. O formato real
Swift inclui `hh_id` e caveats herdados. Ele não é o certificado R0a de admissão;
nenhum grant ou caminho de admissão R0a foi ligado. O telefone já verificava a cadeia
e sua própria chave: esta correção evita armazenar uma aprovação inválida e faz a
recusa ocorrer onde o defeito nasceu, sem alegar que antes era possível admitir um
aparelho com certificado forjado.

Verificação deste checkpoint: 24 testes Core selecionados; 43 testes Mac de domínio;
16 testes de store/rotas de pedido, 10 testes Rust de endereços/certificado/política e
1 guarda de fronteira da aprovação. Builds Mac e iOS sem assinatura passaram.
O gate executável cruzado e a matriz no aparelho continuam pendentes. Este checkpoint
não autoriza release nem instala qualquer build.
