# Cunha Tools (gerenciador)

App com janela única. Instala, atualiza, remove e configura as tools embutidas, e pareia o celular Android por adb. O app fecha junto com a janela e não fica residente.

## Janela

- Barra lateral: Início, uma página por tool e Celular. O ponto ao lado de cada tool mostra o estado: laranja para atualização ou configuração pendente, verde-azulado para aberta, cinza para não instalada.
- Início: selo de estado, card com a próxima ação, anel de tools abertas, fechadas e não instaladas, e grade com um card por tool.
- Página da tool, de cima para baixo: card de instalar, atualizar, abrir e remover. Card de configuração: requisitos, "Configurar" e "Abrir ao iniciar o Mac". **Como usar**, fechado: passos de `CunhaToolGuide`.
- Página do Sound Manager: card **Volumes** entre os dois primeiros e "Mostrar na barra de menus" no card de configuração. Detalhes em [Sound Manager](#sound-manager).
- Rodapé: **Atualizar**, **Contribua** (popup com o QR Pix e o código copia e cola) e **Aparência**, gravada em `UserDefaults`.

## Tools

- O catálogo vem de `Contents/Library/Tools/*.app`. Cada página lê o `Info.plist` da tool embutida: nome, versão, `CunhaToolSummary`, `CunhaToolRequirements`, `CunhaToolSymbol`, `CunhaToolTint` e `CunhaToolGuide`.
- Instalar e atualizar copiam a tool para `/Applications`. Sem permissão de escrita, a cópia vai para `~/Applications`. A cópia aberta é encerrada antes da troca. Depois, as outras cópias da tool nessas duas pastas, com o mesmo bundle ID e qualquer nome, vão para o Lixo.
- Remover desliga o item de início, encerra a tool e a move para o Lixo.
- "Abrir ao iniciar o Mac" e "Configurar" enviam comandos para a tool (`ToolControl`). O estado vem de `~/Library/Application Support/Cunha Tools/status/<bundle id>.json`.
- A suíte sabe se uma tool está aberta pela lista `NSWorkspace.runningApplications`, observada por KVO. As notificações de abertura e fechamento do `NSWorkspace` não chegam para apps de barra de menus (`LSUIElement`), e toda tool é um.

## Sound Manager

A página conversa com o Sound Manager aberto por `SoundChannel` (`shared/CunhaKit/SoundChannel.swift`), em distributed notifications locais.

- O Sound Manager publica o estado inteiro a cada mudança e quando a suíte pede: dispositivo de saída, volume geral, mudo, apps tocando som (volume salvo, volume efetivo, mudo) e o ícone na barra de menus.
- A suíte manda ações: volume e mudo do geral, volume e mudo de um app, ícone visível ou oculto, pedido de estado.
- No arraste, a suíte manda no máximo uma ação a cada 50 ms por slider, sempre com o último valor. O slider mostra o valor local por 0,5 s depois do último movimento.
- O card **Volumes** usa o mesmo slider do menu: para no volume geral e esmaece a trilha acima dele.
- Sound Manager fechado: o card mostra "Abrir". Sem resposta em 2 s: o card pede para atualizar o Sound Manager quando há versão nova, ou diz que ele não respondeu.
- O volume por aba do Chrome fica só no menu do Sound Manager.

## Celular

1. **Ferramentas Android**: sem adb, a suíte baixa o platform-tools do Google (16 MB) para `~/Library/Application Support/Cunha Tools/platform-tools`.
2. **Preparar o celular**: desligar o Bloqueador automático (Samsung), ativar as Opções do desenvolvedor e ligar a Depuração sem fio.
3. **Parear**: no celular, Depuração sem fio → "Parear o dispositivo com um código QR" e ler o QR da suíte. Alternativa: "Parear com código", com IP:porta e o código de 6 dígitos. Também aceita USB.
   Se o Mac não vê o serviço de pareamento do QR em 20 s, a suíte mostra um aviso laranja e abre "Parear com código". A busca pelo QR continua.
4. **App companheiro**: a suíte instala o APK embutido e concede `WRITE_SECURE_SETTINGS` e `POST_NOTIFICATIONS`.

## Atualizar

- O `build-suite.sh` grava `CunhaSourceCommit` no `Info.plist` da suíte: `CUNHA_SOURCE_COMMIT` ou `git rev-parse HEAD`.
- O botão lê `CunhaUpdateRepository` e `CunhaUpdateBranch` do `Info.plist`. `CUNHA_UPDATE_BRANCH` troca o branch para testes.
- Decisão, pela API de compare do GitHub: commit igual ou branch atrás do commit instalado → atualizado. Branch à frente, divergente, commit desconhecido pelo GitHub ou sem commit gravado → atualiza.
- A atualização baixa o tarball do commit para `~/Library/Caches/Cunha Tools/update`, roda o `build-suite.sh` com `ARCHS` nativo, troca as tools instaladas mais antigas e a própria suíte, e apaga a pasta. Log em `~/Library/Logs/Cunha Tools/update.log`.
- A suíte nova vai para a pasta de instalação, de onde quer que a cópia aberta esteja. Depois, as outras cópias da suíte nessa pasta e a cópia aberta vão para o Lixo. Uma cópia num DMG ou em App Translocation fica onde está.

## Build

`scripts/build-suite.sh` builda as tools, o APK e a suíte, e embute tudo. `SKIP_ANDROID=1` pula o APK. Uma tool que não compila fica de fora, com aviso. `scripts/make-dmg.sh` empacota o último build em `build/CunhaTools-<versão>.dmg`.

## Verificação

| Comando | O que verifica |
|---|---|
| `CUNHA_INSTALL_DIR=<pasta> CunhaTools --selftest-install` | Catálogo, instalação, versão, atualização, cópia antiga no Lixo e remoção numa pasta de teste |
| `CUNHA_INSTALL_DIR=<pasta> [CUNHA_UPDATE_BRANCH=<branch>] CunhaTools --selftest-update` | GitHub real: decisão, download, build, commit gravado, assinatura e troca da suíte numa pasta de teste |
| `CunhaTools --selftest-phone` | QR de pareamento e leitura das respostas do adb |
| `CunhaTools --selftest-bonjour` | Busca e resolução mDNS de um serviço de pareamento falso |
| `CunhaTools --selftest-remote` | Com o Sound Manager aberto: arraste do volume geral (mensagens por arraste e valor final), volume real do Mac, mudo, mudo e volume de um app tocando som, ícone saindo e voltando à barra de menus, reabertura, mensagens inválidas, fechar e abrir. Restaura tudo no fim. O volume de um app só é testado se o valor salvo dele estiver no volume geral ou abaixo |
| `CunhaTools --selftest-platform-tools <pasta>` | Download e extração do platform-tools |
| `CunhaTools --render-ui <saída.png> [--page inicio\|celular\|<tool>] [--guide] [--contribute] [--phone] [--qr] [--light\|--dark] [--width <pt>] [--wait s]` | Barra lateral e página renderizadas em PNG, sem split view. `--guide` abre **Como usar**. `--contribute` renderiza só o popup do Pix. `--width` define a largura da página, padrão 830. `--qr` mostra o QR sem ler os celulares conectados; `--qr --wait 21` mostra o aviso de 20 s |
