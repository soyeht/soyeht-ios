# Feature Specification: Onboarding Canônico Soyeht (iOS + macOS)

**Feature Branch**: `017-onboarding-canonical`
**Created**: 2026-05-09
**Status**: Draft
**Input**: Single bet covering both onboarding entry paths — Caso A (Mac primeiro) and Caso B (iPhone primeiro com AirDrop). Thesis "O motor é invisível" aprovada como base canônica em 2026-05-09 via 3-way design competition (proposta backend venceu).

## Clarifications

### Session 2026-05-09

- Q: Quais idiomas Soyeht v1 (iOS + macOS) suporta no shipping? → A: Todos os 15 idiomas atualmente suportados nos string catalogs do projeto: árabe (ar), bengali (bn), alemão (de), inglês (en), espanhol (es), francês (fr), hindi (hi), indonésio (id), japonês (ja), marata (mr), português brasileiro (pt-BR), português europeu (pt-PT), russo (ru), telugu (te), urdu (ur). Suporte global continua — onboarding inteiro deve cobrir todos esses idiomas, incluindo correto suporte a RTL para árabe e urdu.
- Q: Qual o piso de acessibilidade pro onboarding v1? → A: Full Apple-grade. Cobre: VoiceOver labels em todos os elementos interativos e informativos; Dynamic Type completo (XS até AX5/XXL Accessibility); Reduce Motion respeitado (animações de carrossel/transição substituídas por cross-fade simples ou desativadas); Increase Contrast suportado; contraste WCAG AA mínimo em todos os pares de cores texto-fundo; Voice Control labels presentes; touch targets ≥44×44pt; Reduce Transparency com fallback sem materiais Liquid Glass.
- Q: Como o sistema decide que uma rede é "confiável" pra autodescoberta de casas e máquinas? → A: Tailscale-only por enquanto. Discovery default opera apenas quando a interface de rede ativa é identificada como Tailscale (ou WireGuard mesh equivalente reconhecido pelo OS). LAN bruta (RFC1918, .local, link-local sem Tailscale) é fallback opt-in explícito com warning, nunca default. VPNs corporativas/genéricas que não sejam Tailscale não disparam autodescoberta.
- Q: Onde aparece o opt-in de telemetria durante o onboarding? → A: Embarcado na tela de preview do install — no Mac, dentro da cena "O que vai acontecer agora" (preview de instalação) como uma linha discreta com toggle on/off e nota "muda depois em Configurações"; no iPhone, na tela equivalente de preview do "O que vai acontecer agora" antes da escolha de "Tenho um Mac aqui". Não é splash dedicado, não é diferido pro pós-pareamento, não vai pra home view. Default do toggle é OFF (opt-in genuíno, não opt-out disfarçado).
- Q: Quais campos diferenciam 2 casas com mesmo nome na tela de seleção (caso edge multi-casa)? → A: Nome da casa + emoji/cor único auto-gerado deterministicamente da identidade criptográfica da casa. Cada casa ganha um par {emoji, cor de fundo} que é computado a partir do `hh_pub` e nunca muda — funciona como avatar visual da casa. Apresentação na lista: avatar (emoji+cor, ~32×32pt) + nome da casa em destaque + máquina hospedeira em texto secundário. Usuário pode reconhecer "minha casa" instantaneamente sem ler texto.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Casa nasce no Mac com primeiro morador (Priority: P1)

Uma pessoa que ainda não usa Soyeht baixa o instalador Mac, abre o app, dá um nome à sua casa, e adiciona seu iPhone como primeiro morador pessoal. No final, a casa está viva no Mac e o iPhone aparece como morador confirmado. Esta é a entrada mais direta no produto e cobre o MVP completo: a casa existe, tem um morador móvel, e está pronta pra receber agentes/claws.

**Why this priority**: É o caminho funcional mais curto até "casa pronta". Sem ele, o produto não tem como começar — não importa quantas portas alternativas existam. Tudo o mais (Caso B, recovery, multi-device) constrói em cima desta base.

**Independent Test**: Pode ser testado ponta-a-ponta com um Mac sem Soyeht prévio + um iPhone sem Soyeht prévio. Sucesso = casa nomeada, primeiro morador iPhone confirmado, ambos os devices mostrando estado consistente, em ≤45 segundos do drag-to-Applications até "primeiro morador".

**Acceptance Scenarios**:

1. **Given** o Mac do operador não tem Soyeht instalado, **When** o operador arrasta o instalador pra Aplicações e abre, **Then** o app apresenta uma boas-vindas curta e um botão "Continuar" sem pedir nenhuma senha de administrador.

2. **Given** o operador clicou "Continuar" e viu uma tela explicando o que vai acontecer, **When** clica "Instalar", **Then** o Soyeht fica vivo no Mac em ≤8 segundos sem nenhum prompt de senha admin, e o app avança automaticamente pra etapa de batismo da casa.

3. **Given** o Soyeht está vivo no Mac, **When** o operador digita o nome "Casa Caio" e confirma, **Then** o app cria a identidade da casa localmente (visivelmente, com animação curta) e mostra um cartão da casa com slot vazio rotulado "✨ adicionar iPhone".

4. **Given** o cartão da casa está visível com slot vazio, **When** o operador abre o Soyeht no iPhone (já instalado via App Store) e este iPhone está na mesma rede privada confiável, **Then** o iPhone descobre a casa nova automaticamente e mostra notificação "Casa Caio te chamou. Entrar?" com biometria inline.

5. **Given** o iPhone confirmou via biometria, **When** o pareamento conclui, **Then** ambos Mac e iPhone mostram o iPhone listado como primeiro morador com o nome "iPhone <nome do dono>" e timestamp "agora há pouco". O Mac mostra "Casa Caio agora tem 2 moradores."

6. **Given** o pareamento concluiu, **When** o iPhone exibe sua tela de sucesso, **Then** o app mostra uma mensagem tranquilizadora sobre recuperação ("Se perder este iPhone, qualquer Mac da sua casa pode te trazer de volta") antes de ir pra home.

