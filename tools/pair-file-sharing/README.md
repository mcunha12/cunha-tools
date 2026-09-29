# Pair File Sharing

App de barra de menus. Transfere arquivos entre o Mac e o celular Android pela rede Wi-Fi atual, nos dois sentidos. O celular precisa do app companheiro Cunha Tools (`android/`).

## Uso

| Sentido | Como |
|---|---|
| Mac → celular | Arraste arquivos ou pastas para o ícone da barra de menus ou para o popover. Também: "Escolher arquivos…" e Finder → Serviços → "Enviar para o celular" |
| Celular → Mac | Compartilhar → "Enviar para o Mac", ou "Enviar arquivos" no app Cunha Tools |

- O Mac grava em `~/Downloads/Pair File Sharing`. O celular grava em `Download/Pair File Sharing`.
- O popover mostra MB/s, tempo restante e o botão cancelar.

## Pareamento

1. O celular precisa estar pareado por adb no Cunha Tools (seção Celular), com o app companheiro instalado.
2. Abra "Parear celular" no menu da tool. Com adb conectado, o pareamento é automático. Sem adb, a janela mostra um QR: abra-o com a câmera do celular e confirme.

A chave de pareamento fica em `~/Library/Application Support/Cunha Tools/pair-file-sharing/pairing.json`, permissão 0600.

## Protocolo

TCP direto, 4 conexões paralelas, blocos de 8 MiB, autenticação HMAC-SHA256 e quadros AES-256-GCM. Detalhes em `PROTOCOL.md`.

## Primeira execução

O macOS pede dois acessos:

- **Rede local**: sem ele, o celular não acha o Mac.
- **Pasta Downloads**: aparece no primeiro recebimento.

## Verificação

| Comando | O que verifica |
|---|---|
| `PairFileSharing --selftest-unit` | Manifesto, blocos e nomes de caminho |
| `PairFileSharing --selftest-crypto` | Vazão do AES-256-GCM em 1 e 4 threads |
| `PairFileSharing --selftest-bonjour` | Anúncio e resolução `_cunhapfs._tcp` |
| `tools/pair-file-sharing/scripts/interop-test.sh <pasta>` | Núcleo Java (papel do celular) × binário do Mac, nos dois sentidos, com SHA-256 e chave errada. `BIG_MB` define o tamanho do arquivo grande |

O binário fica em `build/Pair File Sharing.app/Contents/MacOS/PairFileSharing`.

## Limites

- Com o Mac também no Wi-Fi, cada byte passa duas vezes pelo ar (celular → roteador → Mac). Com o Mac no cabo, só uma.
- O envio pelo celular aceita arquivos. Pastas não entram.
- Uma transferência interrompida recomeça do zero.
