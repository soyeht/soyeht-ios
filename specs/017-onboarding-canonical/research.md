# Phase 0 Research — Onboarding Canônico Soyeht

**Feature**: 017-onboarding-canonical
**Date**: 2026-05-09
**Purpose**: Resolve all `NEEDS CLARIFICATION` and tech-choice unknowns from `plan.md` before Phase 1 design.

---

## R1 — AirDrop programmatic invocation pra entregar Soyeht.dmg do iPhone pro Mac

**Decision**: Use `UIActivityViewController` com `NSItemProvider` carregando o `Soyeht.dmg` bundleado (~50–80MB), com `applicationActivities: nil` e `excludedActivityTypes` filtrando tudo exceto AirDrop. iPhone exibe a sheet AirDrop nativo restrito (sem outras opções como Mail/Mensagens), Mac do usuário aceita via prompt do sistema, .dmg cai em `~/Downloads`.

**Rationale**:
- AirDrop é a única transferência de arquivo iPhone→Mac com aceitação visual nativa, sem digitação de URL, sem cloud middleman, sem requisito de Apple ID compartilhado (Apple permite cross-Apple-ID com confirmação manual).
- `UIActivityViewController` com lista filtrada por `excludedActivityTypes` é o padrão Apple-blessed; alternativas que invoquem AirDrop diretamente via APIs privadas não são aceitas pela App Store.
- O .dmg é assinado com Developer ID + notarized; aceitação no Mac não dispara warning Gatekeeper.

**Alternatives considered**:
- **iCloud Drive share link**: rejeitado — exige conta iCloud, frequentemente surface UI confusa de "share via iCloud Drive", lento pra arquivo de 50MB sem boost de proximidade.
- **Continuity Universal Clipboard**: rejeitado — limite de tamanho prático (~few MB), comportamento erratico cross-platform com .dmg.
- **`MultipeerConnectivity` direto**: rejeitado — funciona, mas Mac side precisaria de app Soyeht já instalado pra receber, contradizendo o cenário "Mac sem Soyeht ainda".
- **HTTP server local no iPhone via `NWListener`**: rejeitado — Mac precisaria abrir browser e digitar IP local, contradizendo "sem QR scan visível ao usuário".

**Implementation notes**:
- `NSItemProvider(item: dmgURL, typeIdentifier: "com.apple.disk-image-udif")` (UDIF é o subtipo dmg padrão notarizado)
- `excludedActivityTypes`: tudo exceto `.airDrop`
- Fallback automático: se `UIActivityViewController` retorna `completed=false` ou tipo selecionado ≠ AirDrop, app degrada pra cena PB3b (URL+QR).

---

## R2 — Bonjour service `_soyeht-setup._tcp.` publication pelo iPhone

**Decision**: iPhone publica via `NWListener` (Network framework) sobre interface Tailscale. Service type `_soyeht-setup._tcp.`, port atribuído dinamicamente. TXT record (CBOR-encoded inside TXT value, base64url): `{v: 1, token: <32-byte random>, owner_display_name: <utf8 string ≤32 chars>, expires: <unix-timestamp ≤now+3600>}`. Service publication ativada quando user confirma proximidade (cena PB2 "Sim, estou no Mac"); cancelada após Mac fazer claim ou após TTL expirar.

**Rationale**:
- `NWListener` é o sucessor moderno de `NSNetService`/`CFNetService`; `NSNetService` foi marcada deprecada em iOS 18 (via `availabilityCheck`).
- Bonjour TXT records são limitados a 255 bytes por chave-valor; CBOR encoding compacta o token (32 bytes raw) + nome (≤96 bytes UTF-8) + timestamp (8 bytes) em ≤150 bytes — cabe.
- Tailscale-only restriction (Q3) implementada via `NWParameters.requiredInterfaceType = .other` + filtro programático por nome de interface (`utun*` com path conduzindo via Tailscale).
- TTL no token previne replay caso iPhone perca o controle do service prematuramente.