---

### User Story 2 — iPhone primeiro traz o Mac via proximidade (Priority: P1)

Uma pessoa que ainda não tem Soyeht em nenhum dispositivo baixa o app no iPhone (App Store), assiste a uma apresentação visual curta do produto, e diz que quer instalar Soyeht no seu Mac. O iPhone usa um mecanismo nativo de proximidade Apple pra entregar o instalador no Mac do usuário. O usuário batiza a casa AINDA NO IPHONE (com o teclado já na mão), o Mac instala em paralelo, e o iPhone vira primeiro morador via push + biometria. Sem QR scan visível ao usuário, sem digitar URL, sem fricção desnecessária.

**Why this priority**: Caso B é a entrada mais provável de marketing-driven discovery (usuário descobre Soyeht numa rede social, baixa direto no iPhone, espera que "simplesmente funcione"). Sem este caminho, perdemos a maior fatia de funil de aquisição. Equivalente em prioridade ao Caso A — é a outra metade do MVP.

**Independent Test**: Pode ser testado com um iPhone sem Soyeht prévio + um Mac sem Soyeht prévio + ambos próximos fisicamente, na mesma rede. Sucesso = casa criada, Mac e iPhone reconhecidos como pareados, em ≤4 minutos incluindo download do instalador (~50-80MB), sem nenhum QR scan ou digitação de URL pelo usuário.

**Acceptance Scenarios**:

1. **Given** o iPhone abriu Soyeht pela primeira vez e completou o carrossel de apresentação, **When** o app pergunta "Onde você quer instalar Soyeht?", **Then** o operador vê três opções: "Meu Mac" (primary, habilitada), "Meu Linux" (desabilitada com badge "em breve"), e "Pegar o link depois" (fallback secundário).

2. **Given** o operador escolheu "Meu Mac", **When** o app pergunta "Você está perto do seu Mac agora?" e o operador responde "Sim", **Then** o iPhone tenta o caminho de proximidade Apple mais elegante disponível (ex: AirDrop) e fornece um fallback graceful (link visível + QR) caso o caminho elegante falhe.

3. **Given** o iPhone iniciou a transferência por proximidade, **When** o Mac aceita a entrega, **Then** o instalador chega no Mac sem digitação manual de URL e o iPhone mostra "Procurando seu Mac..." enquanto o Mac termina o setup local.

4. **Given** o Mac instalou Soyeht localmente, **When** o Mac descobre que tem um iPhone esperando setup pendente, **Then** o Mac pula a pergunta de "qual o nome da casa" (porque essa pergunta vai ser feita NO IPHONE) e aguarda sincronizado.

5. **Given** o Mac está aguardando, **When** o iPhone exibe a tela "Como você quer chamar sua casa?" e o operador digita "Casa Caio" + confirma, **Then** o nome viaja do iPhone pro Mac, a identidade da casa é gerada no Mac, e ambos os dispositivos mostram "Casa Caio criada" sincronizadamente.

6. **Given** a casa foi criada com nome digitado no iPhone, **When** o pareamento iPhone↔Mac conclui automaticamente (mesmo flow de descoberta + biometria de US1), **Then** ambos mostram "Casa Caio agora tem 2 moradores: Mac Studio + iPhone <nome>" e o iPhone exibe a mensagem de recuperação tranquilizadora.

---

### User Story 3 — Carrossel de apresentação na primeira execução iOS (Priority: P2)

Quando o operador abre o Soyeht no iPhone pela primeira vez, antes de qualquer pergunta funcional, ele vê um carrossel de 5 cards apresentando o que Soyeht é e por que importa. Os cards passam por: instalar agentes da Loja Claw, times de agentes que conversam entre si, transformar agente em site público hospedado no próprio computador, voz como interface principal, e Mac+iPhone como dispositivos complementares. O carrossel termina com CTA "Vamos começar". Esta apresentação é mostrada apenas na primeira execução; uma opção em Configurações permite revê-la.

**Why this priority**: Sem contexto, o usuário não entende o que tá comprando. P2 (não P1) porque o fluxo funcional ainda funciona se o carrossel for skipado — mas a taxa de conversão do CTA cai significativamente. Implementação independente do resto do onboarding.

**Independent Test**: Pode ser testado em isolamento — abrir o app sem state local, validar que o carrossel aparece, deslizar pelos 5 cards, confirmar que CTA "Vamos começar" leva pra próxima etapa do onboarding, e que segunda abertura do app pula o carrossel.

**Acceptance Scenarios**:

1. **Given** o iPhone está abrindo Soyeht pela primeira vez, **When** o app inicializa, **Then** apresenta o carrossel de 5 cards na ordem: (1) Loja Claw, (2) Times de agentes, (3) Seu agente vira site, (4) Voz é mais rápido que texto, (5) Mac e iPhone juntos.

2. **Given** o operador está vendo o carrossel, **When** desliza pra frente, **Then** cada card transiciona com animação suave de cross-fade e parallax, e a posição é indicada com pontos no rodapé.

3. **Given** o operador chegou ao último card, **When** toca no botão "Vamos começar", **Then** o app marca o carrossel como visto e avança pra próxima etapa do onboarding (US2).

4. **Given** o operador já viu o carrossel uma vez, **When** abre o app de novo (sem ter feito setup ainda) ou em qualquer abertura subsequente, **Then** o carrossel não é reapresentado automaticamente.

5. **Given** o usuário quer rever a apresentação, **When** vai em Configurações > Sobre > Reapresentar tour, **Then** o carrossel roda de novo do início.

---

### User Story 4 — "Vou fazer mais tarde" parking lot (Priority: P2)

No fluxo iPhone-primeiro, quando o operador escolhe "Meu Mac" mas indica que não está perto do Mac agora, o app oferece um caminho de adiamento gracioso: copiar/compartilhar o link de download, ou opcionalmente pedir um lembrete por email pra mais tarde. O home view do iPhone passa a mostrar um banner persistente "Soyeht ainda não tem casa. [Instalar no Mac]" até o setup ser completado.

