# Cunha Tools para Android

App companheiro do Pair File Sharing e do Pair Screen. Java puro, sem AndroidX e sem Gradle. Package `com.marcelocunha.cunhatools`, minSdk 30, targetSdk 35. O APK tem cerca de 54 KB.

## Funções

| Função | Onde |
|---|---|
| Receber arquivos do Mac | `TransferService`: foreground service `connectedDevice`, porta 47831, anúncio NSD `_cunhapfs._tcp`. Inicia no boot e ao abrir o app |
| Enviar arquivos ao Mac | `ShareActivity` (Compartilhar → "Enviar para o Mac") e botão "Enviar arquivos" na tela principal |
| Pareamento via adb | `PairReceiver`, protegido por `WRITE_SECURE_SETTINGS`. Comando em `tools/pair-file-sharing/PROTOCOL.md` |
| Pareamento via QR | `PairActivity`, deep link `cunhatools://pair?...`. Pede confirmação antes de gravar |
| Manter depuração sem fio ligada | `AdbWifi`: grava `adb_wifi_enabled=1` no boot e quando o Wi-Fi conecta. Exige `WRITE_SECURE_SETTINGS`, concedida pelo Cunha Tools |

Os arquivos recebidos vão para `Download/Pair File Sharing`, via MediaStore, sem permissão de armazenamento.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `core/` | Núcleo do protocolo em Java puro. Roda no Android e na JVM do Mac |
| `app/` | Código e recursos Android |
| `jvm/` | CLI da JVM usada no teste de interoperabilidade com o Mac |

## Build

`android/build.sh` gera `build/android/cunha-companion.apk` (aapt2, javac, d8, zipalign, apksigner). Na primeira execução, o script cria a keystore `~/.android/cunhatools.keystore`, fora do git. Trocar a keystore obriga a desinstalar o app no celular antes de instalar o novo.

## Instalação

O Cunha Tools instala o APK pela seção Celular. À mão:

```
adb install -r build/android/cunha-companion.apk
adb shell pm grant com.marcelocunha.cunhatools android.permission.WRITE_SECURE_SETTINGS
adb shell pm grant com.marcelocunha.cunhatools android.permission.POST_NOTIFICATIONS
```

## Samsung

- O "Bloqueador automático" (Configurações → Segurança e privacidade) bloqueia o `adb install`. Desligue-o antes de instalar.
- Se o service parar sozinho: Configurações → Aplicativos → Cunha Tools → Bateria → "Sem restrições".