**Alternatives considered**:
- **HTTP polling em endpoint hospedado por iPhone**: rejeitado — Mac precisaria descobrir IP do iPhone, e descoberta sem mDNS é fricção.
- **Cloud relay (telemetry.soyeht.com com endpoint setup)**: rejeitado — viola Constitution III (no central control plane).
- **Bluetooth LE service**: rejeitado — Apple BLE peripheral mode em iOS é restrito (não pode anunciar serviços enquanto app em background sem entitlement); UX fica frágil. Bonjour-over-Tailscale é mais robusto.

---

## R3 — SoyehtMac install pattern: SMAppService.agent vs LaunchAgent plist drop

**Decision**: **`SMAppService.agent(plistName:)`** introduzido em macOS 13+. App registra o plist `com.soyeht.engine.plist` que vive dentro do app bundle (em `Contents/Library/LaunchAgents/`); chamada `SMAppService.agent(plistName: "com.soyeht.engine.plist").register()` faz a instalação per-user, sem sudo, sem `launchctl bootstrap` manual.

**Architectural clarification (alinhado com agente-backend 2026-05-09)**: o engine Rust é **processo independente gerenciado pelo launchd**, NÃO é subprocess do Soyeht.app. Soyeht.app distribui o binário em `Contents/Helpers/soyeht-engine`, mas:
- Soyeht.app NÃO spawna o engine como child process direto
- SMAppService registra o plist; launchd lê e starta o processo separadamente
- Soyeht.app comunica com engine via HTTP loopback (`http://127.0.0.1:8091` + Tailscale interface)
- Engine sobrevive Soyeht.app being closed (matches FR "Soyeht continua vivo neste Mac mesmo com o app fechado")
- Engine tem acesso a Security.framework como qualquer processo macOS — crate `security-framework` (pure Rust) ou FFI direto. NÃO depende de "estar embedded em Soyeht.app process address space".

Plist source-of-truth: agente-backend define o conteúdo do `com.soyeht.engine.plist` em theyos repo; SoyehtMac build phase script copia pra `Contents/Library/LaunchAgents/` durante archive. Versionamento conjunto via release tag.

**Rationale**:
- Apple-blessed (substitui `SMJobBless` legacy que requeria helper tool + Authorization Services + sudo).
- macOS 15+ é nosso target — `SMAppService` está disponível desde macOS 13.
- Per-user (não system-wide) — alinha com Constitution III (state per-user) e elimina sudo prompt.
- App pode chamar `unregister()` em "Recomeçar do zero" (FR-061) sem precisar de helper privilegiado.
- Status query via `SMAppService.status` permite app saber se engine já tá registrado e healthy.

**Alternatives considered**:
- **Manual plist drop em `~/Library/LaunchAgents/` + `launchctl bootstrap gui/$UID`**: rejeitado — funciona mas precisa lidar com edge cases (plist malformado, launchctl errors, permission denied no diretório). `SMAppService` encapsula tudo isso.
- **`launchctl submit`**: deprecada desde macOS 10.10.
- **`SMJobBless`**: deprecada em macOS 13. Constitution Principle IV (no legacy compat) reforça evitar.
- **System daemon via `SMAppService.daemon`**: rejeitado — exige sudo prompt na primeira instalação, viola FR-012.

---

## R4 — Avatar deterministic emoji+color derivation a partir de `hh_pub` (FR-046)

**Decision**: Derivação determinística usando SHA-256 (constitution permite SHA-256 fallback quando BLAKE3 não disponível; CryptoKit não tem BLAKE3 nativo) sobre os 33 bytes SEC1 compressed `hh_pub`. Output 256-bit dividido em dois índices:
- **Emoji**: bytes [0..3] (32 bits) → mod 512 → índice em curated emoji list (512 emojis selecionados pra serem visualmente distintos, semanticamente neutros, e renderizados consistentemente em todas as plataformas Apple).
- **Cor de fundo**: bytes [4..7] (32 bits) → 3 sub-índices: HUE bytes[4..5] (16 bits) → 0..359°, SAT bytes[6] → 60..85%, LIGHTNESS bytes[7] → 50..70% (faixas restritas pra garantir contraste WCAG AA com texto branco).