**Why this priority**: Um percentual mensurável de usuários vai descobrir Soyeht no iPhone fora de casa (no metrô, na rua, no trabalho). Sem este parking lot, esses usuários perdem o momentum e podem não voltar. P2 porque é alto valor mas não bloqueia MVP.

**Independent Test**: Pode ser testado em isolamento — completar carrossel + escolher "Meu Mac" + responder "Vou fazer mais tarde" + validar que o banner aparece na home, que o link copia/compartilha, e que tocar no banner retoma o flow correto.

**Acceptance Scenarios**:

1. **Given** o operador escolheu "Meu Mac" e o app pergunta proximidade, **When** o operador responde "Vou fazer mais tarde", **Then** o app mostra a tela "Sem pressa" com link textual `soyeht.com/mac` (com botão de share/copy) e opção opt-in pra lembrete por email.

2. **Given** o operador optou ou não por lembrete, **When** confirma o adiamento, **Then** o app vai pra home view com banner permanente "Soyeht ainda não tem casa. [Instalar no Mac]".

3. **Given** o banner está visível na home, **When** o operador toca nele, **Then** o app retoma o fluxo a partir da pergunta de proximidade (sem refazer carrossel).

4. **Given** o operador eventualmente completa o setup do Mac, **When** o pareamento Mac↔iPhone conclui, **Then** o banner desaparece automaticamente.

---

### User Story 5 — Recuperação cedo (Priority: P3)

Após o iPhone ser confirmado como primeiro morador (em qualquer um dos casos A ou B), o app exibe uma tela curta tranquilizando o operador sobre o cenário "perdi o iPhone": qualquer Mac da casa pode trazer de volta. A mensagem é informativa, não pede ação imediata, e pode ser dispensada com "Entendi". O conteúdo é re-acessível em Configurações.

**Why this priority**: Reduz ansiedade de adoção em usuários que pensam "e se eu perder esse celular?". P3 porque não bloqueia o flow principal, mas tem alto retorno de confiança.

**Independent Test**: Pode ser testado em isolamento mockando o estado pós-pareamento — validar que a tela aparece, que o texto está calibrado pra não assustar, que o botão "Entendi" dispensa, e que Configurações tem entry point pra revisar.

**Acceptance Scenarios**:

1. **Given** o iPhone acabou de virar primeiro morador, **When** a tela de sucesso é dispensada, **Then** uma tela "Boa notícia" aparece com texto curto sobre recuperação via outro Mac da casa.

2. **Given** o operador leu a tela, **When** toca "Entendi", **Then** o app vai pra home view normal.

3. **Given** o operador quer rever a informação depois, **When** vai em Configurações > Sobre a Casa > Como recuperar, **Then** vê o mesmo conteúdo.

---

### Edge Cases

- **Sem internet durante install**: O app detecta a falha de download/checksum cedo, surface mensagem clara "Sem conexão. Verifique seu Wi-Fi e tente de novo." com retry button. Não persiste estado parcial.
- **AirDrop indisponível ou recusado**: O app degrada graciosamente pro fallback URL+QR sem mostrar mensagem de erro técnica. O usuário simplesmente vê a tela com "soyeht.com/mac" + QR.
- **Mac e iPhone com Apple IDs diferentes**: AirDrop ainda funciona (Apple permite cross-Apple-ID com confirmação manual). Se falhar, fallback URL é entregue. Não trava.
- **iPhone fora da rede do Mac no momento do pareamento**: O pareamento espera por descoberta com timeout generoso (~60s). Se exceder, mostra "Não encontrei seu iPhone na rede. Verifique se o Soyeht no iPhone está aberto e conectado à mesma rede." com retry.
- **Múltiplas casas detectadas na rede**: Improvável no fluxo de criação (porque é uma casa nova nascendo), mas se acontecer (ex: usuário criou e desinstalou + tá refazendo), app mostra lista desambiguada com nome da casa, computador hospedeiro, e timestamp da última atividade.
- **Senha admin negada**: Não deveria ocorrer (install é per-user, sem sudo), mas se um modo edge-case requerer (ex: limpeza de instalação anterior corrompida), o app mostra mensagem carinhosa "Sem essa permissão Soyeht não fica vivo neste Mac. [Tentar de novo]".
- **Engine não sobe pós-install**: App detecta via health-check timeout, mostra "Soyeht não conseguiu acordar. [Reinstalar] [Falar com suporte]". Estado é wipe-able sem deixar lixo.
- **QR adulterado / Mac falsificado**: Antes do pareamento, o app valida que o Mac "candidato" tem identidade consistente com o que foi anunciado via discovery. Discrepância surface "Não consegui verificar este Mac. Cancele e tente de novo." sem detalhes técnicos visíveis.
- **Discovery pega rede pública por engano**: Default é rede privada confiável (Tailscale-like). LAN bruta é fallback opt-in com warning explícito "Soyeht vai procurar em redes Wi-Fi compartilhadas. Faça isso só em rede de casa."
- **Operador cria 2 casas por engano**: Se o app detecta que o Mac já tem uma casa local viva e o operador iniciou outro flow, mostra "Você já tem uma casa neste Mac. Quer recomeçar do zero?" com warning sobre wipe.
- **Carrossel skipped por gesture rápido**: Permitido, mas o app marca como "visto" mesmo assim (não força re-exposição).
- **iPhone restaurado de backup com Soyeht prévio**: Quando o app detecta que está rodando em um device restaurado (via `NSUbiquitousKeyValueStore` flags), pula o carrossel automaticamente e tenta restaurar o relacionamento com a casa anterior antes de mostrar onboarding "fresh". Se a casa não existe mais (Mac desligado, etc), surface mensagem "Você já usou Soyeht antes. Vamos reconectar com sua casa." em vez de tratar como first-launch.
- **iPhone com bateria <20% no momento do download (Caso B)**: Antes de iniciar transferência AirDrop ou download via URL, surface aviso "Sua bateria está baixa. Recomendamos conectar o cabo antes de continuar — o setup leva ~4 minutos." com botões `Continuar mesmo assim` e `Esperar`.
- **Conexão cellular ao invés de Wi-Fi (Caso B)**: Sistema detecta uso celular quando vai baixar instalador; surface "Soyeht.dmg tem ~50MB. Quer baixar agora ou esperar Wi-Fi?" com opção explícita. Default sugerido: esperar Wi-Fi se app sabe que Wi-Fi está disponível em local conhecido.
- **Focus Mode ativo**: Push notifications de "Casa Caio te chamou" respeitam Focus Mode. Quando filtrado, mostram fallback discreto na home screen do iPhone: badge no app icon + entrada na Notification Summary, sem som/vibração.
- **Dark Mode + Increase Contrast simultâneos**: Avatar HSL backgrounds são re-derivados com lightness ajustada (-15%) pra manter contraste WCAG AA mesmo com sobreposição de bordas grossas; gradientes Liquid Glass viram fundos sólidos.
- **App Store atualização durante setup**: Improvável (App Store não interrompe app aberto), mas se Sparkle (Mac) tentar update durante install: setup tem prioridade, update deferido pra próxima abertura.

