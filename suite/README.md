# Cunha Tools (gerenciador)

App com janela única. Instala, atualiza, remove e configura as tools embutidas. O app fecha junto com a janela e não fica residente.

## Tools

- O catálogo vem de `Contents/Library/Tools/*.app`. Cada card lê o `Info.plist` da tool: nome, versão, `CunhaToolSummary`, `CunhaToolRequirements` e `CunhaToolSymbol`.
- Instalar e atualizar copiam a tool para `/Applications`. Sem permissão de escrita, a cópia vai para `~/Applications`. A cópia aberta é encerrada antes da troca.
- Remover desliga o item de início, encerra a tool e a move para o Lixo.
- "Abrir ao iniciar o Mac" e "Configurar" enviam comandos para a tool (`ToolControl`). O estado vem de `~/Library/Application Support/Cunha Tools/status/<bundle id>.json`.

## Checar atualizações

- O `build-suite.sh` grava `CunhaSourceCommit` no `Info.plist` da suíte: `CUNHA_SOURCE_COMMIT` ou `git rev-parse HEAD`.
- O botão lê `CunhaUpdateRepository` e `CunhaUpdateBranch` do `Info.plist`. `CUNHA_UPDATE_BRANCH` troca o branch para testes.
- Decisão, pela API de compare do GitHub: commit igual ou branch atrás do commit instalado → atualizado. Branch à frente, divergente, commit desconhecido pelo GitHub ou sem commit gravado → atualiza.
- A atualização baixa o tarball do commit para `~/Library/Caches/Cunha Tools/update`, roda o `build-suite.sh` com `ARCHS` nativo, troca as tools instaladas mais antigas e a própria suíte, e apaga a pasta. Log em `~/Library/Logs/Cunha Tools/update.log`.
- A suíte se troca no lugar. Rodando de um DMG ou de App Translocation, vai para a pasta padrão de instalação.

## Build

`scripts/build-suite.sh` builda as tools e a suíte, e embute as tools. Uma tool que não compila fica de fora, com aviso. `scripts/make-dmg.sh` empacota o último build em `build/CunhaTools-<versão>.dmg`.

## Verificação

| Comando | O que verifica |
|---|---|
| `CUNHA_INSTALL_DIR=<pasta> CunhaTools --selftest-install` | Catálogo, instalação, versão, atualização e remoção numa pasta de teste |
| `CUNHA_INSTALL_DIR=<pasta> [CUNHA_UPDATE_BRANCH=<branch>] CunhaTools --selftest-update` | GitHub real: decisão, download, build, commit gravado, assinatura e troca da suíte numa pasta de teste |
| `CunhaTools --render-ui <saída.png> [--light\|--dark]` | Janela renderizada em PNG |
