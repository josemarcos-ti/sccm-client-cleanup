<#
.SYNOPSIS
    Remove o cliente do Configuration Manager (SCCM/MECM) e limpa o que sobra dele,
    gerando um painel HTML com tudo o que foi executado.

.DESCRIPTION
    Use quando o agente do SCCM esta corrompido e a reinstalacao normal falha.
    Etapas:
      1. Verificacao inicial (administrador, versao do cliente, servicos, pastas, registro)
      2. Desinstalacao oficial (ccmsetup.exe /uninstall), aguardando terminar
      3. Parada dos servicos do cliente (com encerramento forcado se nao pararem)
      4. ccmclean.exe (opcional, se informado)
      5. Remocao das pastas (CCM, ccmcache, ccmsetup) e do smscfg.ini
      6. Remocao das chaves de registro (CCM, CCMSetup, SMS)
      7. Remocao dos namespaces WMI do cliente e dos certificados SMS
      8. Opcional: liberar regras de firewall para gerenciamento remoto (-ConfigurarFirewall)
      9. Opcional: redefinir o repositorio WMI (-RedefinirWMI)
     10. Verificacao final e painel HTML (+ log em texto)

    Suporta -WhatIf: mostra tudo o que seria feito, sem alterar nada.

.PARAMETER CaminhoCcmClean
    Caminho do ccmclean.exe (opcional).
.PARAMETER TempoDesinstalacao
    Segundos para aguardar o ccmsetup /uninstall (padrao: 300).
.PARAMETER ConfigurarFirewall
    Habilita os grupos de regras do firewall usados no gerenciamento remoto (WMI, servicos, eventos...).
.PARAMETER RedefinirWMI
    Redefine o repositorio WMI (winmgmt /resetrepository). Use so se o WMI estiver com problema.
.PARAMETER Reiniciar
    Reinicia o computador 60 segundos depois de terminar.
.PARAMETER Saida
    Pasta do painel HTML e do log (padrao: C:\Temp\LimpezaSCCM).
.PARAMETER Force
    Nao pede confirmacao.
.PARAMETER NaoAbrir
    Nao abre o painel ao terminar.

.EXAMPLE
    .\Reset-SCCMClient.ps1 -WhatIf
    Simula: mostra no painel tudo o que seria feito, sem alterar nada.
.EXAMPLE
    .\Reset-SCCMClient.ps1
.EXAMPLE
    .\Reset-SCCMClient.ps1 -ConfigurarFirewall -Reiniciar -Force

.NOTES
    Rode como administrador, na propria maquina (ou via sessao remota).
    Depois da limpeza, reinicie a maquina e reinstale o cliente (ccmsetup.exe ou console do SCCM).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CaminhoCcmClean,
    [ValidateRange(30, 3600)][int]$TempoDesinstalacao = 300,
    [switch]$ConfigurarFirewall,
    [switch]$RedefinirWMI,
    [switch]$Reiniciar,
    [string]$Saida = 'C:\Temp\LimpezaSCCM',
    [switch]$Force,
    [switch]$NaoAbrir
)

$ErrorActionPreference = 'Continue'
$Cmd = $PSCmdlet
$Simulacao = [bool]$WhatIfPreference
$inicio = Get-Date

# ---------------- o que o cliente SCCM deixa na maquina ----------------
$Win = $env:SystemRoot
$Pastas = [ordered]@{ 'ccmsetup' = "$Win\ccmsetup"; 'CCM' = "$Win\CCM"; 'ccmcache' = "$Win\ccmcache" }
$Servicos = [ordered]@{ 'ccmsetup' = 'Instalador do cliente'; 'smstsmgr' = 'Task Sequence Manager'; 'CcmExec' = 'SMS Agent Host'; 'CmRcService' = 'Controle Remoto' }
$Chaves = @('HKLM:\SOFTWARE\Microsoft\CCM', 'HKLM:\SOFTWARE\Microsoft\CCMSetup', 'HKLM:\SOFTWARE\Microsoft\SMS')
$SmsCfg = "$Win\smscfg.ini"