Algoritmo determinístico: mesmo `hh_pub` sempre produz mesmo `(emoji, color)`. Espaço total: 512 emojis × 360 hues × 26 sat × 21 lightness ≈ 100M combinações, colisão entre 2 casas distintas tem probabilidade <1e-7 mesmo com 10K casas no universo.

**Rationale**:
- Determinismo é essencial: avatar é a "fingerprint visual" da casa, mesmo em todos os devices que descobrem ela.
- Curated emoji list (não emoji list completo) garante consistência cross-platform: emojis novos do iOS 18 podem aparecer como "?" em iOS 16; selecionar conjunto estável de Unicode 12 ou anterior elimina o risco.
- Color em HSL (não RGB direto) com restrição de saturation+lightness garante contraste WCAG AA com texto branco (FR-083).
- SHA-256 é cripto-grade — ataque de pré-imagem pra forjar avatar igual de outra casa é computacionalmente inviável.

**Alternatives considered**:
- **BLAKE3-256**: preferida por constitution mas CryptoKit não tem nativo. Adicionar dep terceira (e.g., `BLAKE3.swift`) só pra avatar derivation é overhead injustificado. Constitution permite SHA-256 fallback.
- **Emoji + cor + nome amigável da máquina (Q5 Option A)**: rejeitado por Caio em Q5; avatar visual standalone foi escolhido.
- **Identicon SVG (estilo GitHub)**: rejeitado — visual mais opaco; emoji é mais reconhecível.
- **Apenas cor sem emoji**: rejeitado — 360 hues × poucos lightness = ~1000 combinações apenas, colisão alta com 100+ casas.

**Curated emoji list** (definida em `HouseAvatarEmojiCatalog.swift`): 512 emojis selecionados de Unicode 12, evitando: emojis ambíguos (skin-tone variants), tags geopolíticas (bandeiras), emojis de pessoa/profissão (poderia gerar associação não-intencional), emojis violentos. Inclui: animais comuns, plantas, comida, objetos domésticos, formas geométricas, símbolos abstratos.

---

## R5 — Reduce Motion strategy pro carrossel iOS (FR-082)

**Decision**: Verificar `UIAccessibility.isReduceMotionEnabled` no init do carrossel. Quando true: substituir transição parallax+cross-fade por **cross-fade simples** com duration 200ms (vs 400ms padrão), e desativar parallax de hero illustration. Indicador de página (pontos no rodapé) permanece, mas sem animação de "pulsação" do dot ativo.

**Rationale**:
- Reduce Motion não significa "sem animação"; significa "sem animação que possa causar enjoo vestibular" (parallax, zoom, spinning). Cross-fade é safe.
- Apple HIG explicit: "Honor Reduce Motion — provide alternative paths for users who prefer no movement, but don't strip the experience to zero."
- Observable via Combine publisher (`NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)`) — preference change durante uso atualiza imediatamente.

**Alternatives considered**:
- **Skip carrossel entirely quando Reduce Motion**: rejeitado — usuário ainda merece ver as 5 mensagens, só não com efeitos visuais agressivos.
- **Manter animações mas com `.easeInOut` mais lento**: rejeitado — parallax horizontal still triggers vestibular response em alguns usuários; tem que cortar parallax especificamente.

---

## R6 — Push notification "Casa nasceu" pro iPhone (Story 1 step 4-5, Story 2 step 6)

**Decision**: theyos engine no Mac envia push via **APNS direct** usando token JWT-signed (provider key) pra Apple's APNs gateway `api.push.apple.com`. iPhone registra device token via `UNUserNotificationCenter.requestAuthorization` durante o setup-invitation publish (Caso B) ou após pareamento bem-sucedido (Caso A). Token entregue ao Mac via Bonjour setup-invitation TXT (Caso B) ou via PoP-signed handoff durante pareamento (Caso A). theyos persiste device token no household state.

