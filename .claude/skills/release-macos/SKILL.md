---
name: release-macos
description: Publicar uma versão do Soyeht para macOS — archive, DMG notarizado, assinatura Sparkle, appcast e GitHub release. Usar sempre que for publicar/lançar/subir uma versão nova do app macOS, fazer bump de versão para release, ou mexer no appcast.xml. Cada agente redescobre isto do zero; não redescubra.
---

# Publicar o Soyeht para macOS

Não há CI: os workflows foram apagados no #26. Tudo aqui é manual.

## LER PRIMEIRO: `docs/macos-updates.md`

Está no repositório e responde a quase tudo o que se segue — nomes de perfis,
variáveis, caminhos de chaves. Em 2026-08-25 gastei meia hora a vasculhar a
keychain e pedi credenciais ao Caio que já estavam documentadas; o perfil de
notarização chama-se **`soyeht-notary`** e eu procurava por `soyeht`.

Antes de declarar que falta uma credencial, procurar por ela:

```bash
grep -rniE "issuer|notary|keychain-profile|store-credentials" docs/ scripts/
```

## Antes de qualquer coisa

**Nunca tocar no `/Applications/Soyeht.app`.** Publicar gera artefato; quem
atualiza é o utilizador pelo próprio app. O alvo descartável é o
`Soyeht Dev.app`.

**Construir de um clone limpo do `origin/main`**, nunca do diretório de
trabalho. Motivo verificado em 2026-08-25: o diretório principal tinha um
commit local que nunca foi para o GitHub (`3d275e29`), feito por outro agente.
Construir dali teria publicado código não revisto.

```bash
R=/private/tmp/soyeht-release-<versao>
rm -rf "$R" && git clone -q --branch main https://github.com/soyeht/soyeht-ios.git "$R"
cd "$R" && git log --oneline -1        # confirmar que é o merge esperado
```

O clone **não traz** arquivos gitignored. Copiar do diretório principal:
`TerminalApp/Local.xcconfig` (identidade de assinatura estável) e
`.env.release`.

**Cuidado com `git add -A` neste clone.** O `.env.release` e o `appcast.xml`
ficam soltos aqui e carregam, respectivamente, a identidade de assinatura e um
asset que não pertence ao repositório. A 2026-08-25 um `git add -A` meu varreu
os dois para dentro de um commit que chegou a ir para o GitHub; tive que
reconstruir o branch commit a commit para tirá-los. Os dois estão no
`.gitignore` desde então, mas confira `git status` antes de commitar.

## Os passos

### 1. Bump de versão

Duas chaves no `TerminalApp/SoyehtMac.xcodeproj/project.pbxproj`, cada uma
aparece duas vezes (Debug + Release) — as quatro têm de mudar:

```bash
sed -i '' 's/MARKETING_VERSION = 0.1.37;/MARKETING_VERSION = 0.1.38;/g;
           s/CURRENT_PROJECT_VERSION = 42;/CURRENT_PROJECT_VERSION = 43;/g' \
    TerminalApp/SoyehtMac.xcodeproj/project.pbxproj
grep -c "MARKETING_VERSION = 0.1.38\|CURRENT_PROJECT_VERSION = 43" \
    TerminalApp/SoyehtMac.xcodeproj/project.pbxproj    # tem de dar 4
```

`CURRENT_PROJECT_VERSION` é o `sparkle:version` do appcast — o número que o
Sparkle compara. Se não subir, o update não é oferecido.

### 2. Testes — OS DOIS pacotes

```bash
cd Packages/SoyehtCore && swift test
cd TerminalApp/SoyehtMacTests && swift test
```

São **dois pacotes separados** e o segundo é fácil de esquecer. A 2026-08-26
publiquei a 0.1.39 e a 0.1.40 com um teste vermelho no pacote do Mac porque só
rodava o do core. O `xcodebuild` compila esse alvo mas não roda os testes dele,
então build verde não prova nada sobre ele.

### 3. Archive + DMG notarizado

```bash
cd "$R"
xcodebuild archive -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac \
  -configuration Release -archivePath Products/Soyeht.xcarchive \
  -xcconfig TerminalApp/Local.xcconfig
scripts/build-dmg.sh          # export + DMG + notarytool + staple
```

O `build-dmg.sh` lê `.env.release`, que é **gitignored e não existe no clone**
— escrever, três linhas:

```bash
cat > .env.release <<'EOF'
NOTARIZATION_PROFILE=soyeht-notary
EOF
DEV_ID=$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ {print $2; exit}')
echo "DEVELOPER_ID_APPLICATION=$DEV_ID" >> .env.release
echo "TEAM_ID=$(echo "$DEV_ID" | grep -oE '\([A-Z0-9]+\)$' | tr -d '()')" >> .env.release
```

**O perfil `soyeht-notary` já está na keychain desta máquina.** Confirmar com
uma chamada real, não procurando o item:

```bash
xcrun notarytool history --keychain-profile soyeht-notary   # lista submissões
```

