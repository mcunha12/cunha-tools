# Sound Manager

App de barra de menus do macOS. O clique no ícone mostra o volume geral do Mac e lista os apps tocando som, com volume e mudo por app. O Chrome expande e mostra volume e mudo por aba.

A página Sound Manager do Cunha Tools muda o volume geral e o de cada app, e mostra ou esconde o ícone. O volume por aba fica só no menu.

## Requisitos

- macOS 15 ou superior (process taps do Core Audio).
- Command Line Tools da Apple (`xcode-select --install`). O Xcode não é necessário.

## Build e execução

Rode os comandos na raiz do repositório.

| Comando | Resultado |
|---|---|
| `./scripts/build.sh tools/sound-manager` | Gera `build/Sound Manager.app`, universal (arm64 e x86_64). `ARCHS=arm64` gera só arm64 |
| `./scripts/install.sh tools/sound-manager` | Build, troca a cópia em `/Applications` e abre o app |

- O build assina o app com a identidade local “Cunha Tools Local Signing”, criada por `scripts/setup-signing.sh`. A identidade fica no keychain `~/Library/Keychains/cunhatools-signing.keychain-db`, separado do keychain de login. Com ela, o macOS mantém a permissão de áudio entre builds.
- Na primeira execução, o macOS pede “Gravação de áudio do sistema”. Sem essa permissão, o volume por app não funciona. O volume geral de um dispositivo com volume próprio funciona sem ela.
- Na primeira execução a partir de `/Applications` ou `~/Applications`, o app se registra como item de início. O checkbox “Abrir ao iniciar o Mac”, no rodapé do menu, desliga o registro. Depois de desligado, o app não religa sozinho.
- O gerenciador Cunha Tools lê `CunhaToolSummary`, `CunhaToolRequirements` e `CunhaToolSymbol` do `Info.plist`. O app grava em `~/Library/Application Support/Cunha Tools/status/com.marcelocunha.soundmanager.json` se a permissão de áudio está concedida.
- O app não é notarizado. Em outro Mac, o Gatekeeper bloqueia a primeira abertura. O caminho é Ajustes do Sistema → Privacidade e Segurança → “Abrir Mesmo Assim”. A notarização exige conta Apple Developer.

## Volume geral e teto

A linha “Volume geral”, no topo do menu, controla o dispositivo de saída padrão: nome, mudo, slider e percentual. Ela acompanha as teclas de volume do Mac e a troca de dispositivo.

O volume geral é o teto de cada app. O volume efetivo de um app é o menor valor entre o volume do app e o geral.

- Arrastar um app acima do teto: o slider para no teto e o valor salvo fica no teto. O geral não muda.
- Mexer num app nunca altera o geral.
- Baixar o geral abaixo do valor salvo de um app: o app fica no teto e o valor salvo se mantém. Com o geral de volta acima, o app volta ao valor salvo.
- Clique na trilha a até 14 pt (a largura do botão) de uma ponta leva a 0% ou a 100%. Clique no botão sem arrastar mantém o valor.
- No slider de cada app, a trilha acima do teto fica esmaecida e um marcador indica o teto. O percentual mostra o volume efetivo. Com o app limitado, a dica do percentual mostra o valor salvo.
- O volume por aba continua relativo ao app.

Dispositivo com volume próprio (ex.: alto-falantes do Mac): o tap aplica a razão entre a amplitude do volume efetivo e a do geral, pela curva de dB do próprio dispositivo. Um app em 30% soa igual ao dispositivo em 30%. App com volume próprio mantém o tap mesmo no teto, com ganho 1. Assim, subir o geral só troca o ganho: 0,52 ms, contra 12 a 102 ms para criar um tap. App em 100% não passa por tap. Geral em 0 ou mudo: o dispositivo silencia sozinho, sem tap novo.

Dispositivo sem volume próprio (HDMI, alguns DACs): o geral funciona por software, e a legenda mostra “por software”. Com o geral abaixo de 100%, todo app tocando som passa pelo tap, com ganho igual ao volume efetivo. O app guarda o geral por software por dispositivo (UID).

## Canal com o Cunha Tools

O canal é `SoundChannel`, em `shared/CunhaKit/SoundChannel.swift`: distributed notifications locais, com o conteúdo numa string JSON. Só o app aberto escuta; `--render-ui` e os autotestes não.

| Notificação | Sentido | Conteúdo |
|---|---|---|
| `com.marcelocunha.soundmanager.state` | app → suíte | Estado inteiro: dispositivo de saída, volume geral, mudo, apps tocando som (volume salvo, volume efetivo, mudo) e ícone na barra de menus |
| `com.marcelocunha.soundmanager.action` | suíte → app | Uma ação: volume ou mudo do geral, volume ou mudo de um app, ícone visível ou oculto, pedido de estado |

