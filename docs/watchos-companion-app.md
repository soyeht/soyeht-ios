# watchOS Companion App — soyeht

> App companion para Apple Watch: monitoramento de instancias, comandos por voz, e notificacoes em tempo real.

---

## User Stories

> Padrao de uso: **glance → assess → act (or ignore)**. O Watch nao substitui o terminal — ele e o "radar" que mantem o usuario informado e permite micro-intervencoes sem tirar o celular do bolso.

### Longe do computador

- **"Hey Siri, meus servidores estao de pe?"** — olhada rapida no status das instancias enquanto caminha
- **"Mostra os workspaces do picoclaw-01"** — verificar se aquele deploy que deixou rodando ainda esta ativo
- **"Quantas sessoes estao abertas?"** — complicacao no watch face, sem abrir nada

### Monitoramento passivo (notificacoes)

- *Vibra no pulso:* "deploy.sh finished (exit 0) em picoclaw-01" → toca "Ver Output"
- *Vibra no pulso:* "ERROR: out of memory em picoclaw-02" → toca "Reexecutar" ou "Ver Output"
- *Vibra no pulso:* "picoclaw-03 went offline" → sabe que precisa investigar
- *Vibra no pulso:* "workspace 'dev' idle ha 2h" → toca "Encerrar" pra liberar recurso

### Comandos rapidos do dia a dia

- **"Hey Siri, soyeht run git status"** — ver se tem algo pendente no repo
- **"Hey Siri, soyeht run docker ps"** — verificar containers rodando
- **"Hey Siri, soyeht deploy staging"** — disparar deploy do pulso
- **"Hey Siri, soyeht restart nginx"** — reiniciar servico de emergencia

### Reacoes rapidas (recebeu notificacao, age na hora)

- Recebeu alerta de erro → **dita: "tail -20 /var/log/app.log"** → ve as ultimas linhas
- Build falhou → **toca "Reexecutar"** direto na notificacao
- Processo travou → **dita: "kill -9 1234"** ou toca quick command "kill last"
- Servidor lento → **dita: "top -n 1"** → ve resumo de CPU/memoria

### Na academia / corrida

- Olha o pulso, ve complicacao: "3 instances - all healthy" → tranquilo
- Vibra: "CI pipeline finished — all tests passed" → continua o treino
- Vibra: "CI failed — 3 tests broken" → sabe que vai ter que resolver depois

### Em reuniao (nao pode pegar o celular)

- Olhada discreta no pulso: instancias ok? workspaces ativos?
- Vibra baixinho: deploy terminou → da um check mental, continua a reuniao
- Toque rapido: "git pull && npm run build" no workspace remoto

### De madrugada (oncall)

- Vibra forte: "CRITICAL: database connection lost em picoclaw-01"
- No Watch: toca "Ver Output" → ve mensagem de erro
- Dita: "systemctl restart postgresql" → resolve sem levantar da cama
- Confirma: `capture-pane` mostra "postgresql started" → volta a dormir

### Quick Commands favoritos (configurados no iPhone)

```
▶ git status
▶ docker ps
▶ df -h
▶ free -m
▶ tail -5 /var/log/syslog
▶ deploy staging
▶ restart app
```

---

## Visao Geral

O Apple Watch nao suporta terminal completo (tela pequena, sem teclado), mas funciona bem como **companion app** para:

1. **Status das instancias** — ver quais instancias estao ativas no pulso
2. **Comandos por voz** — executar comandos pre-definidos ou ditados por voz
3. **Notificacoes** — alertas de erro, deploy concluido, processo finalizado
4. **Complicacoes** — status resumido direto no watch face

---

## Arquitetura

```
┌─────────────────────────────────────────────────┐
│                   Apple Watch                    │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ Complica- │  │ Voice    │  │ Notifications │  │
│  │ tions     │  │ Commands │  │               │  │
│  └─────┬─────┘  └─────┬────┘  └───────┬───────┘  │
│        │              │               │          │
│        └──────────┬───┘───────────────┘          │
│                   │                              │
│          ┌────────▼────────┐                     │
│          │ WatchSoyehtAPI  │                     │
│          │ (URLSession)    │                     │
│          └────────┬────────┘                     │
└───────────────────┼──────────────────────────────┘
                    │ HTTPS
                    ▼
         ┌─────────────────────┐
         │  soyeht Backend     │
         │  /api/v1/...        │
         └─────────────────────┘
```

O Watch se comunica **direto com o backend** via HTTPS (nao depende do iPhone estar por perto, desde que tenha Wi-Fi ou celular).

---

## Funcionalidades

### 1. Dashboard de Instancias

**Tela principal** — lista compacta das instancias ativas.

```
┌──────────────────────┐
│  soyeht        12:30 │
│                      │
│  ● picoclaw-01       │
│    2 workspaces      │
│                      │
│  ● picoclaw-02       │
│    1 workspace       │
│                      │
│  ○ picoclaw-03       │
│    offline           │
└──────────────────────┘
```

