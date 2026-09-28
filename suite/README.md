# Cunha Tools (gerenciador)

App com janela única. Instala, atualiza, remove e configura as tools embutidas. O app fecha junto com a janela e não fica residente.

## Tools

- O catálogo vem de `Contents/Library/Tools/*.app`. Cada card lê o `Info.plist` da tool: nome, versão, `CunhaToolSummary`, `CunhaToolRequirements` e `CunhaToolSymbol`.
- Instalar e atualizar copiam a tool para `/Applications`. Sem permissão de escrita, a cópia vai para `~/Applications`. A cópia aberta é encerrada antes da troca.
- Remover desliga o item de início, encerra a tool e a move para o Lixo.
- "Abrir ao iniciar o Mac" e "Configurar" enviam comandos para a tool (`ToolControl`). O estado vem de `~/Library/Application Support/Cunha Tools/status/<bundle id>.json`.

## Build

`scripts/build-suite.sh` builda as tools e a suíte, e embute as tools. Uma tool que não compila fica de fora, com aviso. `scripts/make-dmg.sh` empacota o último build em `build/CunhaTools-<versão>.dmg`.

## Verificação

| Comando | O que verifica |
|---|---|
| `CUNHA_INSTALL_DIR=<pasta> CunhaTools --selftest-install` | Catálogo, instalação, versão, atualização e remoção numa pasta de teste |
| `CunhaTools --render-ui <saída.png> [--light\|--dark]` | Janela renderizada em PNG |