# ---------------- registro das etapas (vira o painel) ----------------
$Etapas = New-Object System.Collections.Generic.List[object]
function Add-Etapa([string]$Grupo, [string]$Etapa, [string]$Resultado, [string]$Detalhe, [double]$Seg = 0) {
    $Etapas.Add([pscustomobject]@{ N = $Etapas.Count + 1; Grupo = $Grupo; Etapa = $Etapa; Resultado = $Resultado; Detalhe = $Detalhe; Tempo = $(if ($Seg -ge 1) { '{0:N0} s' -f $Seg } else { '' }) })
    $cor = @{ OK = 'Green'; Aviso = 'Yellow'; Erro = 'Red'; Ignorado = 'DarkGray'; Simulado = 'Cyan' }[$Resultado]
    Write-Host ("[{0,-8}] {1}: {2}" -f $Resultado, $Etapa, $Detalhe) -ForegroundColor $cor
}
# executa uma etapa: respeita -WhatIf, mede o tempo e registra o resultado
# a acao devolve @{ R = 'OK'|'Aviso'|'Erro'|'Ignorado'; D = 'detalhe' }
function Invoke-Etapa([string]$Grupo, [string]$Etapa, [string]$Alvo, [scriptblock]$Acao) {
    if (-not $Cmd.ShouldProcess($Alvo, $Etapa)) { Add-Etapa $Grupo $Etapa 'Simulado' "seria executado em: $Alvo"; return }
    $t = Get-Date
    try { $r = & $Acao; if (-not $r) { $r = @{ R = 'OK'; D = '' } } }
    catch { $r = @{ R = 'Erro'; D = $_.Exception.Message } }
    Add-Etapa $Grupo $Etapa $r.R $r.D ((Get-Date) - $t).TotalSeconds
}
function Get-Tamanho([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    [double](Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}
function Format-Tam([double]$b) { if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } elseif ($b -gt 0) { '{0:N0} KB' -f ($b / 1KB) } else { '0' } }
function Get-Estado {
    $e = [ordered]@{}
    foreach ($s in $Servicos.Keys) { $sv = Get-Service -Name $s -ErrorAction SilentlyContinue; $e["Servico $s ($($Servicos[$s]))"] = $(if ($sv) { "$($sv.Status)" } else { 'nao existe' }) }
    foreach ($k in $Pastas.Keys) { $p = $Pastas[$k]; $e["Pasta $p"] = $(if (Test-Path -LiteralPath $p) { Format-Tam (Get-Tamanho $p) } else { 'nao existe' }) }
    $e["Arquivo $SmsCfg"] = $(if (Test-Path -LiteralPath $SmsCfg) { 'existe' } else { 'nao existe' })
    foreach ($c in $Chaves) { $e["Registro $($c -replace 'HKLM:\\', 'HKLM\')"] = $(if (Test-Path $c) { 'existe' } else { 'nao existe' }) }
    $ns = Get-CimInstance -Namespace root -ClassName __Namespace -Filter "Name='ccm'" -ErrorAction SilentlyContinue
    $e['WMI root\ccm'] = $(if ($ns) { 'existe' } else { 'nao existe' })
    $e['Certificados SMS'] = "$(@(Get-ChildItem Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue).Count)"
    $e
}

# ---------------- 1) verificacao inicial ----------------
New-Item -ItemType Directory -Path $Saida -Force -WhatIf:$false | Out-Null
$stamp = $inicio.ToString('yyyyMMdd-HHmmss')
$base = Join-Path $Saida "Limpeza-SCCM-$env:COMPUTERNAME-$stamp"
try { Start-Transcript -Path "$base.log" -WhatIf:$false | Out-Null } catch { }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$G = '1. Verificacao inicial'
if ($admin) { Add-Etapa $G 'Permissao de administrador' 'OK' "executando como $env:USERDOMAIN\$env:USERNAME" }
elseif ($Simulacao) { Add-Etapa $G 'Permissao de administrador' 'Aviso' 'sem administrador - ok para simulacao, mas a limpeza real exige administrador' }
else { Add-Etapa $G 'Permissao de administrador' 'Erro' 'rode o PowerShell como administrador'; Write-Host 'Abortado: precisa de administrador.' -ForegroundColor Red; try { Stop-Transcript | Out-Null } catch { }; return }

$mc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -ErrorAction SilentlyContinue
$versao = "$($mc.ProductVersion)"; $site = "$($mc.AssignedSiteCode)"
Add-Etapa $G 'Cliente SCCM instalado' $(if ($versao) { 'OK' } else { 'Aviso' }) $(if ($versao) { "versao $versao$(if ($site) { " - site $site" })" } else { 'versao nao encontrada no registro (cliente ausente ou ja parcialmente removido)' })
$antes = Get-Estado
$tamAntes = 0; foreach ($p in $Pastas.Values) { $tamAntes += Get-Tamanho $p }
Add-Etapa $G 'Levantamento do que existe' 'OK' "pastas do cliente: $(Format-Tam $tamAntes); $(@($antes.GetEnumerator() | Where-Object { $_.Value -ne 'nao existe' -and $_.Value -ne '0' }).Count) item(ns) encontrados"

if (-not $Simulacao -and -not $Force) {
    Write-Host "`nIsto vai REMOVER o cliente SCCM de $env:COMPUTERNAME e apagar pastas e registro dele." -ForegroundColor Yellow
    if ((Read-Host 'Digite SIM para continuar') -ne 'SIM') { Write-Host 'Cancelado.'; try { Stop-Transcript | Out-Null } catch { }; return }
}

# ---------------- 2) desinstalacao oficial ----------------
$G = '2. Desinstalacao oficial'
$exe = Join-Path $Pastas['ccmsetup'] 'ccmsetup.exe'
if (Test-Path -LiteralPath $exe) {
    Invoke-Etapa $G 'ccmsetup.exe /uninstall' $exe {
        $p = Start-Process -FilePath $exe -ArgumentList '/uninstall' -PassThru -WindowStyle Hidden
        if ($p.WaitForExit($TempoDesinstalacao * 1000)) {
            $logU = Join-Path $Pastas['ccmsetup'] 'Logs\ccmsetup.log'
            $fim = if (Test-Path $logU) { (Select-String -Path $logU -Pattern 'Uninstall succeeded|uninstall.*(failed|error)' | Select-Object -Last 1).Line } else { '' }
            $fim = ($fim -replace '<!\[LOG\[', '' -replace '\]LOG\]!>.*', '').Trim()
            @{ R = $(if ($p.ExitCode -eq 0) { 'OK' } else { 'Aviso' }); D = "terminou (codigo $($p.ExitCode))$(if ($fim) { " - log: $fim" })" }
        } else {
            Stop-Process -Name ccmsetup -Force -ErrorAction SilentlyContinue
            @{ R = 'Aviso'; D = "nao terminou em $TempoDesinstalacao s - processo encerrado; a limpeza manual continua" }
        }
    }
} else { Add-Etapa $G 'ccmsetup.exe /uninstall' 'Ignorado' "nao encontrado em $exe - segue para a limpeza manual" }

# ---------------- 3) servicos ----------------
$G = '3. Servicos do cliente'
foreach ($s in $Servicos.Keys) {
    $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $sv) { Add-Etapa $G "Parar $s" 'Ignorado' 'servico nao existe'; continue }
    if ($sv.Status -eq 'Stopped') { Add-Etapa $G "Parar $s" 'OK' 'ja estava parado'; continue }
    Invoke-Etapa $G "Parar $s" "servico $s" {
        Stop-Service -Name $s -Force -NoWait -ErrorAction SilentlyContinue
        $lim = (Get-Date).AddSeconds(30)
        while ((Get-Service -Name $s).Status -ne 'Stopped' -and (Get-Date) -lt $lim) { Start-Sleep -Milliseconds 500 }
        if ((Get-Service -Name $s).Status -eq 'Stopped') { return @{ R = 'OK'; D = 'parado' } }
        $pid2 = (Get-CimInstance Win32_Service -Filter "Name='$s'").ProcessId
        if ($pid2) { Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
        $st = (Get-Service -Name $s).Status
        @{ R = $(if ($st -eq 'Stopped') { 'Aviso' } else { 'Erro' }); D = $(if ($st -eq 'Stopped') { "nao parou sozinho - processo $pid2 encerrado a forca" } else { "continua $st - reinicie a maquina e rode de novo" }) }
    }
}

# ---------------- 4) ccmclean (opcional) ----------------
$G = '4. ccmclean'
if (-not $CaminhoCcmClean) { $CaminhoCcmClean = Join-Path $PSScriptRoot 'tools\ccmclean.exe' }
if (Test-Path -LiteralPath $CaminhoCcmClean) {
    Invoke-Etapa $G 'ccmclean.exe' $CaminhoCcmClean {
        $p = Start-Process -FilePath $CaminhoCcmClean -ArgumentList '/q' -PassThru -Wait
        @{ R = $(if ($p.ExitCode -eq 0) { 'OK' } else { 'Aviso' }); D = "codigo de saida $($p.ExitCode)" }
    }
} else { Add-Etapa $G 'ccmclean.exe' 'Ignorado' 'nao informado (opcional - a limpeza abaixo cobre o mesmo)' }

# ---------------- 5) pastas ----------------
$G = '5. Pastas e arquivos'
$liberado = 0
foreach ($k in $Pastas.Keys) {
    $p = $Pastas[$k]
    if (-not (Test-Path -LiteralPath $p)) { Add-Etapa $G "Apagar $p" 'Ignorado' 'nao existe'; continue }
    Invoke-Etapa $G "Apagar $p" $p {
        $tam = Get-Tamanho $p
        $falhas = @()
        foreach ($i in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop } catch { $falhas += $i.Name }
        }
        if (-not $falhas.Count) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        $sobra = Get-Tamanho $p
        $script:liberado += ($tam - $sobra)
        if ($falhas.Count) { @{ R = 'Aviso'; D = "liberado $(Format-Tam ($tam - $sobra)); em uso, nao apagou: $(($falhas | Select-Object -First 5) -join ', ')$(if ($falhas.Count -gt 5) { ' ...' }) - reinicie e rode de novo" } }
        else { @{ R = 'OK'; D = "apagada - $(Format-Tam $tam) liberado" } }
    }
}
if (Test-Path -LiteralPath $SmsCfg) { Invoke-Etapa $G "Apagar $SmsCfg" $SmsCfg { Remove-Item -LiteralPath $SmsCfg -Force -ErrorAction Stop; @{ R = 'OK'; D = 'apagado (a maquina recebe um novo ID de cliente na reinstalacao)' } } }
else { Add-Etapa $G "Apagar $SmsCfg" 'Ignorado' 'nao existe' }