**Endpoints usados:**
- `GET /api/v1/mobile/instances` — listar instancias
- `GET /api/v1/terminals/{container}/workspaces` — contar workspaces por instancia

**Ao tocar numa instancia** — mostra workspaces com status e acoes rapidas.

---

### 2. Comandos por Voz

Tres formas de entrada de voz no watchOS:

#### a) Ditado nativo (Speech-to-Text)

O watchOS oferece `presentTextInputController` que abre o teclado de ditado nativo. O usuario fala o comando e o Watch converte pra texto.

```swift
// SwiftUI — watchOS 9+
TextField("Comando...", text: $command)
    .onSubmit {
        executeCommand(command)
    }

// Ou usar dictation diretamente
func startDictation() {
    // watchOS abre interface de ditado automaticamente
    // quando o usuario toca no TextField
}
```

**Fluxo:**
1. Usuario toca "Executar Comando" no Watch
2. watchOS abre interface de ditado
3. Usuario fala: "git status"
4. Watch envia comando pro backend
5. Mostra output resumido (primeiras linhas)

**Endpoint para enviar comando:**
```
POST /api/v1/terminals/{container}/workspace
→ abre/reusa workspace

WS wss://{host}/api/v1/terminals/{container}/pty?session={id}&token={token}
→ envia comando via WebSocket
→ le resposta (primeiros N bytes)
→ fecha conexao
```

**Alternativa sem WebSocket (mais simples para v1):**
```
POST /api/v1/terminals/{container}/tmux/send-keys
Body: { "session": "workspace-name", "keys": "git status\n" }

GET /api/v1/terminals/{container}/tmux/capture-pane?session=workspace-name
→ retorna output do pane (texto)
```

> Nota: `send-keys` + `capture-pane` e mais simples que WebSocket para comandos one-shot no Watch. O backend ja tem `capture-pane`.

#### b) Siri / App Shortcuts

Usando **App Intents** (iOS 16+ / watchOS 9+), o usuario pode criar atalhos de voz:

```swift
struct RunCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Soyeht Command"
    static var description = IntentDescription("Execute a command on a soyeht instance")

    @Parameter(title: "Command")
    var command: String

    @Parameter(title: "Instance")
    var instance: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$instance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = WatchSoyehtAPI.shared
        let output = try await api.executeCommand(
            command: command,
            instance: instance ?? api.defaultInstance
        )
        return .result(dialog: "Output: \(output.prefix(200))")
    }
}

struct SoyehtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "Run \(\.$command) on soyeht",
                "Execute \(\.$command) on \(\.$instance)",
                "Soyeht run \(\.$command)"
            ],
            shortTitle: "Run Command",
            systemImageName: "terminal"
        )
    }
}
```

**Exemplos de uso:**
- "Hey Siri, soyeht run git status"
- "Hey Siri, execute deploy on picoclaw-01"

#### c) Comandos Pre-definidos (Quick Actions)

Lista de comandos favoritos configurados pelo usuario no iPhone, sincronizados via Watch Connectivity ou API.

```
┌──────────────────────┐
│  Quick Commands       │
│                      │
│  ▶ git status        │
│  ▶ docker ps         │
│  ▶ tail -f logs      │
│  ▶ deploy staging    │
│                      │
│  + Add Command       │
│                      │
│  🎤 Dictate...       │
└──────────────────────┘
```

**Ao tocar num comando:**
1. Envia via `send-keys` para o workspace ativo
2. Espera 1-2s
3. Faz `capture-pane` e mostra output resumido
4. Haptic feedback de sucesso/erro

---

### 3. Notificacoes

**Push notifications** para eventos importantes via APNs.

| Evento | Exemplo |
|---|---|
| Processo terminou | "deploy.sh finished (exit 0)" |
| Erro detectado | "ERROR in build.log" |
| Instancia offline | "picoclaw-01 went offline" |
| Workspace idle | "workspace 'dev' idle for 30min" |

**Implementacao:**
- Backend envia push via APNs quando detecta evento
- Watch recebe e mostra notificacao com acoes inline
- Acoes: "Ver Output", "Reexecutar", "Ignorar"

```swift
// Notification category com acoes
let viewAction = UNNotificationAction(
    identifier: "VIEW_OUTPUT",
    title: "Ver Output"
)
let rerunAction = UNNotificationAction(
    identifier: "RERUN",
    title: "Reexecutar"
)
let category = UNNotificationCategory(
    identifier: "COMMAND_FINISHED",
    actions: [viewAction, rerunAction],
    intentIdentifiers: []
)
```

**Requisito no backend:**
- Endpoint para registrar device token APNs: `POST /api/v1/mobile/push-token`
- Servico de push que monitora eventos e envia notificacoes