**Rationale**:
- APNS direct (sem cloud relay) preserva Constitution III (local-first; nenhum servidor central de Soyeht).
- Provider key (`.p8` cert) bundled dentro do Mac engine binary, pode ser rotacionado via Sparkle update.
- Apple permite até 1024 device tokens por bundle ID — suficiente.
- Não exige Cloudflare Worker ou outro intermediário.

**Alternatives considered**:
- **Push via Cloudflare Worker relay (cloudflare → APNs)**: rejeitado — adiciona terceiro, viola "no central control plane" mesmo sendo benigno (CW só passa pro APNs).
- **Bonjour-only signaling (sem APNs)**: rejeitado — funciona quando iPhone tá na rede e app aberto, mas não acorda iPhone trancado/em background. Push é necessário pra "Casa Caio te chamou" arrival quando iPhone tá na bolsa.
- **Apple Push via SwiftNIO server-side**: viable; theyos pode usar `swift-nio` Rust binding indireto, mas crate `apns-rs` direto cobre a need sem layer extra.

**Implementation notes**:
- Provider key gerada uma vez por release de Soyeht.app, distribuída via .dmg + Sparkle.
- Device token TTL: persiste até iPhone desinstalar app ou revogar permissão.
- Fallback: se push falha (token inválido, rate limit), pareamento ainda acontece quando user abre app manualmente — Bonjour discovery cobre.

---

## R7 — Soyeht.dmg bundle structure + signing + notarization

**Decision**:

```
Soyeht.dmg (UDIF, signed + notarized + stapled)
└── Soyeht.app
    ├── Contents/
    │   ├── Info.plist (CFBundleIdentifier=com.soyeht.app)
    │   ├── MacOS/Soyeht (Swift app binary, signed)
    │   ├── Helpers/
    │   │   └── soyeht-engine (Rust binary, signed with same Developer ID)
    │   ├── Library/
    │   │   └── LaunchAgents/
    │   │       └── com.soyeht.engine.plist (template, copied to ~/Library/LaunchAgents on first launch)
    │   ├── Resources/
    │   │   ├── Localizable.xcstrings (15 locales)
    │   │   ├── Carousel/ (assets)
    │   │   └── push-provider.p8 (APNs provider key)
    │   └── _CodeSignature/
    └── (Soyeht.app symlinked to /Applications drag target inside dmg)
```

Pipeline:
1. Build engine via `cargo build --release --target aarch64-apple-darwin` (Apple Silicon-only v1).
2. Sign engine binary: `codesign --sign "Developer ID Application: ..." --options=runtime --timestamp Soyeht.app/Contents/Helpers/soyeht-engine`.
3. Build Swift app via Xcode archive, embed engine in Helpers via build phase script.
4. Sign full .app: `codesign --sign ... --deep --options=runtime --timestamp Soyeht.app`.
5. Create dmg: `create-dmg` or `hdiutil create`.
6. Sign dmg: `codesign --sign ... Soyeht.dmg`.
7. Notarize: `xcrun notarytool submit Soyeht.dmg --wait`.
8. Staple: `xcrun stapler staple Soyeht.dmg`.

**Rationale**:
- Pipeline é evolução da PR #43 (Developer ID notarization já estabelecida).
- `--options=runtime` (Hardened Runtime) é exigido pela App Store + notarization.
- Binary embed via build phase é Xcode-friendly e funciona com remote build farms.

**Alternatives considered**:
- **Engine como helper tool separado (não embedded)**: rejeitado — usuário teria 2 instaladores. Constitution I (zero manual ops).
- **Universal binary (Apple Silicon + Intel)**: rejeitado — adiciona ~30% tamanho; Intel out-of-scope per spec.
- **Distribuição via brew tap**: rejeitado como entrega primária (nicho dev); pode coexistir como rota docs-only mais tarde.

---

## R8 — Hardware-bound P-256 keypair generation com biometry (Mac + iPhone)