Se um dia faltar, a chave está em `~/.soyeht/notary/AuthKey_6MFCQ8AWV5.p8`
(key id `6MFCQ8AWV5`); o issuer id só existe no App Store Connect e recria-se
com `notarytool store-credentials soyeht-notary`. Mas verificar o perfil
primeiro — ele existe.

### 4. Assinatura Sparkle

A chave privada vive na **keychain**, serviço `https://sparkle-project.org`,
conta `soyeht-mac`. Não há ficheiro.

O `sign_update` não está instalado como cask — vem nos artefactos SPM:

```bash
find ~/Library/Developer/Xcode/DerivedData \
     -path "*artifacts/sparkle/Sparkle/bin/sign_update" | head -1
```

```bash
sign_update --account soyeht-mac Products/dmg/Soyeht.dmg
```

Devolve `sparkle:edSignature` e `length`. Confirmar que a chave é a certa:
`generate_keys --account soyeht-mac -p` tem de bater com a chave pública
embutida na app instalada.

### 5. appcast.xml À MÃO

`generate_appcast` **RECUSA** este projeto: o DMG tem 2 bundles.

O appcast **não vive no repositório** — é asset do release, um por tag.
Buscar o anterior como molde:

```bash
curl -sL -o /tmp/ac.xml \
  https://github.com/soyeht/soyeht-ios/releases/download/mac-v0.1.37/appcast.xml
```

Formato (um único `<item>`, sem histórico):

```xml
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Soyeht</title>
        <item>
            <title>0.1.38</title>
            <pubDate>Mon, 25 Aug 2026 12:00:00 +0000</pubDate>
            <sparkle:version>43</sparkle:version>
            <sparkle:shortVersionString>0.1.38</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description sparkle:format="markdown"><![CDATA[...]]></description>
            <enclosure url="https://github.com/soyeht/soyeht-ios/releases/download/mac-v0.1.38/Soyeht.dmg"
                       length="<bytes do DMG>" type="application/octet-stream"
                       sparkle:edSignature="<do sign_update>"/>
        </item>
    </channel>
</rss>
```

A `url` aponta para uma tag que ainda não existe — é resolvida depois do
upload. O `length` tem de ser o tamanho real em bytes do DMG assinado.

**Notas de versão em INGLÊS**, na voz do produto: o que o usuário ganha, não o
que mudou no código.

O Caio definiu isso a 2026-08-25 — o app é internacional. As notas até a 0.1.38
estão em português europeu porque agentes anteriores escreveram assim; da 0.1.39
em diante, inglês. Vale também para mensagem de commit e descrição de PR. Só a
conversa com ele é em português do Brasil.

### 6. Bump por PR — a main é protegida

Push direto na `main` é recusado. O commit de bump vai por PR:

```bash
git checkout -b release/0.1.XX && git commit -am "chore(release): 0.1.XX (build NN)"
git push -u origin release/0.1.XX
gh pr create --title "Release 0.1.XX" --base main --head release/0.1.XX --body "..."
gh pr merge --squash --delete-branch release/0.1.XX
```

Só depois do merge é que a tag pode apontar para o commit certo. Na 0.1.38 eu
criei a tag antes e tive que apagar e refazer.

### 7. Tag e release

```bash
git checkout main && git reset --hard origin/main
git tag -a mac-v0.1.XX -m "Soyeht 0.1.XX" && git push origin mac-v0.1.XX
gh release create mac-v0.1.XX --title "Soyeht 0.1.XX" --notes-file <notas> \
    Products/dmg/Soyeht.dmg appcast.xml
```

Tag **anotada** (`-a`) e título **`Soyeht X.Y.Z`**. A 0.1.38 saiu com tag leve e
título só `0.1.38`, fora do padrão de todas as outras.

### 8. Verificar a ENTREGA, não o ficheiro local

Validar o ficheiro local não prova nada sobre o que o utilizador recebe.

```bash
curl -sL -o /tmp/dl.dmg <url-publica-do-enclosure>
shasum -a 256 /tmp/dl.dmg Products/dmg/Soyeht.dmg     # têm de bater
curl -sL <url-do-appcast> | grep edSignature          # tem de bater com o assinado
spctl -a -t open --context context:primary-signature -v /tmp/dl.dmg
```

## O que costuma correr mal

- **Bump só em Debug ou só em Release.** São quatro ocorrências.
- **`CURRENT_PROJECT_VERSION` esquecido.** O Sparkle compara este número;
  a app instalada não vê a atualização e nada falha visivelmente.
- **`generate_appcast`.** Recusa; é à mão.
- **Procurar o appcast no repositório.** Não está lá, é asset do release.
- **Dar por concluído sem baixar pelo URL público.**
- **Rodar só os testes do core.** São dois pacotes.
- **`git add -A` no clone de release.** Ver o aviso acima.
- **Esta skill não estar no clone.** Ela vive em `.claude/skills/` no
  repositório e o `.gitignore` a permite explicitamente, mas ficou meses sem ser
  commitada — então o clone limpo de onde se publica não a tinha. Se você está
  lendo isto de um clone, ela foi commitada; mantenha assim.