# ---------------- 6) registro ----------------
$G = '6. Registro'
foreach ($c in $Chaves) {
    $nome = $c -replace 'HKLM:\\', 'HKLM\'
    if (-not (Test-Path $c)) { Add-Etapa $G "Apagar $nome" 'Ignorado' 'nao existe'; continue }
    Invoke-Etapa $G "Apagar $nome" $nome {
        Remove-Item -Path $c -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $c) {
            $resto = @(Get-ChildItem $c -Recurse -ErrorAction SilentlyContinue).Count
            @{ R = 'Aviso'; D = "parte das subchaves sem permissao ($resto restante(s)) - normal em algumas chaves protegidas; nao impede a reinstalacao" }
        } else { @{ R = 'OK'; D = 'apagada' } }
    }
}

# ---------------- 7) WMI e certificados ----------------
$G = '7. WMI e certificados'
foreach ($ns in @(@('root', 'ccm'), @('root\cimv2', 'sms'))) {
    $alvo = "$($ns[0])\$($ns[1])"
    $o = Get-CimInstance -Namespace $ns[0] -ClassName __Namespace -Filter "Name='$($ns[1])'" -ErrorAction SilentlyContinue
    if (-not $o) { Add-Etapa $G "Remover namespace WMI $alvo" 'Ignorado' 'nao existe'; continue }
    Invoke-Etapa $G "Remover namespace WMI $alvo" $alvo { $o | Remove-CimInstance -ErrorAction Stop; @{ R = 'OK'; D = 'removido' } }
}
$certs = @(Get-ChildItem Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue)
if ($certs.Count) { Invoke-Etapa $G 'Remover certificados SMS' 'Cert:\LocalMachine\SMS' { $certs | Remove-Item -Force -ErrorAction Stop; @{ R = 'OK'; D = "$($certs.Count) certificado(s) removido(s) - serao recriados na reinstalacao" } } }
else { Add-Etapa $G 'Remover certificados SMS' 'Ignorado' 'nenhum certificado' }