**Decision**: Use `SecKeyCreateRandomKey` com attributes `[kSecAttrTokenIDSecureEnclave: kCFBooleanTrue, kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256, kSecAttrAccessControl: SecAccessControlCreateWithFlags(.biometryCurrentSet, .privateKeyUsage)]` para criar `hh_priv` (Mac) e `D_priv` (iPhone). Public key extraída via `SecKeyCopyPublicKey` + serializada em SEC1 compressed (33 bytes) via `SecKeyCopyExternalRepresentation` + parser P-256.

Ed25519 NÃO é usado; constitution v2.0.0 mandates P-256 ECDSA pra Apple platforms (Secure Enclave compatibility).

**Rationale**:
- Constitution explícita: "Identity-bearing private keys on Apple platforms ... MUST be created with `kSecAttrTokenIDSecureEnclave`".
- `kSecAccessControlBiometryCurrentSet` impede que troca de biometric (e.g., adicionar nova face em Face ID) bypasse o gating.
- Signing via `SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, data, &error)`.

**Alternatives considered**:
- **Ed25519 com envelope wrap**: rejeitado por constitution (private scalar materializaria em RAM).
- **Software-only P-256 (sem SE)**: rejeitado — perde proteção hardware-isolated, viola constitution.
- **Senza biometric ACL**: rejeitado — primeira coisa que vaza num Mac roubado é o keychain plain.

---

## R9 — Continuity Camera + Vision pra QR fallback (cena PB3b)

**Decision**: No fallback "Continuity Camera disponível", Mac usa `AVCaptureSession` com `.builtInWideAngleCamera` (default Mac webcam) + `VNDetectBarcodesRequest` (Vision framework) configurado pra `.qr` symbology. Frame buffer scanned em background queue; quando QR detectado, parsing do payload (URL `https://soyeht.com/mac?token=<base64url>`) abre Safari direto na página de download.

**Rationale**:
- Continuity Camera (macOS 13+, conecta automaticamente iPhone como webcam) e built-in webcam ambos servem pelo mesmo `AVCaptureDevice` API.
- Vision framework é Apple-blessed e cobre QR sem deps externas.
- Mostra ao Mac um QR rendered pelo iPhone (na tela do iPhone) — Mac webcam scaneia.

**Alternatives considered**:
- **`CIDetector` (CoreImage)**: depreciado em iOS 17+ pra `VNDetectBarcodesRequest`. Constitution Principle IV (no legacy).
- **`AVCaptureMetadataOutput`**: funcional mas Vision dá mais controle sobre lighting/angle correction.

---

## R10 — RTL traffic light positioning no macOS

**Decision**: Em RTL (ar/ur), traffic lights ficam **top-LEFT** (mesma posição física que LTR), per Apple HIG e memória `feedback_macos_rtl_traffic_lights.md`. Conteúdo da janela espelha (botões primary→right, navegação→inverted), MAS reserva física dos traffic lights não muda. Implementação: `NSWindowController` com `titlebarAppearsTransparent = true` + custom title bar accessory que respeita traffic lights na esquerda mesmo em RTL.

**Rationale**:
- Apple HIG: "Window controls always appear in the same physical location regardless of language direction."
- Espelhar traffic lights pra direita quebra muscle memory dos usuários macOS.
- Memória `feedback_macos_rtl_traffic_lights.md` é diretiva direta.

**Alternatives considered**: nenhuma — é diretriz Apple.

---

## R11 — Encryption-at-rest do Soyeht.dmg durante AirDrop transfer

**Decision**: AirDrop transfer já é encrypted-by-default pela Apple (TLS sobre Bluetooth/Wi-Fi P2P). Não precisamos camada extra. .dmg já é signed+notarized; a integridade é verificada pelo Gatekeeper antes da abertura.

**Rationale**: AirDrop usa TLS 1.2+ com mutual auth via Apple ID certs; man-in-the-middle dentro de proximidade Bluetooth é tecnicamente possível mas requer atacante físico ≤9 metros, que está fora do threat model de onboarding consumer.

**Alternatives considered**: nenhuma necessária — Apple-native crypto suficiente.

---

## R12 — Telemetry endpoint hosting