## Requirements *(mandatory)*

### Functional Requirements

#### Vocabulário & Comunicação

- **FR-001**: O sistema MUST eliminar 100% das ocorrências dos termos `servidor`, `daemon`, `theyOS`, `household`, `founder`, `candidate`, `fingerprint`, `anchor`, `pair-machine`, `pair-device`, `BIP-39`, `shard`, `Shamir` em qualquer string de UI visível ao usuário (auditável via grep da string catalog).
- **FR-002**: O sistema MUST usar substitutos consistentes: `casa` (no lugar de household), `Soyeht no seu Mac` (no lugar de daemon/server/engine), `morar/ficar vivo neste Mac` (no lugar de "rodar como daemon"), `código de segurança` (no lugar de fingerprint), `primeiro morador` (no lugar de first device), `este Mac entrou na sua casa` (no lugar de pair-machine result).
- **FR-003**: O sistema MUST referir-se ao app móvel sempre como "Soyeht" (sem "iOS app") e ao app desktop sempre como "Soyeht" (sem "macOS app" ou "client"). A diferenciação fica implícita pelo dispositivo.
- **FR-004**: O sistema MUST entregar o onboarding completo (carrossel, fluxos Caso A e B, mensagens de erro, telas de sucesso e recuperação) traduzido em todos os 15 idiomas suportados pelo string catalog do projeto (ar, bn, de, en, es, fr, hi, id, ja, mr, pt-BR, pt-PT, ru, te, ur).
- **FR-005**: O sistema MUST usar `LocalizedStringResource` ou `LocalizedStringKey` para todas as strings de UI (não literais hardcoded), e usar interpolação via `LocalizedStringResource(key, defaultValue:, comment:)` para strings com variáveis.

#### Caso A — Mac primeiro

- **FR-010**: O sistema MUST exibir tela de boas-vindas Mac com botão "Continuar" e progress indicator "1 de 3".
- **FR-011**: O sistema MUST exibir tela "O que vai acontecer agora" listando em linguagem desarmada: (a) Soyeht vai instalar uma parte que fica viva neste Mac mesmo com o app fechado, (b) explicação simples de qualquer permissão que o sistema operacional vá pedir, (c) tempo estimado, (d) menção de que pode ser desinstalado a qualquer momento.
- **FR-012**: O sistema MUST instalar Soyeht no Mac sem solicitar senha de administrador (admin password) em nenhum momento do fluxo padrão. Tentativas que requeiram tal solicitação devem ser tratadas como erro a ser refatorado ou caminho excepcional documentado.
- **FR-013**: Durante a instalação, o sistema MUST exibir progresso em 4 micro-steps user-friendly (verificando, pedindo permissão, instalando, acordando) com feedback visual de progresso a cada etapa.
- **FR-014**: Após instalação, o sistema MUST verificar autonomamente que Soyeht está vivo (health check) antes de avançar pra batismo da casa.
- **FR-015**: O sistema MUST permitir o operador digitar o nome da casa em campo de texto pré-preenchido com sugestão sensível ("Casa <nome do dono>"), aceitar string ≤32 caracteres sem caracteres de filesystem proibidos, e validar antes de avançar.
- **FR-016**: Após confirmação do nome, o sistema MUST gerar a identidade criptográfica da casa localmente no Mac e mostrar animação de progresso ≤3 segundos.
- **FR-017**: Após criação da casa, o sistema MUST exibir cartão visual da casa com nome em destaque, ícone do Mac listado como computador, e slot vazio "✨ adicionar iPhone" piscando suavemente.

#### Caso B — iPhone primeiro

- **FR-020**: O sistema MUST exibir carrossel de apresentação na primeira abertura do iPhone, contendo exatamente 5 cards de apresentação na ordem definida (US3), com indicador de página e CTA "Vamos começar" no último card.
- **FR-021**: O sistema MUST persistir flag de "carrossel visto" e suprimir reapresentação automática em aberturas subsequentes.
- **FR-022**: O sistema MUST oferecer entry point em Configurações pra revisar o carrossel sob demanda.
- **FR-023**: Após CTA do carrossel, o sistema MUST perguntar onde instalar Soyeht com opções "Meu Mac" (primary), "Meu Linux" (desabilitada com badge "em breve"), e link educativo opcional explicando o que significa "morar em algum computador".
- **FR-024**: Quando o operador escolhe "Meu Mac", o sistema MUST perguntar proximidade física antes de iniciar transferência de instalador.
- **FR-025**: Quando o operador confirma proximidade, o sistema MUST tentar entregar o instalador via mecanismo nativo Apple de proximidade (preferência primária) antes de degradar pra fallbacks (URL textual + QR pra Mac scanear).
- **FR-026**: O sistema MUST publicar um anúncio descobrível na rede privada pra que o Mac, ao terminar instalação local, identifique automaticamente o iPhone que iniciou o setup, sem QR scan visível ao usuário.
- **FR-027**: Quando o Mac descobre o anúncio do iPhone, o sistema MUST pular a tela de batismo de casa NO MAC e aguardar o nome ser digitado NO IPHONE.
- **FR-028**: O sistema MUST permitir o operador digitar o nome da casa NO IPHONE (mesmas regras de validação de FR-015) e transmiti-lo ao Mac, que cria a identidade da casa.
- **FR-029**: Após criação da casa via Caso B, o sistema MUST mostrar sincronizamente em ambos Mac e iPhone que a casa nasceu, com lista de moradores ("Mac Studio + iPhone <nome>").
- **FR-030**: Quando o operador escolhe "Vou fazer mais tarde", o sistema MUST oferecer link textual + share-sheet + opt-in opcional de lembrete por email, e exibir banner persistente na home view do iPhone até o setup ser completado.