# ---------------- 8) firewall (opcional) ----------------
$G = '8. Firewall (opcional)'
if ($ConfigurarFirewall) {
    # grupos pelo nome interno (funciona em Windows em portugues ou ingles)
    $grupos = [ordered]@{
        '@FirewallAPI.dll,-34251' = 'Instrumentacao de Gerenciamento do Windows (WMI)'
        '@FirewallAPI.dll,-28502' = 'Compartilhamento de Arquivos e Impressoras'
        '@FirewallAPI.dll,-29502' = 'Gerenciamento Remoto de Servico'
        '@FirewallAPI.dll,-29252' = 'Gerenciamento Remoto do Log de Eventos'
        '@FirewallAPI.dll,-33252' = 'Gerenciamento Remoto de Tarefas Agendadas'
        '@FirewallAPI.dll,-30002' = 'Gerenciamento Remoto do Firewall do Windows'
    }
    foreach ($g in $grupos.Keys) {
        Invoke-Etapa $G "Habilitar: $($grupos[$g])" "firewall $g" {
            $r = @(Get-NetFirewallRule -Group $g -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq 'Inbound' })
            if (-not $r.Count) { return @{ R = 'Ignorado'; D = 'grupo nao existe nesta versao do Windows' } }
            $r | Enable-NetFirewallRule -ErrorAction Stop
            @{ R = 'OK'; D = "$($r.Count) regra(s) de entrada habilitada(s)" }
        }
    }
} else { Add-Etapa $G 'Regras de gerenciamento remoto' 'Ignorado' 'nao solicitado (use -ConfigurarFirewall)' }