**Decision**: Cloudflare Worker em `telemetry.soyeht.com` recebendo `POST /event` com body CBOR `{event: <enum>, timestamp: <unix>, version: <semver>, platform: <enum>}`. Worker armazena em Cloudflare D1 (SQLite serverless) com retention 90 dias, sem IP logging (Cloudflare cf-connecting-ip stripped at edge). Custo estimado <$1/mês até 100K events.

**Rationale**:
- Constitution III aceita telemetria opt-in com PII strip — Cloudflare Worker é o caminho mais barato + edge-fast.
- D1 é SQLite-as-a-service; retention SQL fácil.
- Endpoint próprio (não Mixpanel/Amplitude) preserva data sovereignty.

**Alternatives considered**:
- **Self-hosted (digital ocean droplet + postgres)**: rejeitado — overhead operacional, Cloudflare Worker é serverless.
- **Mixpanel/Amplitude**: rejeitado — third-party PII risk; constitution III concerns.

**Out of scope this delivery**: actual Cloudflare Worker implementation. Plan freezes the contract and event enum; the endpoint setup is a parallel ops task.

---

## R13 — Bonjour TXT enrichment pro existing `_soyeht._tcp.` service

**Decision**: Adicionar campos no TXT record:
- `hh_name` (já existe — confirmar com theyos team)
- `owner_display_name`: human-friendly name digitado no FR-015 (≤32 UTF-8 bytes)
- `device_count`: número de moradores paireados (UInt8)
- `platform`: enum string `mac` | `linux` (futuramente)
- `bootstrap_state`: enum string `uninitialized` | `ready_for_naming` | `named_awaiting_pair` | `ready` | `recovering`

TXT record limit 1300 bytes total (DNS-SD spec); cabe folgado.

**Rationale**: discovery UI no iPhone quer mostrar "Casa Caio · Mac Studio · 2 moradores · viva agora há 5min" — esses campos viabilizam.

**Alternatives considered**:
- **Mantém TXT minimal, app faz HTTP get pro engine pra info rica**: rejeitado — adiciona round-trip; lista de discovery deve ser instant.

---

---

## R14 — Animation curves catalog (Apple-grade timing)

**Decision**: Define um catalog explícito de curvas e durações em `Packages/SoyehtCore/Sources/SoyehtCore/Animation/AnimationCatalog.swift` que TODA scene de onboarding consome (sem hardcoded values dispersos).

| Token | Curve | Duration | Use case |
|---|---|---|---|
| `sceneTransition` | `.spring(response: 0.42, dampingFraction: 0.85)` | implicit | Transição entre cenas (FR-100) |
| `keyForging` | custom Bezier (0.2,0.0)→(0.8,1.0) | 2.4–3.0s | "Chave girando" durante criação (FR-101) |
| `carouselPageDot` | `.spring(response: 0.32, dampingFraction: 0.78)` | implicit | Morphing dot do indicador (FR-102) |
| `avatarReveal` | `.spring(response: 0.5, dampingFraction: 0.7)` | implicit | Avatar scale-in inicial (FR-103) |
| `confettiBurst` | linear out, 4–6 partículas | ≤1.2s | Cartão "primeiro morador" (FR-104) |
| `buttonPress` | spring | ≤120ms | CTA momentary compress (FR-106) |
| `staggerWord` | linear, 60ms apart | total 0.36s | Código de segurança 6-word reveal (FR-128) |
| `safetyGlow` | `.easeInOut` | 0.4s | Validação pós-confirmação (FR-129) |

**Rationale**: hardcoded animation values disperos em N views = drift. Catalog centraliza, facilita Reduce Motion override (única source de verdade), e CI test pode auditar ausência de hardcoded curves.

**Alternatives considered**:
- **Per-view animation literals**: rejeitado — drift inevitable, Reduce Motion override fica frágil.
- **Apple's stock spring presets (`.bouncy`, `.smooth`, `.snappy`)**: rejeitado — Apple presets são dimensions adimensionais que mudam entre OS versions; explicit values estabilizam.

---

## R15 — Haptic feedback profiles