#### Discovery & Pareamento

- **FR-040**: O sistema MUST descobrir casas e dispositivos automaticamente apenas quando a interface de rede ativa é identificada pelo OS como Tailscale (ou WireGuard mesh equivalente). Outras redes (incluindo VPNs corporativas/genéricas que não sejam Tailscale, redes Wi-Fi públicas, e LAN doméstica sem Tailscale) NÃO disparam autodescoberta por padrão.
- **FR-041**: O sistema MUST oferecer fallback opt-in explícito pra LAN bruta (RFC1918, .local, link-local) com aviso claro de que isso pode expor a casa a dispositivos desconhecidos na mesma rede. Esse opt-in é per-rede (ex: marcar Wi-Fi de casa como confiável), nunca global. **LAN bruta é 100% read-only** — discovery + visualização funciona, mas operações de pareamento (`/bootstrap/initialize`, `/local/anchor`, qualquer endpoint state-changing) recusam-se a rodar fora do Tailnet retornando `403 tailnet_required` com mensagem clara *"Pra adicionar máquinas, ative Tailscale na sua rede"*. Elimina caminho plain-text completamente; sem warning + HTTP fallback.
- **FR-042**: Quando múltiplas casas são detectadas na rede, o sistema MUST apresentar lista desambiguada onde cada linha mostra: (a) avatar visual único da casa — emoji + cor de fundo derivados deterministicamente da identidade criptográfica `hh_pub` da casa, ~32×32pt, (b) nome da casa em destaque, (c) nome amigável da máquina hospedeira em texto secundário, (d) timestamp da última atividade. O avatar funciona como reconhecimento visual instantâneo e nunca muda pra uma casa ao longo da vida dela.
- **FR-046**: O sistema MUST gerar avatar visual da casa (emoji + cor de fundo HSL) deterministicamente a partir de `hh_pub` na criação da casa, persistir essa associação localmente, e usar esse avatar consistentemente em toda surface da UI onde a casa é referenciada (lista de casas, cartão da casa, header de Configurações, push notifications de pareamento). O algoritmo de derivação MUST ser estável (mesmo `hh_pub` sempre gera mesmo avatar) e ter probabilidade de colisão ≤1×10⁻⁶ sobre uma população de até 10⁵ casas (espaço total ≥10¹¹ combinações; ver `research.md` R4 pra derivação). Avatar é PERSISTIDO no momento da criação da casa; render path NUNCA recomputa.
- **FR-043**: O sistema MUST validar a identidade do Mac descoberto antes de iniciar pareamento, e abortar com mensagem genérica caso a identidade não bata com o anúncio recebido.
- **FR-044**: O pareamento MUST exigir confirmação biométrica explícita do operador no iPhone antes de finalizar.
- **FR-045**: O sistema MUST exibir o "código de segurança" no Mac (durante criação ou pareamento) e no iPhone (na confirmação) usando o mesmo formato (6 palavras curtas, monospace, agrupadas em 2 fileiras de 3), com warning explícito de que ambos os códigos devem bater antes de confirmar.

#### Recuperação & Tranquilização

- **FR-050**: Após o iPhone virar primeiro morador (em qualquer caso A ou B), o sistema MUST exibir uma tela "Boa notícia" comunicando que perder o iPhone não é catastrófico — qualquer Mac da casa pode recuperar.
- **FR-051**: A tela de recuperação MUST ser dispensável com botão "Entendi" e re-acessível em Configurações > Sobre a Casa > Como recuperar.

#### Resiliência & Falhas

- **FR-060**: Em qualquer falha de rede (sem internet, AirDrop indisponível, descoberta sem resultado), o sistema MUST exibir mensagem em linguagem desarmada com ação concreta de retry, sem expor detalhes técnicos como códigos HTTP, nomes de protocolos, ou stack traces.
- **FR-061**: O sistema MUST permitir wipe completo do estado da casa via opção em Configurações ("Recomeçar do zero") com confirmação forte e explicação clara das consequências.
- **FR-062**: Se uma instalação anterior estiver corrompida e detectada, o sistema MUST oferecer "Reinstalar" sem solicitar ações técnicas do usuário.

#### Telemetria

- **FR-070**: O sistema MUST exibir o opt-in de telemetria embarcado na tela de preview do install — no Mac dentro da cena "O que vai acontecer agora" (Cena MA2 da Story 1), no iPhone na tela equivalente que precede o pedido de proximidade (Caso B) ou na cena equivalente do "O que vai acontecer agora" se o iPhone também roda preview de install. O elemento MUST ser um toggle visualmente claro com label "Compartilhar uso anônimo (muda depois em Configurações)" e default OFF.
- **FR-071**: Se opt-in concedido, o sistema MUST coletar apenas eventos enumerados e anônimos (instalação iniciada/concluída/falhou, primeiro pareamento concluído/falhou, casa criada, dispositivo adicionado), sem PII, sem mensagens de erro de formato livre.
- **FR-072**: O sistema MUST permitir alterar a preferência de telemetria a qualquer momento em Configurações com efeito imediato.
- **FR-073**: O default do toggle de telemetria MUST ser OFF (opt-in genuíno). Marcar como ON requer ação explícita do operador.

#### Acessibilidade (Apple-grade obrigatório)

