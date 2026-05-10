# Copy Voice Guide — Soyeht Onboarding

> T129 — FR-119 compliance. Governs tone and vocabulary for all onboarding screens,
> error states, and notifications. Used by CopyVoiceAuditor (T039a) in CI.

---

## Tone Principle

**"Amigo paciente, não burocrático."**

Soyeht is an invisible engine. Onboarding language should feel warm, unhurried, and
trust-building — never bureaucratic, never alarm-inducing. The user is setting up
something powerful; the app's job is to make that feel simple and safe.

---

## Banned Vocabulary

The following words and patterns are blocked. CopyVoiceAuditor flags them in CI.

### Error & Status Terms (FR-119)

| ❌ Banned | ✅ Preferred |
|-----------|-------------|
| erro | algo deu errado / não conseguimos |
| falha | não funcionou |
| problema | algo inesperado / pode tentar de novo |
| inválido | não reconhecemos / formato diferente |
| rejeitado | não foi possível / vamos tentar de novo |
| aguarde | um momento... |
| carregando | — (omit; use progress indicator) |
| processando | trabalhando nisso |

### Presentation & UX (FR-119)

| ❌ Banned | ✅ Preferred |
|-----------|-------------|
| sucesso | ✓ pronto / feito / tudo certo |
| concluído | pronto |
| operação | — (always rephrase around the outcome) |
| configuração | setup / preparar (context-dependent) |
| instalação (as noun) | instalar / colocar |

### Tone Patterns

| ❌ Avoid | Why |
|---------|-----|
| "Por favor, ..." | Sounds bureaucratic — just say what to do |
| "Você precisa de ..." | Creates obligation; rephrase as benefit |
| "Erro ao ..." / "Falha ao ..." | Alarm language; use passive or soft phrasing |
| Triple exclamation "!!!" | Reserved. Max 1 exclamation per screen, max 3 per flow |
| Emoji in error states | Confusing or dismissive — only in success moments |

---

## Preferred Substitutions by Context

### Onboarding entry
- "Boas-vindas" → "Oi" or context greeting (no formal welcome header)
- "Vamos começar" → "Tá" / "Pronto pra começar?"

### Pairing flow
- "Autorizar" → "Deixar entrar"
- "Autenticar" → — (never surface to user)
- "Confirmar dispositivo" → "Reconhecer o Mac"

### Installation
- "Instalando..." → "Preparando o motor..."
- "Instalação completa" → "Tudo pronto."
- "Falha na instalação" → "Não conseguimos instalar. Vamos tentar de novo?"

### Recovery / safety
- Never "Se algo der errado" — leads with failure
- Use "Se você trocar de iPhone" / "Se um dia você perder o iPhone"
- Avoid "backup" — use "recuperar" or "outra cópia"
- "Suas chaves ficam seguras" is approved phrasing (FR-050)

### Error states
- "Tente novamente" → "Pode tentar de novo"
- "Sem conexão" → "Sem internet no momento"
- "Tempo limite esgotado" → "Demorou mais do que o esperado. Pode tentar de novo?"

---

## Exclamation Policy

- Max **1** exclamation point per screen
- Max **3** per complete onboarding flow
- Approved use: first success moment ("Tudo pronto!"), first morador confirmation
- Never in: error states, informational screens, warnings

---

## Emoji Policy

- Approved in success moments: checkmark ✓ (system SF Symbol, not emoji character)
- No emoji in: error messages, warnings, navigation labels
- No emoji in: locales ar, ur (right-to-left cultural norms)
- Decorative SF Symbols (`.accessibilityHidden(true)`) are not subject to this policy

---

## Screen-Specific Voice Notes

### InstallPickerView (PB1)
- "Meu Mac" not "Para Mac" — possession signals home ownership
- Linux badge: "Em breve" not "Não disponível" or "Beta"

### ProximityQuestionView (PB2)
- "Sim, estou no Mac" — first person, confirms the user is present
- "Vou fazer mais tarde" — no guilt, no urgency

### LaterParkingLotView (PB4 — "Sem pressa")
- Title period is intentional: "Sem pressa." — lands as a calm statement
- No "Você pode instalar depois" (obligation); use "Quando você tiver um Mac por perto"

### RecoveryMessageView (T110)
- Title "Boa notícia." — period intentional, warm opening
- Body approved: "Suas chaves ficam seguras — não dependem de nenhum dispositivo sozinho"
- Never: "Não se preocupe" (implies there is something to worry about)

### Error / AwaitingMac timeout
- "Não encontramos o Mac ainda. Vamos tentar de novo?" — soft, non-accusatory
- Never: "Mac não encontrado" (reads as failure, not state)

### NoCasaBanner
- "Sua casa ainda não está configurada" — factual, not alarmist
- "Toque para configurar agora" — action-oriented, no urgency pressure

---

## CopyVoiceAuditor Integration

`CopyVoiceAuditor` (T039a) consumes the banned words list above and:
- Scans all `defaultValue:` strings in Swift source for banned patterns
- Produces structured report with `file:line` citations
- CI gate: PR fails if any banned word found in new/modified strings

The auditor does NOT scan:
- Code identifiers (variable names, function names)
- Comment text
- `comment:` fields in `LocalizedStringResource` calls (translator notes)

---

## Cultural Review Notes (FR-140)

| Locale | Reviewer notes |
|--------|----------------|
| pt-BR  | Canonical — all copy authored here first |
| pt-PT  | "Instalar" acceptable; avoid BR slang like "tá" in formal contexts |
| ar     | Review imperative constructs — soften where culturally cold |
| hi     | Formal register ("आप") appropriate; avoid imperative-only sentences |
| ja     | Avoid direct "you" subject — often omitted in JA naturally |

---

*Last updated: 2026-05-09. Source of truth for CopyVoiceAuditor CI gate.*