# ---------------- 9) WMI (opcional) ----------------
$G = '9. Repositorio WMI (opcional)'
if ($RedefinirWMI) {
    Invoke-Etapa $G 'Verificar repositorio' 'winmgmt /verifyrepository' { $o = (& winmgmt.exe /verifyrepository 2>&1 | Out-String).Trim(); @{ R = 'OK'; D = $o } }
    Invoke-Etapa $G 'Redefinir repositorio' 'winmgmt /resetrepository' {
        $o = (& winmgmt.exe /resetrepository 2>&1 | Out-String).Trim()
        @{ R = $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'Aviso' }); D = "$o (codigo $LASTEXITCODE)" }
    }
} else { Add-Etapa $G 'Redefinir repositorio WMI' 'Ignorado' 'nao solicitado (use -RedefinirWMI so se o WMI estiver com problema)' }

# ---------------- 10) verificacao final ----------------
$G = '10. Verificacao final'
$depois = Get-Estado
$restam = @($depois.GetEnumerator() | Where-Object { $_.Value -notin 'nao existe', '0', 'Stopped' })
if ($Simulacao) { Add-Etapa $G 'Conferencia' 'Simulado' 'simulacao: nada foi alterado' }
elseif ($restam.Count) { Add-Etapa $G 'Conferencia' 'Aviso' "ainda resta: $(($restam | ForEach-Object { $_.Key }) -join '; ') - reinicie e rode de novo" }
else { Add-Etapa $G 'Conferencia' 'OK' 'nenhum resto do cliente SCCM encontrado' }
Add-Etapa $G 'Proximo passo' $(if ($Simulacao) { 'Simulado' } else { 'OK' }) 'reiniciar a maquina e reinstalar o cliente (ccmsetup.exe ou pelo console do SCCM)'

# ---------------- painel HTML ----------------
$erros = @($Etapas | Where-Object { $_.Resultado -eq 'Erro' }).Count
$avisos = @($Etapas | Where-Object { $_.Resultado -eq 'Aviso' }).Count
$situacao = if ($Simulacao) { 'SIMULACAO (-WhatIf) - nada foi alterado' } elseif ($erros) { "Concluido com $erros erro(s)" } elseif ($avisos) { "Concluido com $avisos aviso(s)" } else { 'Concluido com sucesso' }
$dur = (Get-Date) - $inicio
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$dados = [ordered]@{
    titulo      = 'Limpeza do cliente SCCM'
    subtitulo   = "$env:COMPUTERNAME - $($inicio.ToString('dd/MM/yyyy HH:mm')) - executado por $env:USERDOMAIN\$env:USERNAME"
    situacao    = $situacao
    computador  = $env:COMPUTERNAME
    liberado    = $(if ($Simulacao) { Format-Tam $tamAntes } else { Format-Tam $liberado })
    duracao     = $(if ($dur.TotalMinutes -ge 1) { '{0}m {1:00}s' -f [math]::Floor($dur.TotalMinutes), $dur.Seconds } else { '{0:N0} s' -f $dur.TotalSeconds })
    info        = @(
        , @('Computador', $env:COMPUTERNAME)
        , @('Sistema', "$($os.Caption) $($os.Version)")
        , @('Cliente SCCM (antes)', $(if ($versao) { "$versao$(if ($site) { " - site $site" })" } else { 'nao identificado' }))
        , @('Opcoes', "Firewall: $(if ($ConfigurarFirewall) { 'sim' } else { 'nao' }) | Redefinir WMI: $(if ($RedefinirWMI) { 'sim' } else { 'nao' }) | Reiniciar: $(if ($Reiniciar) { 'sim' } else { 'nao' })")
    )
    etapas      = $Etapas.ToArray()
    comparativo = @(foreach ($k in $antes.Keys) { , @($k, $antes[$k], $(if ($Simulacao) { '(simulacao)' } else { $depois[$k] })) })
    rodape      = @("Log completo: $base.log", 'Avisos de arquivos em uso ou de servicos que nao pararam normalmente se resolvem reiniciando a maquina e rodando o script de novo.')
}

