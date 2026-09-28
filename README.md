# Cunha Tools

Suíte de utilitários para macOS. O app **Cunha Tools** instala, atualiza, remove e configura cada utilitário (tool). As tools vêm embutidas nele.

A versão atual traz uma tool: o **Sound Manager**, que controla o volume de cada app, de cada aba do Chrome e do Mac inteiro, pela barra de menus.

<img src="docs/cunha-tools.png" alt="Janela do Cunha Tools com o card do Sound Manager" width="600">

## Sound Manager

O ícone de alto-falante fica na barra de menus. O clique abre o volume geral do Mac e a lista dos apps que estão tocando som.

<img src="docs/sound-manager.png" alt="Menu do Sound Manager com volume geral e três apps" width="360">

| Controle | O que faz |
|---|---|
| Volume geral | Volume e mudo do dispositivo de saída padrão. Acompanha as teclas de volume do Mac e a troca de dispositivo |
| Volume por app | Slider e mudo para cada app que toca som. O app guarda o valor de cada app entre aberturas |
| Volume por aba | No Chrome e em navegadores Chromium, slider e mudo para cada aba. Exige a extensão incluída no app |
| Abrir ao iniciar o Mac | Liga ou desliga a abertura automática no login |

### O volume geral é o teto

O volume efetivo de um app é o menor valor entre o volume do app e o volume geral.

- Mexer num app nunca altera o volume geral.
- Um app arrastado acima do volume geral para no volume geral.
- Um clique perto da ponta da trilha leva a 0% ou a 100%.
- Baixar o volume geral limita os apps que estão acima dele. O valor salvo de cada app se mantém. Quando o volume geral sobe de novo, cada app volta ao valor salvo.
- No slider do app, a trilha acima do teto fica esmaecida, e um marcador mostra o teto. O percentual mostra o volume efetivo.
- O volume por aba é relativo ao volume do app.

### Como funciona

- O Sound Manager usa os *process taps* do Core Audio (macOS 15). Para cada app abaixo de 100%, o Sound Manager cria um tap que silencia o som original do app, aplica o ganho e toca o resultado no dispositivo de saída, por um dispositivo agregado.
- Um app com volume próprio mantém o tap mesmo quando fica no teto. Assim, subir o volume geral só troca o ganho, sem esperar um tap novo.
- Um app que volta a 100% perde o tap 2 s depois. O áudio dele volta ao caminho normal do macOS.
- No dispositivo com volume próprio (ex.: alto-falantes do Mac), o ganho segue a curva de dB do próprio dispositivo. Um app em 30% soa igual ao dispositivo em 30%.
- No dispositivo sem volume próprio (HDMI, alguns DACs), o volume geral funciona por software. A legenda do volume geral mostra "por software".
- A extensão do navegador ajusta o volume dentro da página e conversa com o app por WebSocket em `ws://127.0.0.1:47821`.

As regras completas do teto e dos dois tipos de dispositivo estão em [`tools/sound-manager/README.md`](tools/sound-manager/README.md).

### Privacidade

- O áudio é processado no Mac. O Sound Manager não grava áudio em disco e não abre conexão de rede externa.
- A única porta aberta é `127.0.0.1:47821`, só na interface local. O app aceita só conexões com origem de extensão de navegador.
- A permissão "Gravação de áudio do sistema" existe porque o tap precisa ler o áudio de cada app para aplicar o volume.

## Instalação

### Requisitos

- macOS 15 ou superior.
- Command Line Tools da Apple: `xcode-select --install`. O Xcode não é necessário.

### Build e instalação

```sh
git clone https://github.com/mcunha12/cunha-tools.git
cd cunha-tools
./scripts/build-suite.sh
open "build/Cunha Tools.app"
```

Na janela do Cunha Tools, clique em **Instalar** no card do Sound Manager. A tool vai para `/Applications` e abre.

Para instalar só o Sound Manager, sem o gerenciador: `./scripts/install.sh tools/sound-manager`.

O primeiro build cria a identidade de assinatura local "Cunha Tools Local Signing" num keychain próprio, `~/Library/Keychains/cunhatools-signing.keychain-db`, e o adiciona à lista de keychains do usuário. Com a mesma identidade, o macOS mantém as permissões entre builds.

### Primeira abertura

1. O macOS pede a permissão "Gravação de áudio do sistema". Clique em **Permitir**. Sem ela, o volume por app não funciona. O volume geral de um dispositivo com volume próprio funciona sem ela.
2. Aberto a partir de `/Applications` ou `~/Applications`, o Sound Manager se registra para abrir no login. O checkbox "Abrir ao iniciar o Mac", no rodapé do menu, desliga o registro.

