# Fixture isolada para aprovação pelo Mac

## Objetivo e limite

Provar G numa casa nova cujo dono foi criado pelo Mac pelo fluxo autenticado
existente. A casa Dev atual continua sendo a fixture negativa de Mac sem sessão.
Não importar sessão, chave ou certificado; não reabrir first-owner numa casa
existente. A fixture positiva só vale após `owner_capability=proven` e aprovação
seguida de validação e persistência no iPhone.

Na elaboração inicial, não havia outro Mac/VM disponível. Uma cópia de Dev.app e outra porta não isolam
Keychain, registro local, instalação nem limpeza. Esta fixture precisa de um
terceiro perfil explícito de ponta a ponta, `pairingqa`. Não é uma flag que dá
autoridade ao Mac: a verificação da assinatura e a cerimônia permanecem iguais.

## Namespace proposto

| Recurso | Fixture |
|---|---|
| Mac / iPhone | `com.soyeht.mac.pairingqa` / `com.soyeht.app.pairingqa` |
| Extensões do iPhone | sob `com.soyeht.app.pairingqa.` |
| Perfil no protocolo | `pairingqa`, bootstrap `8111` |
| Admin | loopback `8912` |
| Application Support | `SoyehtPairingQA` |
| Estado legado | `.theyos-pairingqa` |
| LaunchAgent | `com.soyeht.engine.pairingqa` |
| Keychain Mac / mobile | `com.soyeht.mac.pairingqa` / `com.soyeht.mobile.pairingqa` |
| Sessão da casa | `com.soyeht.household.pairingqa` |
| Chave do dono | `com.soyeht.household.pairingqa.owner` |
| Logs | `~/Library/Logs/SoyehtPairingQA/engine.log` |
| Wrapper log | `/tmp/soyeht-pairingqa-engine.log` |
| Registro local | `soyeht-local-reg-pairingqa-<euid>/owner-webauthn.sock` |
| VM socket | `/tmp/soyeht-pairingqa-vmrunner.sock` |
| Session DB | dentro de `SoyehtPairingQA` |
| Grupo iOS | `group.com.soyeht.mobile.clawshare.pairingqa` |
| Grupo Keychain da extensão | `com.soyeht.mobile.clawshare.mesh.pairingqa` |

Os números são reserva lógica, não prova de disponibilidade: o preflight deve
recusar portas ocupadas. Nunca parar o ocupante. Também deve recusar diretórios
ou sockets que resolvam por symlink para outro namespace.

## Fronteiras que precisam mudar juntas

1. `SoyehtInstallProfile`: resolução exata do bundle e de suas extensões;
   disjunção de todos os identificadores com release e Dev. Os testes atuais
   dos valores de release e Dev continuam válidos.
2. Engine: `PairingInstallation`, bundle do App Attest, diretórios e portas.
   O registro local deve escolher tanto o UDS quanto a designated requirement
   do Mac QA. Hoje `household_bootstrap` escolhe Dev pelo componente exato
   `SoyehtDev`; o listener e o cliente têm namespaces próprios que também
   precisam acompanhar. Não ampliar o verifier para aceitar qualquer bundle.
3. Builds: Mac e iOS QA têm identificadores efetivos próprios, inclusive
   extensões, entitlements, grupos e preferências. Uma mudança apenas no nome
   exibido não conta. Assinatura/provisionamento para o novo bundle iOS é uma
   pré-condição de execução ainda não comprovada; build unsigned não a prova.
4. Instalação: plist/env completos e lidos de volta do artefato. Nenhuma
   integração automática com agentes/MCP, Homebrew, atualização Sparkle ou
   limpeza global na fixture. O uninstaller atual remove recursos de ambos
   os perfis; não deve ser usado para limpar QA.
5. iOS: descoberta, convite, seleção e persistência consomem a mesma identidade
   QA. Não relaxar comparação de perfil nem inferir perfil por porta. QA×Dev
   e QA×release precisam falhar antes do claim.

## Verificação antes de liberar a faixa

- Testes de disjunção e ownership dos três perfis: paths, serviços, tags,
  sockets, labels e portas; controles negativos com uma colisão por categoria.
- Teste cruzado Swift/Rust para perfil e registro local: o contrato deve ser
  lido do outro checkout, sem duplicar fixtures que poderiam discordar.
- Readback dos dois bundles e do plist: identificadores, entitlements,
  caminhos, portas, assinatura e revisão do código. Número de versão não basta.
- Preflight somente de leitura compara os artefatos com o contrato; qualquer
  ausência, erro de leitura ou colisão recusa execução. Não cria casa, não
  consulta conteúdo secreto do Keychain, não reinstala nem executa bootout.
- A faixa de Blaire verifica processo/FDs/ports do engine QA após o início e
  continuidade dos engines existentes. Um manifesto estático sozinho não
  prova que o processo obedeceu ao namespace.

## Corridas

1. Pelo fluxo real, criar a casa no Mac QA e comprovar sua capacidade de dono.
2. iPhone QA sem casa, sem tailnet: descobrir, pedir, comparar o digest das
   palavras, aprovar no Mac, validar certificado e persistir no iPhone.
3. Repetir com tailnet; conferir o endereço persistido e a reconexão, não só
   descoberta ou aceitação do engine.
4. Rejeitar convites cruzados e executar os controles negativos da sonda.
5. Manter M3 longo na casa Dev existente como teste independente de expiração.

O log novo `pair.request.post host=<host> port=<port>` é emitido no cliente
HTTP de device-pairing ao entregar o request ao URLSession. Ele prova o destino
inicial escolhido para o POST, não recepção no servidor, ausência de redirects
nem conclusão da cerimônia. O subsystem é `com.soyeht.mobile`, categoria
`device-pairing`; não inclui body, autorização, request token ou query.

## Estado

Implementação suspensa em 2026-09-06: um segundo Mac ficou disponível na LAN,
segundo a faixa E2E. O caminho preferido passa a ser usar os builds Dev normais
nessa máquina; o acesso ainda depende do usuário. Este documento fica como
alternativa, sem implementação autorizada enquanto essa opção é verificada.

Uma máquina separada isola os recursos locais, mas não prova estado Dev vazio
nem isola descoberta na LAN. Antes de criar a casa, a faixa deve verificar o
estado existente e preservar qualquer casa já estabelecida. O cenário positivo
precisa comprovar que o Mac criou a casa e possui a capacidade de aprovação.
As fitas devem identificar qual Mac/engine recebeu o pedido: ambos os Macs
podem anunciar o mesmo perfil Dev e a mesma porta. O isolamento de perfil não
seleciona uma máquina entre duas do mesmo perfil.

Nenhuma instância QA está liberada com este documento. O log de envio é uma correção independente.
Uma fixture positiva não substitui a matriz do fluxo ordinário em que o dono
está no iPhone, nem demonstra recuperação de uma chave ausente.
