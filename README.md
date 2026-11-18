# Limpeza do cliente SCCM (MECM) com painel de execução

Script PowerShell que **remove o cliente do Configuration Manager (SCCM/MECM) e limpa tudo o que ele deixa na máquina** — quando o agente está corrompido e a reinstalação normal falha. Ao final, gera um **painel HTML** mostrando cada etapa executada, o resultado, o espaço liberado e um comparativo **antes x depois**.

![Exemplo do painel](exemplo/screenshot.png)

> Veja o painel de exemplo: [exemplo/painel-exemplo.html](exemplo/painel-exemplo.html)

## O que ele faz

| # | Etapa | Detalhe |
|---|---|---|
| 1 | Verificação inicial | administrador, versão e site do cliente, levantamento do que existe |
| 2 | Desinstalação oficial | `ccmsetup.exe /uninstall`, aguardando terminar (com limite de tempo) e lendo o resultado no log |
| 3 | Serviços | para `CcmExec`, `smstsmgr`, `CmRcService`, `ccmsetup`; se não pararem, encerra o processo |
| 4 | ccmclean | opcional, se informado |
| 5 | Pastas e arquivos | `C:\Windows\CCM`, `ccmcache`, `ccmsetup` e `smscfg.ini`, informando o espaço liberado |
| 6 | Registro | `HKLM\SOFTWARE\Microsoft\CCM`, `CCMSetup` e `SMS` |
| 7 | WMI e certificados | namespaces `root\ccm` e `root\cimv2\sms` e certificados do repositório `SMS` |
| 8 | Firewall *(opcional)* | habilita os grupos de regras de gerenciamento remoto (WMI, serviços, eventos...) — funciona em Windows em português ou inglês |
| 9 | Repositório WMI *(opcional)* | `winmgmt /resetrepository`, só quando o WMI está com problema |
| 10 | Verificação final | confere o que sobrou e indica o próximo passo |

Cada etapa é registrada como **OK**, **Aviso**, **Erro**, **Ignorado** ou **Simulado** — e o painel permite filtrar clicando nos indicadores.

## Segurança

- **`-WhatIf`**: simula tudo e gera o painel mostrando o que *seria* feito, sem alterar nada.
- Pede confirmação (digitar `SIM`) antes de remover — use `-Force` para automatizar.
- Não apaga a pasta do repositório WMI: quando necessário, usa o comando oficial `winmgmt /resetrepository`.
- Arquivos em uso e chaves protegidas viram **Aviso** (não interrompem o script); reiniciar e rodar de novo resolve.
- Log completo (transcript) salvo junto com o painel.

## Requisitos

- Windows PowerShell 5.1 ou PowerShell 7, **como administrador**
- Executar na própria máquina (ou via `Enter-PSSession` / `Invoke-Command`)

## Como usar

```powershell
# 1) simular primeiro (não altera nada)
.\Reset-SCCMClient.ps1 -WhatIf

# 2) limpeza
.\Reset-SCCMClient.ps1

# limpeza + liberar firewall para gerenciamento remoto + reiniciar ao final, sem perguntar
.\Reset-SCCMClient.ps1 -ConfigurarFirewall -Reiniciar -Force

# usando o ccmclean.exe e redefinindo o WMI
.\Reset-SCCMClient.ps1 -CaminhoCcmClean C:\Tools\ccmclean.exe -RedefinirWMI
```

| Parâmetro | Descrição | Padrão |
|---|---|---|
| `-WhatIf` | simula, sem alterar nada | — |
| `-CaminhoCcmClean` | caminho do `ccmclean.exe` | `.\tools\ccmclean.exe`, se existir |
| `-TempoDesinstalacao` | segundos de espera do `ccmsetup /uninstall` | `300` |
| `-ConfigurarFirewall` | habilita regras de gerenciamento remoto | não |
| `-RedefinirWMI` | redefine o repositório WMI | não |
| `-Reiniciar` | reinicia 60 s após terminar (`shutdown /a` cancela) | não |
| `-Saida` | pasta do painel e do log | `C:\Temp\LimpezaSCCM` |
| `-Force` | não pede confirmação | — |
| `-NaoAbrir` | não abre o painel ao terminar | — |

## Depois da limpeza

1. Reinicie a máquina.
2. Reinstale o cliente (`ccmsetup.exe` com os parâmetros do seu site, ou pelo console do SCCM).

## Licença

MIT — veja [LICENSE](LICENSE).
