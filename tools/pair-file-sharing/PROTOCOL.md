# Pair File Sharing: protocolo (versão 1)

TCP direto na rede Wi-Fi atual. Sem Wi-Fi Direct e sem hotspot. Quem envia abre as conexões; quem recebe escuta.

## Endereços

| Lado | Porta TCP | Bonjour/NSD |
|---|---|---|
| Mac | 47830 | `_cunhapfs._tcp`, TXT `role=mac`, `id=<id do Mac>` |
| Celular | 47831 | `_cunhapfs._tcp`, TXT `role=phone`, `id=<id do celular>` |

Ordem de tentativa no envio: endereço resolvido pelo Bonjour, último IP conhecido do pareamento, e (só no Mac) acordar o service por adb e ler o IP de `wlan0`. Cada conexão autenticada atualiza o último IP conhecido do outro lado.

## Handshake (em claro, 3 mensagens)

`K` = chave de pareamento, 32 bytes. `keyId` = SHA-256(K)[0..8].

```
C→S HELLO   (46 B) = "CPFS" | versão=1 | papel (1=mac, 2=phone) | keyId (8) | nonceC (32)
S→C WELCOME (70 B) = "CPFS" | versão=1 | papel | nonceS (32) | HMAC-SHA256(K, "cpfs-s" | HELLO | WELCOME[0..38])
C→S PROOF   (32 B) = HMAC-SHA256(K, "cpfs-c" | HELLO | WELCOME[0..38])
```

O servidor fecha a conexão se não conhece o `keyId` ou se a prova não confere. O cliente rejeita um WELCOME cujo HMAC não confere.

Chaves de sessão, uma por sentido e por conexão: `HKDF-SHA256(ikm=K, salt=nonceC|nonceS, info="cpfs c2s" | "cpfs s2c")`, 32 bytes.

## Quadros

```
u32 comprimento (texto cifrado + 16) | AES-256-GCM(texto) | tag (16)
```

Nonce = 4 bytes zero + contador u64 big-endian, próprio de cada sentido, começando em 0. AAD = os 4 bytes do comprimento. Texto em claro de até 1 MiB + 64 bytes. Sem compressão. Inteiros em big-endian; texto = u16 comprimento + UTF-8.

| Tipo | Conteúdo |
|---|---|
| `0x01` INFO | id, nome, porta de escuta. A resposta é outro INFO. Confirma pareamento e testa alcance. |
| `0x02` OFFER | sessão (16), conexões (u8), id, nome, nº de itens (u32), bytes totais (u64), itens neste quadro (u32), itens |
| `0x03` OFFER_MORE | itens neste quadro (u32), itens (manifesto que não coube em 1 MiB) |
| `0x04` JOIN | sessão (16): conexão extra da mesma transferência |
| `0x05` DATA | repetido: arquivo (u32), offset (u64), tamanho (u32), bytes |
| `0x06` FINISH | fim do envio, só na conexão de controle |
| `0x07` CANCEL | cancelado pelo remetente |
| `0x10` ACCEPT / `0x11` REJECT (motivo) / `0x12` DONE (itens u32, bytes u64) | respostas do receptor |

Item do manifesto: tipo (u8: 0 arquivo, 1 pasta vazia), caminho relativo com `/`, tamanho (u64), modificação em ms (i64). O receptor recusa `..`, troca `:` e caracteres de controle por `_`, e renomeia caminhos repetidos para " (2)".

## Transferência

1. Conexão de controle: handshake, OFFER, espera ACCEPT (ou REJECT, por exemplo "sem espaço no destino").
2. Mais N−1 conexões (padrão N=4): handshake, JOIN, ACCEPT. Conexão extra que falha só reduz o paralelismo.
3. Os arquivos formam um fluxo concatenado, dividido em blocos de 8 MiB. Cada conexão pega o próximo bloco livre. Um quadro DATA leva até 1 MiB e pode juntar pedaços de vários arquivos pequenos.
4. O receptor grava cada pedaço por posição (`pwrite` / `FileChannel.write(buf, pos)`) em arquivo temporário pré-alocado. Quando o arquivo completa, publica: `rename` no Mac, `IS_PENDING=0` no MediaStore.
5. Depois do último bloco, o remetente manda FINISH. O receptor espera todos os bytes, cria pastas vazias e arquivos de 0 byte, e responde DONE.
6. Falha ou cancelamento em qualquer conexão encerra a sessão inteira e apaga os temporários dos arquivos incompletos. Arquivos já completos ficam.

Buffers de socket: 4 MiB no Mac. No Android o núcleo mantém o autoajuste do kernel, porque `SO_RCVBUF` explícito desliga o autoajuste do Linux e fica limitado a `rmem_max`.

## Pareamento

Chave nova de 32 bytes a cada pareamento. O Mac aceita a chave pendente enquanto a janela "Parear celular" está aberta.

**Via adb** (o gerenciador e a tool usam este caminho). O receiver exige `WRITE_SECURE_SETTINGS` do remetente; o shell do adb tem, apps comuns não.

```
adb shell "am broadcast -a com.marcelocunha.cunhatools.PAIR -n com.marcelocunha.cunhatools/.PairReceiver --include-stopped-packages --es key '<chave base64url>' --es mac_name '<nome do Mac>' --es mac_id '<id do Mac>' --es host '<IP do Mac>' --ei port 47830"
```

Resposta: `Broadcast completed: result=-1, data="ok|<id do celular>|<nome do celular>"`. Depois a tool roda:

```
adb shell pm grant com.marcelocunha.cunhatools android.permission.WRITE_SECURE_SETTINGS
adb shell pm grant com.marcelocunha.cunhatools android.permission.POST_NOTIFICATIONS
adb shell am start-foreground-service -n com.marcelocunha.cunhatools/.TransferService
```

**Via QR**: `cunhatools://pair?k=<chave base64url>&n=<nome do Mac>&id=<id do Mac>&h=<IP do Mac>&p=47830`. A câmera abre o link; o app pede "Parear com <Mac>?" antes de gravar. Depois o celular manda INFO ao Mac, que grava o pareamento.

**No Mac**: `~/Library/Application Support/Cunha Tools/pair-file-sharing/pairing.json`, permissão 0600:

```json
{ "key": "<base64url>", "macId": "…", "phoneId": "…", "phoneName": "…", "phoneHost": "192.168.1.23", "phonePort": 47831, "pairedAt": "2026-09-27T22:00:00Z" }
```

`setupComplete` do status da suíte = chave válida e `phoneId` presente.

## Testes

- `tools/pair-file-sharing/scripts/interop-test.sh <pasta>`: núcleo Java na JVM (faz o papel do celular) contra o binário do Mac, nos dois sentidos, arquivo grande + 1.000 arquivos, SHA-256 de origem e destino, chave errada.
- Binário: `PairFileSharing --selftest-unit | --selftest-crypto | --selftest-bonjour | --selftest-receive <porta> <chave> <pasta> | --selftest-send <host> <porta> <chave> <conexões> <caminhos…> | --selftest-wrongkey <host> <porta> <chave>`.
- Cifra no celular: `adb shell CLASSPATH=$(adb shell pm path com.marcelocunha.cunhatools | cut -d: -f2) app_process / com.marcelocunha.cunhatools.pfs.Bench`.