- **FR-080**: O sistema MUST fornecer rótulos VoiceOver (accessibilityLabel) em todos os elementos interativos (botões, campos, indicadores de carrossel) e informativos (cartão da casa, lista de moradores, código de segurança) do fluxo de onboarding.
- **FR-081**: O sistema MUST suportar Dynamic Type em toda a hierarquia tipográfica do onboarding, incluindo as faixas Accessibility (AX1 até AX5/XXL), com layout que se adapta sem truncar conteúdo crítico.
- **FR-082**: O sistema MUST respeitar a preferência Reduce Motion do sistema operacional, substituindo animações do carrossel, transições entre cenas, e progress animations por cross-fade simples ou estado estático equivalente.
- **FR-083**: O sistema MUST atender contraste WCAG AA mínimo (4.5:1 texto normal, 3:1 texto grande) em todos os pares de cores texto-fundo do onboarding, em ambos os modos claro e escuro.
- **FR-084**: O sistema MUST suportar a preferência Increase Contrast, ajustando bordas e separadores quando ativada.
- **FR-085**: O sistema MUST respeitar Reduce Transparency, substituindo materiais translúcidos (Liquid Glass) por fundos sólidos equivalentes.
- **FR-086**: O sistema MUST fornecer rótulos Voice Control em elementos interativos com nomes em linguagem natural curta (correspondentes ao texto visível ou descrição funcional).
- **FR-087**: O sistema MUST garantir touch targets de no mínimo 44×44 pontos lógicos para todos os elementos interativos no iPhone.
- **FR-088**: O sistema MUST renderizar corretamente em RTL (right-to-left) quando o idioma do dispositivo é árabe (ar) ou urdu (ur), incluindo espelhamento de layout, direção de progress indicators do carrossel, ordenação de listas de moradores/dispositivos, e respeito ao posicionamento dos traffic lights no macOS (top-left mesmo em RTL, conforme padrão Apple HIG e memória interna `feedback_macos_rtl_traffic_lights.md`).

#### Qualidade Experiencial (Apple-grade)

> **Filosofia**: o objetivo NÃO é entregar funcionalidade rapidamente; é entregar a experiência mais fluida e emocionalmente confortável que o usuário pode receber, comparável ao bar Apple usa em seus próprios produtos. Cada FR abaixo é OBRIGATÓRIA para shipping, sem exceções por velocidade de delivery.

##### Animação & timing

- **FR-100**: Cada transição entre cenas do onboarding MUST usar curva `.spring(response:dampingFraction:)` com `response=0.42`, `dampingFraction=0.85` (curva Apple-padrão usada em Setup Assistant e Wallet) — exceto quando Reduce Motion ON, onde MUST degradar pra cross-fade linear de 200ms.
- **FR-101**: A animação "chave girando" durante criação da identidade da casa (Cena MA3 / FR-016) MUST durar entre 2.4s e 3.0s (não mais nem menos), com easing custom que acelera nos primeiros 1.2s, mantém ritmo nos 0.8s do meio, e desacelera nos 0.8s finais simbolizando "encaixe". Animação MUST sincronizar com 4 micro-steps de progresso (FR-013), cada step durando exatamente 0.6–0.75s.
- **FR-102**: Carrossel iOS (FR-020) MUST usar transições onde hero illustration tem parallax 0.4× (vs 1.0× do conteúdo de texto), cross-fade de imagem ao invés de slide rígido, e indicador de página onde o ponto ativo MORPHA pro próximo (não apenas slide) com `.spring` de `response=0.32`.
- **FR-103**: Avatar da casa (FR-046), no momento de revelação inicial (após criação da casa), MUST animar com scale-in `0.6→1.0` em `.spring(response=0.5, damping=0.7)`, simultaneamente cross-fade do emoji de opacity `0→1` em 0.4s, com soft glow halo que pulsa uma vez (∼0.6s) e desvanece. Em re-renders subsequentes, avatar aparece estático sem animação.
- **FR-104**: Cartão da casa "primeiro morador adicionado" (transição de slot pulsante pra morador presente) MUST animar com confetti emoji-stickers (4–6 partículas, ≤1.2s, leve, NÃO uma chuva agressiva) + ícone do iPhone "voando" pro slot com `.spring`. Em Reduce Motion: confetti substitui por simples cross-fade do estado.
- **FR-105**: Push notification "Casa Caio te chamou" no iPhone MUST renderizar como rich notification com avatar emoji (FR-046) + cor de fundo HSL como background do notification card; quando expanded (long-press), exibe casa name + Mac hospedeiro + tempo de espera ativo.
- **FR-106**: Botões CTA principais ("Continuar", "Vamos começar", "Confirmar") MUST ter momentary compress (`scale 0.96`) durante toque + return spring no release, com duração ≤120ms total. Botão de destaque ("Vamos começar" do carrossel + "Criar Casa" do naming) usa material Liquid Glass (iOS 26+) com tint accent.

##### Haptic feedback

- **FR-110**: Pareamento bem-sucedido (Caso A FR-014 + Caso B equivalent) MUST disparar haptic profile **em duas etapas** no iPhone: primeira `.soft` no momento do "verificando" (tela de progresso step 1), segunda `.success` (UINotificationFeedbackGenerator) no momento do "pronto". Duas etapas comunicam "começou + acabou" sem ser excessivo.
- **FR-111**: Tap em CTA do carrossel MUST disparar haptic `.soft` (suave, ≤30ms). Tap em opção desabilitada ("Meu Linux em breve") MUST disparar haptic `.warning` muito breve (perceptível, não repreensivo) + visual shake leve do botão.
- **FR-112**: Avatar revealed (FR-103) MUST sincronizar com haptic `.medium` no momento do scale-in completar (sensação tátil de "aterrissagem").
- **FR-113**: Erro recuperável (sem internet, AirDrop falhou) MUST usar haptic `.warning` (NÃO `.error` — preserva tom amigável). Erro fatal raro (engine corrompido, FR-062) usa `.error`.
- **FR-114**: Code de segurança (FR-045) bate entre Mac e iPhone MUST disparar haptic sincronizado em AMBOS os dispositivos (.success) no momento da confirmação biométrica — comunicando "estamos juntos" tactically.
- **FR-115**: Toda interação tátil MUST respeitar a preferência iOS Settings > Acessibilidade > Touch > Reduce Haptics.