**Decision**: `Packages/SoyehtCore/Sources/SoyehtCore/Haptics/HapticDirector.swift` centraliza todas as invocações `UINotificationFeedbackGenerator` / `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator`.

| Profile | Generator | Type | Trigger |
|---|---|---|---|
| `pairingProgress` | impact | `.soft` | Início do "verificando" (FR-110 step 1) |
| `pairingSuccess` | notification | `.success` | Conclusão de pareamento (FR-110 step 2) |
| `ctaTap` | impact | `.soft` | Tap em CTA principal (FR-111) |
| `disabledTap` | notification | `.warning` | Tap em opção disabled (FR-111) |
| `avatarLanded` | impact | `.medium` | Avatar scale-in completou (FR-112) |
| `recoverableError` | notification | `.warning` | Erro com retry available (FR-113) |
| `fatalError` | notification | `.error` | Engine corrupted etc (FR-113) |
| `codeMatch` | notification | `.success` | Código de segurança bate (FR-114) |

**Reduce Haptics** (`UIAccessibility.isReduceHapticsEnabled`, iOS 17+): HapticDirector verifica antes de toda invocação. Quando ON, suppress todos os haptics não-essenciais (mantém apenas `pairingSuccess` e `codeMatch` por critério de feedback de segurança).

**Rationale**: profile-based abstraction protege contra drift + facilita override em uma única place pra Reduce Haptics + facilita test mock (HapticDirector.mock no XCTest sem invocar real generators).

---

## R16 — Sound design

**Decision**: 2 audio assets `.caf` (Core Audio Format, Apple-blessed pra iOS) compactos:
- `casa-criada.caf` — 440Hz fundamental + harmônicos pares 2x/4x (warm), envelope ADSR com attack 50ms / sustain 200ms / release 250ms, total 0.5s, peak −12dBFS
- `morador-pareado.caf` — variante de `casa-criada.caf` com pitch shift +5 semitons (mantém família sonora)

`SoundDirector.swift` em SoyehtCore aciona via `AVAudioPlayer` com volume relativo ao master. Verifica `AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint` antes de tocar (silencia quando outro app está com áudio em foreground).

**Rationale**: `.caf` é Apple-native (zero compression artifacts perceptíveis no range usado). 2 sons apenas — minimalismo Apple, não soundscape de aplicativo de banco. ADSR carefully crafted evita "tech beep" sensation.

**Alternatives considered**:
- **System sound IDs (e.g., kSystemSoundID_TweetSent)**: rejeitado — não branded, indistinto de outros apps.
- **Procedurally synthesized via AudioKit**: rejeitado — overhead de framework + risk de inconsistência entre devices.

---

## R17 — Voice copy guide (banned vs preferred phrasing)

**Decision**: documenta em `specs/017-onboarding-canonical/copy-voice.md` (artefato follow-up) o guia de voz adotado, baseado em Apple HIG "Inclusion → Empathetic language" + customização Soyeht.

**Banned vocabulary** (extensão de FR-001, foca em error voice por FR-119):

| Banido | Substituto preferido |
|---|---|
| "Erro" | "Algo aconteceu" / "Não consegui" |
| "Falha" | "Não funcionou desta vez" |
| "Inválido" | "Não reconheci esse formato" |
| "Rejeitado" | "Não pude confirmar" |
| "Aguarde..." | "Estou preparando..." |
| "Carregando..." | "Estou trabalhando" / "Buscando..." |
| "Processando..." | (use verbo específico: "Verificando", "Acordando", "Salvando") |
| "Sucesso!" | "Pronto" / "Tudo certo" |
| "Concluído!" | "Sua casa está viva" |

**Tone**: amigo paciente, não sistema burocrático. **Não** infantilizar — usuário é adulto. **Não** usar emojis excessivos no texto (separado do uso emoji-as-avatar). **Não** excessive exclamation marks (no máximo 1 por view).

---

## R18 — Restored-from-backup detection (FR-122)