---

### 4. Complicacoes (Watch Face)

Mostram info resumida direto no watch face, sem abrir o app.

| Tipo | Conteudo |
|---|---|
| Circular | Numero de instancias ativas (ex: "3") |
| Rectangular | "picoclaw-01: 2 ws" |
| Inline | "soyeht: 3 active" |

```swift
struct SoyehtComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "SoyehtStatus",
            provider: StatusProvider()
        ) { entry in
            VStack {
                Text("\(entry.activeCount)")
                    .font(.title)
                Text("instances")
                    .font(.caption2)
            }
        }
        .configurationDisplayName("Soyeht Status")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
```

**Atualizacao:** Timeline refresh a cada 15min via `TimelineProvider`, ou push-triggered via `WidgetCenter.shared.reloadAllTimelines()`.

---

## Stack Tecnica

| Componente | Tecnologia |
|---|---|
| UI | SwiftUI (watchOS 9+) |
| Networking | URLSession (requests diretos ao backend) |
| Auth | Token compartilhado via Keychain (App Group) |
| Voz | Ditado nativo + App Intents (Siri) |
| Notificacoes | APNs + UNUserNotificationCenter |
| Complicacoes | WidgetKit (watchOS 9+) |
| Sync iPhone↔Watch | Watch Connectivity (config/favoritos) |
| Persistencia local | SwiftData ou UserDefaults |

---

## Compartilhamento de Codigo com iOS

```
iSoyehtTerm/
├── Shared/                          # Codigo compartilhado iOS + watchOS
│   ├── SoyehtAPIClient.swift        # Mover de iOSTerminal/ para ca
│   ├── Models/
│   │   ├── SoyehtWorkspace.swift
│   │   ├── TmuxWindow.swift
│   │   └── Instance.swift
│   └── SessionStore.swift           # Keychain + token management
│
├── TerminalApp/
│   ├── iOSTerminal/                 # App iOS (terminal completo)
│   └── MacTerminal/                 # App macOS (terminal completo)
│
├── WatchApp/
│   ├── WatchApp.swift               # Entry point
│   ├── Views/
│   │   ├── DashboardView.swift      # Lista de instancias
│   │   ├── WorkspaceListView.swift  # Workspaces por instancia
│   │   ├── QuickCommandsView.swift  # Comandos pre-definidos
│   │   └── CommandOutputView.swift  # Output resumido
│   ├── Intents/
│   │   ├── RunCommandIntent.swift   # Siri "run X on soyeht"
│   │   └── SoyehtShortcuts.swift    # App Shortcuts provider
│   ├── Complications/
│   │   └── StatusWidget.swift       # Watch face complication
│   └── WatchApp.xcodeproj
│
└── Package.swift                    # SwiftTerm (iOS/macOS only)
```

**O que pode ser reusado do iOS:**
- `SoyehtAPIClient` — todas as chamadas REST (mover para `Shared/`)
- `SessionStore` — gerenciamento de token/keychain
- Models — `SoyehtWorkspace`, `TmuxWindow`, `Instance`

**O que e exclusivo do Watch:**
- UI (SwiftUI compacta pro watch)
- App Intents / Siri integration
- Complicacoes
- Logica de `send-keys` + `capture-pane` (comando one-shot)

---

## Fases de Implementacao

### Fase 1 — MVP (companion basico)
- [ ] Criar WatchApp target no Xcode
- [ ] Extrair `SoyehtAPIClient` e models para `Shared/`
- [ ] Dashboard: listar instancias e workspaces
- [ ] Compartilhar token via Keychain App Group
- [ ] Complicacao simples (count de instancias)

### Fase 2 — Comandos por Voz
- [ ] Quick Commands (lista pre-definida)
- [ ] Ditado de voz → `send-keys` + `capture-pane`
- [ ] Mostrar output resumido no Watch
- [ ] Haptic feedback

### Fase 3 — Siri e Notificacoes
- [ ] App Intents + App Shortcuts
- [ ] Push notifications (requer backend: APNs service)
- [ ] Acoes inline nas notificacoes
- [ ] Background App Refresh para complicacoes

### Fase 4 — Polish
- [ ] Watch Connectivity (sync favoritos com iPhone)
- [ ] Historico de comandos recentes
- [ ] Temas/aparencia consistente com iOS
- [ ] Complicacoes avancadas (ultimo comando, status detalhado)

---

## Endpoints Necessarios no Backend (novos)

| Endpoint | Necessario para | Fase |
|---|---|---|
| `POST /api/v1/terminals/{container}/tmux/send-keys` | Enviar comando sem WebSocket | 2 |
| `POST /api/v1/mobile/push-token` | Registrar device pra push | 3 |
| Push notification service (APNs) | Enviar alertas pro Watch | 3 |

> Todos os demais endpoints ja existem e serao reusados do iOS.