Os apps não são notarizados pela Apple. Copiados para outro Mac, a primeira abertura é bloqueada. Para liberar: Ajustes do Sistema → Privacidade e Segurança → **Abrir Mesmo Assim**. Alternativa no Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Cunha Tools.app"
```

### Volume por aba no Chrome

1. No menu do Sound Manager, clique na seta ao lado do Google Chrome.
2. Clique em **Instalar extensão**. O Finder abre a pasta da extensão, o caminho vai para a área de transferência e o Chrome abre `chrome://extensions`.
3. Ative o **Modo do desenvolvedor**, no canto superior direito.
4. Clique em **Carregar sem compactação** e escolha a pasta. Na janela de escolha, `Cmd+Shift+G` e `Cmd+V` colam o caminho.
5. Recarregue as abas que já estavam abertas.

### Distribuir em DMG

```sh
./scripts/build-suite.sh
./scripts/make-dmg.sh
```

O resultado é `build/CunhaTools-<versão>.dmg`, com o atalho para Aplicativos e o guia [`dist/Como instalar.txt`](dist/Como%20instalar.txt).

## Limites

- Controle por aba: só Chrome e navegadores Chromium (Brave, Edge, Arc, Vivaldi, Opera). O Safari exige uma Safari Web Extension, e o build dela exige o Xcode. O Firefox não tem suporte.
- Páginas `chrome://` e a Chrome Web Store bloqueiam extensões. Nelas, só o mudo funciona.
- O volume por aba vale para abas carregadas depois da instalação da extensão, ou recarregadas.
- Com um app abaixo de 100%, o áudio dele passa pelo dispositivo agregado e ganha latência. O valor não foi medido.
- Os apps não são notarizados.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `Package.swift` | Pacote Swift único. Cada pasta da lista `apps` vira um executável |
| `suite/` | Gerenciador Cunha Tools |
| `tools/sound-manager/` | Sound Manager: código, `Info.plist`, ícone e extensão do navegador |
| `shared/CunhaKit/` | Código comum: item de início, comandos gerenciador → tool, estado da tool |
| `scripts/` | Build, instalação, assinatura, ícone e DMG |
| `dist/` | Guia de instalação que vai no DMG |
| `docs/` | Imagens deste README |

## Build

| Comando | Resultado |
|---|---|
| `./scripts/build.sh tools/sound-manager` | `build/Sound Manager.app`, universal (arm64 e x86_64) |
| `./scripts/install.sh tools/sound-manager` | Build, troca a cópia em `/Applications` e abre |
| `./scripts/build-suite.sh` | `build/Cunha Tools.app` com as tools embutidas |
| `./scripts/make-dmg.sh` | `build/CunhaTools-<versão>.dmg` |
| `swift scripts/make-icon.swift <símbolo> <#topo> <#base> <saída.icns>` | Ícone a partir de um SF Symbol sobre gradiente |

| Variável | Efeito |
|---|---|
| `ARCHS=arm64` | Pula o build universal |
| `SCRATCH=<pasta>` | Pasta de build do SwiftPM separada, para builds em paralelo |
| `CUNHA_ONLY=tools/sound-manager,suite` | Limita o pacote às pastas listadas |

## Adicionar uma tool

1. Crie `tools/<id>/Sources`, `tools/<id>/Resources/Info.plist` e `tools/<id>/Resources/AppIcon.icns` (`CFBundleIconFile` = `AppIcon`).
2. Registre o executável na lista `apps` do `Package.swift`.
3. No `Info.plist`, preencha as chaves que o Cunha Tools lê:

| Chave | Tipo | Uso |
|---|---|---|
| `CunhaToolSummary` | string | Frase do card |
| `CunhaToolRequirements` | array | Permissões que a tool pede: `audioCapture`, `localNetwork` |
| `CunhaToolSymbol` | string | SF Symbol do card |

4. Na abertura, crie um `LaunchAtLogin`, chame `applyDefault()` nele e passe-o para `ToolControl.listen(launchAtLogin:openSetup:)`. Publique o estado de setup com `ToolStatus.publish(setupComplete:)`.
5. Um script executável em `tools/<id>/build-hook.sh` roda antes da assinatura, com o caminho do `.app`. É opcional.

## Testes

O Command Line Tools não executa XCTest nem swift-testing. Cada app traz autotestes no próprio binário, chamados por flag.

| Comando | O que verifica |
|---|---|
| `CUNHA_INSTALL_DIR=<pasta> "build/Cunha Tools.app/Contents/MacOS/CunhaTools" --selftest-install` | Catálogo, instalação, atualização e remoção numa pasta de teste |
| `"build/Sound Manager.app/Contents/MacOS/SoundManager" --selftest-ceiling` | Regras do teto e do ganho |
| `"build/Sound Manager.app/Contents/MacOS/SoundManager" --selftest-slider` | Cliques e arraste no slider |
| `open -n -W "build/Sound Manager.app" --stdout /tmp/rt.log --args --selftest-router` | Tempo de vida do tap num processo real |
| `"build/Sound Manager.app/Contents/MacOS/SoundManager" --selftest-master` | Leitura e escrita do volume geral. Altera o volume real do Mac e restaura no fim |

A lista completa, com os testes de áudio e da extensão, está em [`tools/sound-manager/README.md`](tools/sound-manager/README.md#verificação).
