# Pair Screen

App de barra de menus. Espelha a tela do celular Android numa janela flutuante no Mac, com controle por mouse e teclado. A conexão é por adb, por Wi-Fi (depuração sem fio) ou por USB. O pareamento adb é feito no Cunha Tools, seção Celular.

## Arquitetura

- No celular roda o `scrcpy-server` v4.1 (Genymobile/scrcpy, Apache-2.0; ver `Resources/NOTICE`). O `build-hook.sh` baixa o arquivo, confere o SHA-256 e o copia para `Contents/Resources/scrcpy-server`. O cache fica em `.build/downloads/`.
- O cliente no Mac é Swift nativo. A decodificação H.265/H.264 roda em hardware (VideoToolbox), com exibição direta no `AVSampleBufferDisplayLayer`.
- Se o H.265 não entregar vídeo, o app tenta H.264 e avisa.

## Controles

| Mac | Celular |
|---|---|
| Clique e arraste | Toque e deslize |
| Roda do mouse ou trackpad | Rolagem |
| Botão direito | Voltar (liga a tela se estiver apagada) |
| Botão do meio | Início |
| Digitação | Texto |
| Enter, Delete, setas, Tab, Home/End, Page Up/Down | Teclas equivalentes |
| Esc | Voltar |
| ⌘V | Cola o clipboard do Mac no celular |
| ⌘ + letra | Ctrl + letra (⌘C copia, ⌘A seleciona tudo) |

- A barra que aparece com o mouse sobre a janela tem: voltar, início, recentes, ligar/desligar a tela, girar e fechar.
- Arraste a janela pela faixa superior ou com ⌥ + arrastar em qualquer ponto. O redimensionamento mantém a proporção.
- O clipboard do celular vai para o do Mac.

## Ajustes (menu da barra)

Resolução máxima (padrão 1600), fps máximo (padrão 60), bitrate (padrão 12 Mbps), codec, "Desligar tela do celular durante o espelhamento" e "Sempre no topo".

## Verificação

| Comando | O que verifica |
|---|---|
| `PairScreen --selftest-control` | Bytes das mensagens de controle e do dispositivo contra os testes C do scrcpy v4.1 |
| `tools/pair-screen/scripts/pipeline_test.sh "build/Pair Screen.app" h265` | ffmpeg → servidor scrcpy falso → cliente real: frames decodificados, troca de resolução, entrada. `MEASURE=1` mede CPU e RAM sem capturas |

## Limites

- A escala da rolagem do trackpad é uma estimativa. Ela pode precisar de ajuste no celular real.
- Sem áudio do celular.