# ---------------- modelo do painel ----------------
$Modelo = @'
<!doctype html>
<html lang="pt-br"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Limpeza do cliente SCCM</title>
<style>
:root{--ink:#1f2933;--mut:#627d98;--line:#e4e9f0;--bg:#f2f5f9;--ok:#15803d;--av:#b45309;--er:#b91c1c;--ig:#64748b;--si:#1d4ed8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font-family:"Segoe UI",Roboto,Arial,sans-serif}
header{background:linear-gradient(120deg,#0f2b5b,#1d4ed8);color:#fff;padding:24px 36px}
header h1{margin:0;font-size:23px}header .sub{opacity:.85;font-size:13px;margin-top:6px}
.banner{margin-top:12px;display:inline-block;padding:6px 14px;border-radius:20px;font-weight:700;font-size:13px;background:rgba(255,255,255,.18)}
main{padding:22px 36px;max-width:1300px;margin:0 auto}
.info{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:8px 24px;background:#fff;border-radius:12px;padding:14px 18px;box-shadow:0 1px 4px rgba(15,43,91,.06);font-size:13px;margin-bottom:16px}
.info b{display:block;color:var(--mut);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:18px}
.card{background:#fff;border-radius:12px;padding:14px 16px;box-shadow:0 1px 4px rgba(15,43,91,.08);border-left:6px solid #cbd5e1;cursor:pointer}
.card.on{outline:3px solid #1d4ed8}.card .n{font-size:26px;font-weight:800;line-height:1;white-space:nowrap}.card .l{font-size:11px;color:var(--mut);margin-top:7px;text-transform:uppercase;letter-spacing:.04em}
h2{font-size:16px;color:#334e68;margin:22px 0 10px}
.panel{background:#fff;border-radius:12px;padding:6px 0;box-shadow:0 1px 4px rgba(15,43,91,.06);overflow:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
th{background:#0f2b5b;color:#fff;text-align:left;padding:9px 12px;white-space:nowrap}
td{padding:8px 12px;border-top:1px solid var(--line);vertical-align:top}
tr.grp td{background:#eef2f7;font-weight:700;color:#334e68;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.tag{display:inline-block;padding:2px 9px;border-radius:12px;font-size:11.5px;font-weight:700;color:#fff;white-space:nowrap}
.det{color:#334e68}.mut{color:var(--mut);font-size:12px}
.foot{color:var(--mut);font-size:12px;margin-top:16px;line-height:1.6}
@media print{.card{cursor:default}}
</style></head><body>
<header><h1 id="tit"></h1><div class="sub" id="sub"></div><div class="banner" id="ban"></div></header>
<main>
<div class="info" id="info"></div>
<div class="cards" id="cards"></div>
<h2>Etapas executadas</h2>
<div class="panel"><table id="et"><thead><tr><th>#</th><th>Etapa</th><th>Resultado</th><th>Detalhe</th><th>Tempo</th></tr></thead><tbody></tbody></table></div>
<h2>Antes x depois</h2>
<div class="panel"><table id="cmp"><thead><tr><th>Item</th><th>Antes</th><th>Depois</th></tr></thead><tbody></tbody></table></div>
<div class="foot" id="foot"></div>
</main>
<script>
var R = __DADOS__;
var COR = { 'OK': 'var(--ok)', 'Aviso': 'var(--av)', 'Erro': 'var(--er)', 'Ignorado': 'var(--ig)', 'Simulado': 'var(--si)' };
var filtro = '';
function e(s) { return (s == null ? '' : String(s)).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
function tag(r) { return '<span class="tag" style="background:' + (COR[r] || 'var(--ig)') + '">' + e(r) + '</span>'; }
function etapas() {
  var h = '', g = '';
  R.etapas.forEach(function (x) {
    if (filtro && x.Resultado !== filtro) return;
    if (x.Grupo !== g) { g = x.Grupo; h += '<tr class="grp"><td colspan="5">' + e(g) + '</td></tr>'; }
    h += '<tr><td>' + x.N + '</td><td>' + e(x.Etapa) + '</td><td>' + tag(x.Resultado) + '</td><td class="det">' + e(x.Detalhe) + '</td><td class="mut">' + e(x.Tempo) + '</td></tr>';
  });
  document.querySelector('#et tbody').innerHTML = h || '<tr><td colspan="5">Nenhuma etapa com esse resultado.</td></tr>';
}
function cards() {
  var c = {}; R.etapas.forEach(function (x) { c[x.Resultado] = (c[x.Resultado] || 0) + 1; });
  var h = '<div class="card on" data-r="" style="border-left-color:#1d4ed8"><div class="n" style="color:#1d4ed8">' + R.etapas.length + '</div><div class="l">Etapas</div></div>';
  ['OK', 'Aviso', 'Erro', 'Simulado', 'Ignorado'].forEach(function (k) {
    if (!c[k] && (k === 'Simulado' || k === 'Ignorado')) return;
    h += '<div class="card" data-r="' + k + '" style="border-left-color:' + COR[k] + '"><div class="n" style="color:' + COR[k] + '">' + (c[k] || 0) + '</div><div class="l">' + k + '</div></div>';
  });
  h += '<div class="card" style="border-left-color:#0f766e;cursor:default"><div class="n" style="color:#0f766e">' + e(R.liberado) + '</div><div class="l">Espaco liberado</div></div>';
  h += '<div class="card" style="border-left-color:#475569;cursor:default"><div class="n" style="color:#475569">' + e(R.duracao) + '</div><div class="l">Duracao</div></div>';
  var el = document.getElementById('cards'); el.innerHTML = h;
  el.querySelectorAll('.card[data-r]').forEach(function (k) {
    k.onclick = function () { el.querySelectorAll('.card').forEach(function (x) { x.classList.remove('on'); }); k.classList.add('on'); filtro = k.getAttribute('data-r'); etapas(); };
  });
}
document.getElementById('tit').textContent = R.titulo;
document.getElementById('sub').textContent = R.subtitulo;
document.getElementById('ban').textContent = R.situacao;
document.getElementById('info').innerHTML = R.info.map(function (i) { return '<div><b>' + e(i[0]) + '</b>' + e(i[1]) + '</div>'; }).join('');
document.querySelector('#cmp tbody').innerHTML = R.comparativo.map(function (c) { return '<tr><td>' + e(c[0]) + '</td><td>' + e(c[1]) + '</td><td>' + e(c[2]) + '</td></tr>'; }).join('');
document.getElementById('foot').innerHTML = R.rodape.map(e).join('<br>');
document.title = R.titulo + ' - ' + R.computador;
cards(); etapas();
</script>
</body></html>

'@

$json = (ConvertTo-Json -InputObject $dados -Depth 5 -Compress) -replace '</', '<\/'
[IO.File]::WriteAllText("$base.html", $Modelo.Replace('__DADOS__', $json), (New-Object System.Text.UTF8Encoding($true)))
Write-Host "`n$situacao" -ForegroundColor $(if ($erros) { 'Red' } elseif ($avisos -or $Simulacao) { 'Yellow' } else { 'Green' })
Write-Host "Painel: $base.html" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
if (-not $NaoAbrir) { try { Start-Process "$base.html" } catch { } }
if ($Reiniciar -and -not $Simulacao) { Write-Host 'Reiniciando em 60 segundos (shutdown /a cancela)...' -ForegroundColor Yellow; shutdown.exe /r /t 60 /c 'Reinicio apos limpeza do cliente SCCM' }