- O app publica o estado 30 ms depois de uma mudança, só se ele difere do último publicado. Um pedido de estado tem resposta na hora.
- A lista de apps é a mesma do menu.
- As ações seguem as regras do menu. Um app arrastado acima do volume geral fica no volume geral.
- O app ignora mensagem com JSON inválido.
- Qualquer processo do usuário pode postar no canal, como no `ToolControl`.

## Ícone na barra de menus

- "Mostrar na barra de menus", na página do Cunha Tools, mostra ou esconde o ícone. O valor fica em `UserDefaults`, chave `showsMenuBarIcon`. O padrão é visível.
- Com o ícone oculto, o app continua aberto e aplica os volumes.
- Para o ícone voltar: abra o Sound Manager de novo com ele já aberto, por clique duplo no Finder ou `open`. Com o app fechado, a primeira abertura mantém o ícone oculto e a segunda mostra.

## Extensão do navegador (volume por aba)

1. Abra o menu do Sound Manager e expanda o Chrome.
2. Clique em “Instalar extensão”. O app copia a extensão para `~/Library/Application Support/Sound Manager/BrowserExtension`, abre a pasta no Finder, copia o caminho e abre `chrome://extensions`.
3. Ative o “Modo do desenvolvedor” e clique em “Carregar sem compactação”. Escolha a pasta.

A extensão conecta no app por `ws://127.0.0.1:47821`. O app aceita só conexões com origem `chrome-extension://`.

Depois de alterar arquivos em `Resources/BrowserExtension/`, clique de novo em “Instalar extensão” e em “Recarregar” na página de extensões.

## Limites

- Controle por aba: Chrome e navegadores Chromium (Brave, Edge, Arc, Vivaldi, Opera). O Safari exige uma Safari Web Extension, e o build dela exige o Xcode. O Firefox não tem suporte.
- Páginas `chrome://` e a Chrome Web Store bloqueiam scripts de extensão. Nelas, só o mudo funciona.
- O volume por aba só vale para abas carregadas depois da instalação da extensão, ou para abas recarregadas.
- Com volume abaixo de 100%, o áudio do app passa por um dispositivo agregado, o que acrescenta alguns milissegundos de latência. Em 100%, o app remove o tap 2 s depois.
- Geral por software abaixo de 100%: um app que começa a tocar fica sem o teto até o tap entrar. Criar um tap levou de 12 a 102 ms nas medições num MacBook Air.

## Verificação

`APP="build/Sound Manager.app"`, na raiz do repositório.

| Comando | O que verifica |
|---|---|
| `"$APP/Contents/MacOS/SoundManager" --selftest-ceiling` | Regras do teto: volume efetivo, arraste acima do teto, ganho pela curva do dispositivo e por software, geral por software salvo por UID. Sai com código 1 em falha |
| `"$APP/Contents/MacOS/SoundManager" --selftest-master` | Lê o volume e o mudo do dispositivo padrão, escreve outros valores, confere a leitura e o listener, e restaura os valores originais. Sai com código 1 em falha |
| `"$APP/Contents/MacOS/SoundManager" --selftest-slider` | Cliques e arraste sintéticos num slider de 205 pt: pontas, meio, botão e teto. Sai com código 1 em falha |
| `open -n -W "$APP" --stdout /tmp/rt.log --args --selftest-router` | Tempo de vida do tap num processo real, com ganho perto de 1 (inaudível), e tempo para subir o geral. Sai com código 1 em falha |
| `"$APP/Contents/MacOS/SoundManager" --render-ui /tmp/menu.png --demo` | PNG do menu com três apps de exemplo e geral em 60%. `--software` mostra o geral por software |
| `open -n "$APP" --stderr /tmp/st.log --args --selftest <pid> 0.5` | Ganho do motor de áudio num processo (razão saída/bruto) |
| `open -n "$APP" --stderr /tmp/mt.log --args --model-test <bundle-id>` | Volume e mudo pelo `AppModel`, com mapeamento de processos real |
| `python3 tools/sound-manager/scripts/e2e_extension.py` | Extensão num Chrome headless: volume 30%, mudo e restauração, medidos no áudio real |
| `python3 tools/sound-manager/scripts/fake_extension.py session 6` | Ponte WebSocket do app com um cliente falso |

`e2e_extension.py` usa a porta 47899 e não interfere no app aberto. `fake_extension.py` usa a porta 47821, ou `SOUNDMANAGER_PORT`.

O canal com o Cunha Tools é testado pela suíte, com este app aberto: `"build/Cunha Tools.app/Contents/MacOS/CunhaTools" --selftest-remote`. A lista de verificações está em [`suite/README.md`](../../suite/README.md#verificação).