##### Sound design

- **FR-116**: Sucesso de criação de casa (FR-016 final) MUST tocar chime curto ≤0.5s, warm-tonality (frequências 440Hz–880Hz, sem componentes >2kHz que soam "tech"), volume −12dB relativo ao master. Default: ON. Mute respeita Settings > Sons > Sons de Sistema do iOS/macOS.
- **FR-117**: Pareamento iPhone-confirmado MUST tocar mesmo chime do FR-116 mas com pitch shift +5 semitons (variante "morador adicionado") — mantém família sonora, distingue evento.
- **FR-118**: NUNCA sons de erro harshes (beeps agudos, error.aiff). Falhas usam haptic + visual silenciosamente. Sound design respeita FR-115 (Reduce Haptics) também desativando sons não-essenciais.

##### Voz dos textos (escrita user-facing)

- **FR-119**: Strings de erro user-facing MUST EVITAR as palavras "erro", "falha", "problema", "inválido", "incorreto", "rejeitado". Substitutos preferidos: "ainda não consegui...", "vamos tentar de novo", "isso não funcionou desta vez", "verifique se...", "algo aconteceu — pode ser...". Tom: amigo paciente, não sistema burocrático.
- **FR-120**: Strings de loading/progresso MUST usar verbos no presente contínuo amigável ("Preparando seu Mac", "Procurando seu iPhone", "Acordando Soyeht") — NUNCA "Aguarde...", "Processando...", "Carregando..." (genéricos).
- **FR-121**: Strings de confirmação positiva MUST evitar exclamação excessiva e linguagem corporativa. Preferir: "Pronto" / "Tudo certo" / "Sua casa está viva" sobre "Sucesso!" / "Concluído!" / "Operação completada com êxito".

##### Awareness contextual (first-launch detection)

- **FR-122**: Sistema MUST detectar restored-from-backup vs true first-launch via flag persistida em `NSUbiquitousKeyValueStore` (key `soyeht.first_launch_completed_at`). Em restored, suprime carrossel automático + surface tela "Você já usou Soyeht antes. Vamos reconectar com sua casa." quando o app abre.
- **FR-123**: Sistema MUST detectar conexão celular antes de iniciar transferência ≥10MB (Soyeht.dmg ~50MB) e surface confirmação explícita "Quer baixar usando dados móveis (~50MB) ou esperar Wi-Fi?" — default sugerido baseado em Wi-Fi-known-locations awareness.
- **FR-124**: Sistema MUST detectar bateria <20% no iPhone antes de iniciar Caso B + surface aviso amigável recomendando carregamento.
- **FR-125**: Sistema MUST respeitar Focus Mode ativo no iPhone — push notifications de pareamento aceitam filtragem por Focus, e quando filtradas o app surface entrada visual discreta (badge + Notification Summary) sem som/vibração extra.

##### Falhas com elegância

- **FR-126**: Falha de `SMAppService.register()` MUST diagnosticar o caso específico (status enum: `notRegistered`, `requiresApproval`, `notFound`, `enabled`, `unknown`) e renderizar UX apropriada por caso. Para `requiresApproval`: tela com animação visual (subtle setinha) apontando pra System Settings > Login Items + botão `Abrir Configurações` que faz deeplink direto via `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`. Para `notFound`: oferta automática de "Reinstalar Soyeht no Mac" sem solicitar ações técnicas. Para todos os casos: NUNCA culpa o usuário.
- **FR-127**: QR adulterado / Mac falsificado (edge case): em vez de mensagem genérica de erro, surface tela informativa "Não consegui confirmar que esse Mac é o seu. Pra sua segurança, cancelei o pareamento. Você pode tentar de novo escaneando o QR diretamente do Mac." com botões `Tentar de novo` e `Como saber se é o meu Mac?` (último abre help educativo).

##### Visualização do código de segurança (FR-045 elevado)

- **FR-128**: As 6 palavras do código de segurança MUST aparecer com staggered animation (cada palavra fade-in 60ms apart, total 0.36s) tanto no Mac quanto no iPhone. Sincronia entre dispositivos NÃO é estritamente necessária (cada um anima independente), mas VISUAL consistency (mesma fonte monospace, mesmo size 22pt, mesmo agrupamento 3+3) é obrigatória.
- **FR-129**: Quando o operador toca em "Confirmar" no iPhone após verificar o código bater, AMBOS os dispositivos (Mac + iPhone) MUST animar uma sutileza de validação ao redor das palavras (subtle green glow halo ≤0.4s) + haptic FR-114, comunicando "está combinando" sem ser explícito demais.

##### Continuity Camera QR fallback (FR-025 elevado)

- **FR-130**: Quando Mac webcam scaneia QR exibido no iPhone (cena PB3b fallback), Mac UI MUST mostrar viewport ao vivo da webcam com 4 cantos animados (acende em verde 1 por vez quando QR começa a ser decodificado), + freeze-frame no momento da detecção bem-sucedida com check-mark animado, + smooth transition (não corte) pra Safari abrindo a URL de download.

##### Localização — qualidade além de cobertura

- **FR-138**: Strings com plurais MUST usar formato `xcstrings` plural rules (substitution variants `one`, `few`, `many`, `other` conforme regras de cada locale CLDR), não interpolação manual. Exemplo: "1 morador" / "2 moradores" / em russo: "1 житель" / "2 жителя" / "5 жителей".
- **FR-139**: Strings que possam carregar gênero (ex: "novo morador" → masculino default) MUST ser revisadas por falante nativo de cada locale pra adotar formulação gender-neutral onde idioma permite (ex: PT "novo morador" pode virar "morador novo" mantendo neutralidade; FR "nouveau résident" → "nouvelle personne dans la maison" reformulação).
- **FR-140**: Cada locale MUST passar por revisão cultural (não só tradução literal) pra catch frases que soam frias ou impositivas no idioma alvo (ex: imperativo direto em japonês pode soar rude; locale-specific copy ajusta pra "〜してください" formal).

