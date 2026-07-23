---
name: neomorphism-macos
description: Implementar/ajustar neumorphism (soft UI) no app macOS do Soyeht — arquitetura de luz por-card, leis de sombra, técnicas AppKit/CALayer e o workflow de validação por medição de pixels. Usar sempre que mexer no estilo neo (PR3+), em sombras/gradientes do chrome, ou ao portar o estilo pro iOS.
---

# Neumorphism no Soyeht macOS

Conhecimento destilado da implementação do estilo neo (PR #326/#327/#328, jul/2026),
incluindo os becos sem saída — não os repita. Referência de design: `unica.pen`
(nodes `nTscC`, `YzYHW`, `tjIxf`) via pencil MCP.

## As leis (violou, fica feio)

1. **Face do elemento ≈ cor do canvas.** Neumorphism só funciona claro-sobre-claro
   (canvas `#E0E5EC`, face `#E8EDF4`). Tela/card ESCURO sobre canvas claro: sombra
   tingida vira mancha/anel — usar só contraste + ambiente neutro (preto ~10-25%).
   Foi por isso que o Neo Milk virou terminal CLARO (ink `#3E4A66` sobre `#E8EDF4`);
   Midnight é o preset de terminal escuro.
2. **Luz do topo-esquerda, sem exceção.** Escura para baixo-direita, branca para
   cima-esquerda. Em coordenadas de CALayer não-flipado: dark offset `(+d, -d)`,
   light `(-d, +d)`.
3. **Sombras tingidas SÓLIDAS** (opacity ~1 em par canônico): a suavidade vem da COR
   perto do fundo (`#A6B4C8` sobre milk), nunca de alpha baixo. Exceção: overlay de
   luz do grid usa alpha (~0.55/0.65) porque compõe por cima de conteúdo variado.
4. **blur ≈ 1.7–2× offset, escala com o ESPAÇO ao redor** (não com o elemento):
   pills ~34pt → 6/10; cards em grid com corredor ~21pt → 4/9; painel isolado → 9/18;
   o 33/55 do gerador é para objeto-herói solitário. Reach (offset+blur) DEVE caber
   na margem disponível ou a sombra é fatiada com borda reta.
5. **Superfície com gradiente diagonal 145°** (a curvatura): convexo = claro no
   topo-esquerda; côncavo/pressionado = invertido (tab ativa). Tokens:
   `MacTheme.neoConvexStart/End`.

## A arquitetura de luz do grid (a lição mais cara)

**Ilumine CARDS, nunca corredores.** Três gerações que falharam, com prova por medição:

- Sombra por-pane: clipa na fronteira do slot → bandas chapadas com degrau (26 un).
- Corredor-retângulo com gradiente opaco: 3 faixas coladas (`#EDF0F4|#E0E5EC|#D0D7E2`).
- Corredor com alpha + fade nas pontas: a borda TRANSVERSAL do retângulo ainda liga
  o tint de uma vez (degrau 15).

**O que funciona** (`GridLightingView` em `PaneGridController.swift`): UM overlay
sobre o grid inteiro desenha, por card visível, sombra escura + bloom branco como
sombras 2D de rounded-rect (`layer.shadowPath`, sem body), cada uma **mascarada do
próprio caster** (CAShapeLayer evenOdd: bounds gigante + path do card) mas livre
para cair em vizinhos e canvas. Junções em T = sobreposição natural de sombras;
degrau medido caiu para 5 un (imperceptível). Specs atuais: dark `#A6B4C8` 0.55
(4,-4)/9, bloom branco 0.65 (-4,4)/9, card radius 20, margem do card 12.
Atualiza em layout E em `NSSplitView.didResizeSubviewsNotification`.

## Técnicas AppKit essenciais

- **Múltiplas sombras**: CALayer tem 1 sombra. `MacStyledSurfaceView` empilha N
  sublayers de sombra + surface (CAGradientLayer p/ gradiente) + `passesThroughHits`
  para backdrops cosméticos atrás de botões.
- **Inner shadow (inset do gerador)**: truque do anel clipado — CAShapeLayer evenOdd
  (rect gigante + rounded rect), fill clipado fora, só a sombra cai pra dentro
  (`MacInnerWellShadowView`).
- **NSSplitViewController**: NUNCA trocar/subclassear o splitView (nem antes de
  `super.loadView()`) — quebra addSplitViewItem e a área fica vazia. A linha de 1px
  do divider é desenhada por uma view interna ACIMA de tudo: para escondê-la,
  aninhe uma strip cor-do-canvas DENTRO dela (acompanha drag de graça).
- **Gap entre panes**: inset por-pane (root transparente → card → clip), nunca
  divider grosso. `insetBy` em bounds zero → rect negativo mata o autoresizing
  (guard + re-aplicar em `viewDidLayout`).
- **Anti-alias de canto**: a camada-base sob conteúdo clipado deve ser CLARA
  (cor do header) — base escura vaza 1px no canto arredondado como risquinho.
- Sobre conteúdo escuro (sidebar/drawer sobre panes): sombra AMBIENTE neutra
  (preto ~30%), nunca o par tingido (vira borrão).

## Workflow de validação (inegociável)

1. Build Debug → `rm -rf "/Applications/Soyeht Dev.app" && ditto <build> && open`
   (Dev é descartável; NUNCA tocar no Soyeht.app de produção). Se rodar direto do
   DerivedData, `nohup .../MacOS/Soyeht Dev` — `open` pode reusar instância velha.
2. Screenshot por window-id: `screencapture -o -x -l <WID>`; WID via Quartz
   (CGWindowListCopyWindowInfo) — coordenadas de tela mentem (janela se move).
3. **Medir, não olhar**: PIL, run-length de uma varredura de pixels cruzando a
   região (`itertools.groupby`) + métrica MAX-STEP (maior delta entre pixels
   vizinhos). Degrau > ~8 unidades dentro de canvas = emenda visível = reprovado.
   Borda de card com degrau é correto (objeto real).
4. Comparar com o RENDER do Pencil (`get_screenshot` do node), não só com os
   números dele — e medir o render também (o Caio mede!).
5. Regressão classic a cada mudança: `defaults write com.soyeht.mac.dev
   soyeht.design.style classic` + tema `soyehtDark` → deve ficar pixel-idêntico
   ao app de hoje (tokens classic = valores históricos).

## Onde vive cada coisa

- Tokens de forma/sombra por estilo: `TerminalApp/SoyehtMac/MacSurface.swift`.
- Cores neo (+gradientes, pastéis de header): `MacTheme.swift`; derivação
  compartilhada: `SoyehtCore/Theme/NeoStyleColors.swift` + `HexColorMath.swift`.
- Presets com chrome≠terminal: `DesignStylePresets.swift` via `extraHexColors`
  com chaves reservadas `app.*` (palette do chrome) e `neo.*` (papéis neo).
- Estilo ativo/gating: `SoyehtCore/Theme/DesignStyle.swift` (`available` esconde
  estilos não-prontos; downgrade cai pro classic).
- Fontes: Nunito bundlada (OFL) só pro chrome neo via `nsChromeFont`; terminal e
  título de pane ficam JetBrains Mono (título: mono 11-12 bold tintado — contraste
  proposital do design).