**Decision**: usa `NSUbiquitousKeyValueStore` (iCloud KV) com key `soyeht.first_launch_completed_at`. Se a key existe E iPhone foi inicializado com Apple ID conhecido (não fresh device), trata como restored. Lógica:

```swift
let kvStore = NSUbiquitousKeyValueStore.default
kvStore.synchronize()
if let firstLaunch = kvStore.object(forKey: "soyeht.first_launch_completed_at") as? Date {
    // Restored from backup — flag para suprimir carrossel + tentar reconciliação
    isRestoredFromBackup = true
} else {
    // True first-launch
    kvStore.set(Date(), forKey: "soyeht.first_launch_completed_at")
    isRestoredFromBackup = false
}
```

`NSUbiquitousKeyValueStore` é Apple-native, tem 1MB total quota (mais que suficiente), e propaga via iCloud quando user mantém a same Apple ID entre devices ou reinstall.

**Rationale**: Apple's own apps (Photos, Wallet, Notes) usam similar pattern pra distinguir first-launch da restoration. Sem isso, restored-iPhone vê carrossel de novo + recria onboarding inteiro = experiência ruim.

**Alternatives considered**:
- **Local UserDefaults only**: rejeitado — backup restore preserva UserDefaults, mas wipe + reinstall não. NSUbiquitousKeyValueStore sobrevive ambos.
- **Keychain-bound flag**: rejeitado — keychain restore is opt-in pelo usuário, comportamento variável.

---

## R19 — Wi-Fi vs cellular awareness (FR-123)

**Decision**: usa `NWPathMonitor` (Network framework) pra detectar `currentPath.usesInterfaceType(.cellular)` antes de iniciar download de Soyeht.dmg. Se cellular detected:
- Surface `ProminentConfirmationSheet` com texto FR-123
- Default highlighted button: "Esperar Wi-Fi" (não "Continuar com cellular") — Apple defaults sempre pro caminho mais conservador de dados
- Se user confirma cellular: prossegue + telemetria event (anonimizada) `cellular_download_accepted`

**Apple-grade detail**: ML model interno do iOS aprende que user costuma estar conectado a Wi-Fi específico (home, work). Quando cellular é detectado MAS Wi-Fi conhecido está nearby (`NEHotspotConfigurationManager`), suggest "espere mais 30 segundos — sua rede de casa está chegando" instead.

**Alternatives considered**:
- **No detection (always-allow cellular)**: rejeitado — surpreende usuário com data charge, viola "fluida e perfeita" (Caio's directive).
- **Hard-block cellular**: rejeitado — usuário em viagem pode estar 100% em cellular e não há razão pra bloquear.

---

## R20 — Continuity Camera QR detection animation UX (FR-130)

**Decision**: Mac UI durante webcam QR scan tem 3 estados visuais sequenciais:

1. **Searching** (sem QR detectado ainda): viewport ao vivo, 4 cantos animados pulsando suavemente (each canto cycles `.opacity 0.4 → 1.0` em 1.2s offset 0.3s entre cantos), prompt "Aponte a câmera pro código no seu iPhone"
2. **Acquiring** (QR detectado, decodificando): cantos firmes verde, viewport sutilmente desaturated (`.colorMultiply(.green.opacity(0.85))`), animação de "scan line" horizontal varrendo o QR
3. **Confirmed** (QR completamente decodificado, validado): freeze frame, check-mark animado em `.spring(0.5, 0.7)` aparecendo no centro, transição smooth (cross-fade ≤0.6s) pra Safari abrindo URL

**Rationale**: Apple's Vision Pro Continuity Camera setup faz exatly this 3-stage UX. Imitar mantém familiaridade muscular do usuário Apple.

**Alternatives considered**:
- **Apenas video preview sem feedback de detection**: rejeitado — usuário não sabe se a câmera "viu" o código.
- **Beep audível em vez de visual**: rejeitado — viola FR-118 (no harsh sounds).

---

## Summary

20 decisões fechadas (R1-R20). Todos os `NEEDS CLARIFICATION` resolvidos + qualidade experiencial Apple-grade documentada. Plan apto pra Phase 1+ tasks.