### Key Entities

- **Casa**: A unidade central de identidade. Tem um nome amigável dado pelo operador, uma identidade criptográfica criada localmente no primeiro Mac, e uma lista de moradores (devices pessoais) e máquinas hospedeiras (Macs, futuramente Linux). É soberana — não depende de servidor central.
- **Operador (dono da casa)**: A primeira pessoa a criar a casa. Tem autoridade pra aprovar entrada de novos dispositivos. No escopo desta entrega, é o único papel — não há convidados ou múltiplos operadores.
- **Morador (device pessoal)**: Um iPhone, iPad ou Mac adicional que o operador autorizou. Pode acessar e operar a casa. Esta entrega cobre apenas a adição do **primeiro** morador (iPhone).
- **Computador da casa (máquina hospedeira)**: O Mac onde Soyeht está vivo e que hospeda a identidade da casa. Esta entrega cobre apenas **um** computador (o Mac onde a casa nasceu).
- **Código de segurança**: Sequência curta de 6 palavras visualmente verificável que o operador deve comparar entre dois dispositivos antes de confirmar um pareamento. É o único conceito técnico que aparece no UI, e tem nome amigável.
- **Carrossel**: Apresentação visual de 5 cards na primeira execução do app iOS. É um asset estático (não dinâmico), com strings localizáveis.
- **Avatar da casa**: Par {emoji, cor de fundo} derivado deterministicamente da identidade criptográfica da casa, atribuído na criação e usado em toda surface visual onde a casa aparece (listas de descoberta, cartões, push notifications). Permanece estável durante a vida da casa.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: ≥95% dos operadores que iniciam o Caso A (drag-to-Applications) completam até "primeiro morador iPhone confirmado" em ≤45 segundos, sem precisar de intervenção externa ou suporte.
- **SC-002**: ≥95% dos operadores que iniciam o Caso B (carrossel + "Meu Mac" + proximidade) completam até "primeiro morador iPhone confirmado" em ≤4 minutos, incluindo download do instalador.
- **SC-003**: 0 prompts de senha de administrador são solicitados ao operador durante o fluxo de instalação no Mac padrão.
- **SC-004**: 0 strings de UI contêm vocabulário banido (auditável programaticamente via grep da string catalog em CI).
- **SC-005**: ≥90% dos pareamentos iPhone↔Mac concluem com sucesso na primeira tentativa (sem retry manual do operador).
- **SC-006**: ≥85% dos operadores expostos ao carrossel iOS chegam até o CTA "Vamos começar" (não saem do app antes do último card).
- **SC-007**: ≥80% dos operadores que escolhem "Vou fazer mais tarde" e optam por lembrete por email retornam pro fluxo dentro de 7 dias.
- **SC-008**: 100% dos dispositivos pareados via Caso B têm o nome da casa correto digitado no iPhone refletido no Mac sem divergência.
- **SC-009**: ≥98% das mensagens de erro mostradas durante o onboarding (sem internet, AirDrop falhou, etc) levam o operador a uma ação concreta de retry sem precisar de suporte humano.
- **SC-010**: A tela de "boa notícia" sobre recuperação é exibida em 100% dos pareamentos bem-sucedidos.

## Assumptions

- **Plataforma Mac**: O Mac do operador é Apple Silicon (M-series). Suporte Intel está fora de escopo nesta entrega.
- **Distribuição Mac**: O instalador Mac é distribuído como um arquivo notarizado pela Apple via canal próprio (não via App Store nesta entrega).
- **Distribuição iOS**: O app iOS é distribuído via App Store padrão.
- **Rede privada confiável**: O operador tem acesso a uma rede privada confiável (Tailscale ou similar) configurada antes do início do onboarding. Onboarding em rede pública/desconhecida é fora de escopo nesta entrega.
- **Apple ID**: Não há requisito de Mac e iPhone compartilharem o mesmo Apple ID. O fluxo deve funcionar em ambos os casos.
- **Proximidade física Caso B**: Quando o operador diz "estou perto do meu Mac", o Mac está fisicamente alcançável (mesma sala, mesmo Wi-Fi). Distância maior é tratada como caso "Vou fazer mais tarde".
- **Permissões iOS**: O operador concede permissões padrão pedidas pelo app iOS (notificações pra push de pareamento, câmera pra fallback de QR, AirDrop). Recusas são tratadas com fallbacks degradados, não como erros.
- **Linux fora de escopo**: A opção "Meu Linux" no iPhone aparece desabilitada com badge "em breve" pra honestidade de roadmap, mas não é funcional nesta entrega.
- **Recovery completo fora de escopo**: A mensagem de recuperação é apenas comunicada (FR-050); o fluxo real de recuperar uma casa por outro Mac quando o iPhone original foi perdido é uma feature separada, fora desta entrega.
- **App Store v2**: Eventual distribuição Mac via App Store é v2 e não é atendida por esta spec.
- **Auto-pair sem QR via rede confiável**: Otimização de fricção (pular QR scan quando ambos os dispositivos provarem identidade via rede confiável) é trabalho de iteração futura com threat model dedicado, fora desta primeira spec de onboarding.

## Dependencies

- A apresentação visual (carrossel + telas Welcome) requer ativos gráficos finais aprovados pelo operador antes da entrega final, mas pode usar placeholders durante implementação.
- O fluxo Caso B depende de mecanismo nativo Apple de proximidade estar disponível e funcional na geração de iPhone do operador (iPhone 11 ou superior pra AirDrop estável).
- A tela de "Reapresentar tour" em Configurações depende da infraestrutura de configurações já existente no app iOS.
- Mecanismo de telemetria opt-in depende de endpoint próprio de coleta estar disponível (fora do escopo desta spec — assumido como pronto pelo time).
