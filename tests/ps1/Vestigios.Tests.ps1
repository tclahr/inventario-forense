BeforeAll {
    . "$PSScriptRoot/../../InventarioForense.ps1"
    if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) { function global:Get-WinEvent { param($FilterHashtable) } }
    function New-EvtMsi {
        param([int]$Id, [string]$Msg = '...', $Props = @())
        [pscustomobject]@{ Id = $Id; TimeCreated = [datetime]'2026-02-03 10:00:00'; UserId = $null; Properties = $Props; Message = $Msg }
    }
    $Script:Perfil = [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; Usuario = 'PC\ana'; RaizUsuario = 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001'; RaizClasses = 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001_Classes'; Disponivel = $true }
}

Describe 'Get-VestigioEventoMsi' {
    It '1034 vira Removido' {
        Mock Get-WinEvent { New-EvtMsi -Id 1034 -Props @(@{Value='SolidWorks 2022'},@{Value='30.1'},@{Value='1033'},@{Value='0'},@{Value='Dassault'}) }
        $r = @(Get-VestigioEventoMsi)
        $r.Count | Should -Be 1
        $r[0].Item | Should -Be 'SolidWorks 2022'
        $r[0].Versao | Should -Be '30.1'
        $r[0].Fabricante | Should -Be 'Dassault'
        $r[0].TipoData | Should -Be 'Removido'
        $r[0].Data | Should -Be '2026-02-03 10:00:00'
        $r[0].Detalhe | Should -Be 'EventId=1034;Status=0'
        $r[0].Fonte | Should -Be 'EventoMSI'
    }
    It 'UserId SID e traduzido' {
        $e = New-EvtMsi -Id 1033 -Props @(@{Value='P'},@{Value='1'},@{Value='1033'},@{Value='0'},@{Value='F'})
        # SecurityIdentifier nao e suportado no Linux; o codigo so usa .Value
        $e.UserId = [pscustomobject]@{ Value = 'S-1-5-18' }
        Mock Get-WinEvent { $e }
        @(Get-VestigioEventoMsi)[0].Usuario | Should -Be 'SYSTEM'
    }
    It '11707 extrai da mensagem' {
        Mock Get-WinEvent { New-EvtMsi -Id 11707 -Msg 'Product: CorelDRAW X8 -- Installation completed successfully.' }
        $r = @(Get-VestigioEventoMsi)
        $r[0].Item | Should -Be 'CorelDRAW X8'
        $r[0].TipoData | Should -Be 'Instalado'
    }
    It '11724 em portugues extrai Produto da mensagem' {
        Mock Get-WinEvent { New-EvtMsi -Id 11724 -Msg 'Produto: Programa X -- Remoção concluída com êxito.' }
        $r = @(Get-VestigioEventoMsi)
        $r[0].Item | Should -Be 'Programa X'
        $r[0].TipoData | Should -Be 'Removido'
        $r[0].Detalhe | Should -Be 'EventId=11724'
    }
    It '1033 com EventData incompleto nao usa o idioma como fabricante' {
        Mock Get-WinEvent { New-EvtMsi -Id 1033 -Props @(@{Value='P'},@{Value='1'},@{Value='1046'},@{Value='0'}) }
        $r = @(Get-VestigioEventoMsi)
        $r[0].Fabricante | Should -Be ''
        $r[0].Detalhe | Should -Be 'EventId=1033;Status=0'
    }
    It 'sem eventos (ingles e portugues) devolve vazio' {
        Mock Get-WinEvent { throw [Exception]'No events were found that match the specified selection criteria.' }
        { Get-VestigioEventoMsi } | Should -Not -Throw
        @(Get-VestigioEventoMsi).Count | Should -Be 0
        Mock Get-WinEvent { throw [Exception]'Não foi encontrado nenhum evento' }
        @(Get-VestigioEventoMsi).Count | Should -Be 0
    }
    It 'outra excecao propaga' {
        Mock Get-WinEvent { throw [Exception]'Acesso negado' }
        { Get-VestigioEventoMsi } | Should -Throw
    }
}

Describe 'Get-VestigioBam' {
    It 'le valores byte[] e ignora Version/SequenceNumber' {
        $ft = (Get-Date '2026-03-01 12:00:00').ToFileTime()
        $bytes = New-Object byte[] 24
        [BitConverter]::GetBytes([long]$ft).CopyTo($bytes, 0)
        Mock Get-RegSubchaves { @('S-1-5-18') } -ParameterFilter { $Caminho -like '*\bam\State\UserSettings' }
        Mock Get-RegSubchaves { @() } -ParameterFilter { $Caminho -like '*\dam\State\UserSettings' }
        Mock Get-RegValores { @{ '\Device\HarddiskVolume3\Tools\x.exe' = $bytes; Version = 1; SequenceNumber = 5 } }
        $r = @(Get-VestigioBam)
        $r.Count | Should -Be 1
        $r[0].Caminho | Should -Be '\Device\HarddiskVolume3\Tools\x.exe'
        $r[0].Item | Should -Be 'x.exe'
        $r[0].TipoData | Should -Be 'UltimaExecucao'
        $r[0].Data | Should -Be '2026-03-01 12:00:00'
        $r[0].Usuario | Should -Be 'SYSTEM'
        $r[0].Fonte | Should -Be 'BAM'
        $r[0].Detalhe | Should -Be 'Servico=bam'
    }
}

Describe 'Get-VestigioUserAssist' {
    It 'decodifica ROT13' {
        $b = New-Object byte[] 72
        [BitConverter]::GetBytes([uint32]7).CopyTo($b, 4)
        [BitConverter]::GetBytes([long](Get-Date '2026-05-06 07:08:09').ToFileTime()).CopyTo($b, 60)
        Mock Get-RegSubchaves { @('{G}') } -ParameterFilter { $Caminho -like '*\UserAssist' }
        Mock Get-RegSubchaves { @() }
        Mock Get-RegValores { @{ 'P:\Cebtenz Svyrf\K\k.rkr' = $b } } -ParameterFilter { $Caminho -like '*\{G}\Count' }
        $r = @(Get-VestigioUserAssist -Perfis @($Script:Perfil))
        $r.Count | Should -Be 1
        $r[0].Item | Should -Be 'C:\Program Files\X\x.exe'
        $r[0].Detalhe | Should -Be 'Execucoes=7'
        $r[0].Data | Should -Be '2026-05-06 07:08:09'
        $r[0].Fonte | Should -Be 'UserAssist'
        $r[0].TipoData | Should -Be 'UltimaExecucao'
    }
    It 'ignora valor de 16 bytes' {
        Mock Get-RegSubchaves { @('{G}') } -ParameterFilter { $Caminho -like '*\UserAssist' }
        Mock Get-RegSubchaves { @() }
        Mock Get-RegValores { @{ 'abc' = (New-Object byte[] 16) } }
        @(Get-VestigioUserAssist -Perfis @($Script:Perfil)).Count | Should -Be 0
    }
    It 'aceita Perfis nulo' {
        @(Get-VestigioUserAssist -Perfis $null).Count | Should -Be 0
    }
}

Describe 'Get-VestigioMuiCache' {
    It 'junta empresa pelo caminho' {
        Mock Get-RegValores { @{ 'C:\a\b.exe.FriendlyAppName' = 'B App'; 'C:\a\b.exe.ApplicationCompany' = 'Fab' } }
        $r = @(Get-VestigioMuiCache -Perfis @($Script:Perfil))
        $r.Count | Should -Be 1
        $r[0].Caminho | Should -Be 'C:\a\b.exe'
        $r[0].Item | Should -Be 'B App'
        $r[0].Fabricante | Should -Be 'Fab'
        $r[0].Fonte | Should -Be 'MUICache'
    }
    It 'pula FriendlyAppName vazio' {
        Mock Get-RegValores { @{ 'C:\a\b.exe.FriendlyAppName' = '' } }
        @(Get-VestigioMuiCache -Perfis @($Script:Perfil)).Count | Should -Be 0
    }
    It 'pula perfil sem RaizClasses' {
        Mock Get-RegValores { @{ 'C:\a\b.exe.FriendlyAppName' = 'B App' } }
        $p = [pscustomobject]@{ SID = 'S'; Usuario = 'u'; RaizUsuario = 'Registry::X'; RaizClasses = ''; Disponivel = $true }
        @(Get-VestigioMuiCache -Perfis @($p)).Count | Should -Be 0
    }
}

Describe 'Get-VestigioCompatAssistant' {
    It 'nome do valor vira Caminho' {
        Mock Get-RegValores { @{ 'C:\x\setup.exe' = 4 } }
        $r = @(Get-VestigioCompatAssistant -Perfis @($Script:Perfil))
        $r[0].Caminho | Should -Be 'C:\x\setup.exe'
        $r[0].Item | Should -Be 'setup.exe'
        $r[0].Fonte | Should -Be 'CompatAssistant'
    }
}

Describe 'Get-VestigioChaveSoftware' {
    It 'exclui Microsoft e Classes' {
        Mock Get-RegSubchaves { @('Microsoft', 'Adobe', 'Classes') } -ParameterFilter { $Caminho -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE' }
        Mock Get-RegSubchaves { @('Photoshop') } -ParameterFilter { $Caminho -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Adobe' }
        Mock Get-RegSubchaves { @() }
        Mock Get-RegUltimaEscrita { '2026-01-01 00:00:00' }
        $r = @(Get-VestigioChaveSoftware -Perfis @())
        $r.Count | Should -Be 1
        $r[0].Fabricante | Should -Be 'Adobe'
        $r[0].Item | Should -Be 'Photoshop'
        $r[0].TipoData | Should -Be 'ChaveModificada'
        $r[0].Fonte | Should -Be 'ChaveSoftware'
        $r[0].Caminho | Should -Be 'HKEY_LOCAL_MACHINE\SOFTWARE\Adobe\Photoshop'
        Should -Invoke Get-RegUltimaEscrita -ParameterFilter { $Caminho -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Adobe\Photoshop' }
    }
    It 'fabricante sem subchave gera linha propria' {
        Mock Get-RegSubchaves { @('Solo') } -ParameterFilter { $Caminho -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE' }
        Mock Get-RegSubchaves { @() }
        Mock Get-RegUltimaEscrita { '' }
        $r = @(Get-VestigioChaveSoftware -Perfis @())
        $r.Count | Should -Be 1
        $r[0].Item | Should -Be 'Solo'
        $r[0].Fabricante | Should -Be 'Solo'
    }
}

Describe 'Vestigios parte 2' {
    BeforeAll {
        foreach ($n in 'reg.exe', 'esentutl.exe') {
            if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { Set-Item -Path "function:global:$n" -Value { } }
        }
        foreach ($n in 'Get-NetFirewallRule', 'Get-NetFirewallApplicationFilter', 'Get-MpThreatDetection', 'Get-MpThreat') {
            if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { Set-Item -Path "function:global:$n" -Value { } }
        }
    }
    BeforeEach {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.Admin = $true
        Mock Write-Host { }
    }

    Context 'Prefetch' {
        It 'Prefetch nome e hash' {
            $orig = Join-Path $TestDrive 'pf'
            $dest = Join-Path $TestDrive 'brutos/Prefetch'
            $null = New-Item -ItemType Directory -Path $orig -Force
            $pf = Join-Path $orig 'CHROME.EXE-ABCD1234.pf'
            [System.IO.File]::WriteAllBytes($pf, [byte[]](1, 2, 3))
            [System.IO.File]::SetLastWriteTime($pf, [datetime]'2026-04-05 06:07:08')
            $r = @(Get-VestigioPrefetch -Destino $dest -Pasta $orig)
            $r.Count | Should -Be 2
            $r | ForEach-Object { $_.Item | Should -Be 'CHROME.EXE' }
            $r | ForEach-Object { $_.Detalhe | Should -Be 'HashCaminho=ABCD1234' }
            $r | ForEach-Object { $_.Fonte | Should -Be 'Prefetch' }
            @($r.TipoData | Sort-Object) | Should -Be @('PrimeiraExecucao', 'UltimaExecucao')
            ($r | Where-Object TipoData -eq 'UltimaExecucao').Data | Should -Be '2026-04-05 06:07:08'
            ($r | Where-Object TipoData -eq 'PrimeiraExecucao').Data | Should -Be (ConvertTo-DataTexto ([System.IO.File]::GetCreationTime($pf)))
            $copia = Join-Path $dest 'CHROME.EXE-ABCD1234.pf'
            Test-Path $copia | Should -BeTrue
            [System.IO.File]::ReadAllBytes($copia) | Should -Be @(1, 2, 3)
            [System.IO.File]::GetLastWriteTime($copia) | Should -Be ([datetime]'2026-04-05 06:07:08')
        }
    }

    Context 'Amcache' {
        BeforeEach {
            $Script:Bruto = Join-Path $TestDrive 'brutos/Amcache'
            $null = New-Item -ItemType Directory -Path $Script:Bruto -Force
            $Script:Hve = Join-Path $Script:Bruto 'Amcache.hve'
            [System.IO.File]::WriteAllBytes($Script:Hve, [byte[]](9, 8, 7))
            [System.IO.File]::WriteAllBytes($Script:Hve + '.LOG1', [byte[]](5))
            $Script:Tmp = Join-Path $TestDrive '_tmp'
            $Script:ArgsReg = New-Object System.Collections.Generic.List[string]
            Mock reg.exe { $Script:ArgsReg.Add(($args -join '|')); $global:LASTEXITCODE = 0 }
            Mock Dismount-HivesColeta { }
        }
        It 'Amcache SHA1 sem prefixo' {
            $raiz = 'Registry::HKEY_LOCAL_MACHINE\COLETA_AMCACHE\Root'
            Mock Get-RegSubchaves { @('f1') } -ParameterFilter { $Caminho -eq ($raiz + '\InventoryApplicationFile') }
            Mock Get-RegSubchaves { @('p1') } -ParameterFilter { $Caminho -eq ($raiz + '\InventoryApplication') }
            Mock Get-RegSubchaves { @() }
            Mock Get-RegValores { @{ FileId = '0000aabbcc'; Name = 'x.exe'; LowerCaseLongPath = 'c:\x\x.exe'; Publisher = 'Fab'; Version = '1.2'; LinkDate = '03/15/2023 10:20:30'; ProgramId = 'p1' } } -ParameterFilter { $Caminho -eq ($raiz + '\InventoryApplicationFile\f1') }
            Mock Get-RegValores { @{ Name = 'App X'; Publisher = 'Fab'; Version = '1.2'; InstallDate = '03/14/2023 01:02:03'; Source = 'MSI'; RootDirPath = 'C:\x'; UninstallString = 'msiexec /x' } } -ParameterFilter { $Caminho -eq ($raiz + '\InventoryApplication\p1') }
            $r = @(Get-VestigioAmcache -CopiaHve $Script:Hve -PastaTmp $Script:Tmp)
            $r.Count | Should -Be 2
            $a = $r | Where-Object Fonte -eq 'Amcache'
            $a.Item | Should -Be 'App X'
            $a.Data | Should -Be '2023-03-14 01:02:03'
            $a.TipoData | Should -Be 'Instalado'
            $a.Caminho | Should -Be 'C:\x'
            $a.Detalhe | Should -Be 'Origem=MSI;Desinstalador=msiexec /x;ProgramId=p1'
            $f = $r | Where-Object Fonte -eq 'AmcacheArquivo'
            $f.Detalhe | Should -BeLike 'SHA1=aabbcc*'
            $f.Detalhe | Should -Be 'SHA1=aabbcc;ProgramId=p1'
            $f.Caminho | Should -Be 'c:\x\x.exe'
            $f.TipoData | Should -Be 'ArquivoCompilado'
            $f.Data | Should -Be '2023-03-15 10:20:30'
            # monta a SEGUNDA copia, em <PastaTmp>\amcache
            $Script:ArgsReg.Count | Should -Be 1
            $Script:ArgsReg[0] | Should -Be ('load|HKLM\COLETA_AMCACHE|' + (Join-Path (Join-Path $Script:Tmp 'amcache') 'Amcache.hve'))
            Test-Path (Join-Path (Join-Path $Script:Tmp 'amcache') 'Amcache.hve.LOG1') | Should -BeTrue
            $Script:Ctx.HivesMontadas | Should -Contain 'HKLM\COLETA_AMCACHE'
            Should -Invoke Dismount-HivesColeta -Times 1 -Exactly -ParameterFilter { @($Somente).Count -eq 1 -and $Somente[0] -eq 'HKLM\COLETA_AMCACHE' }
            [System.IO.File]::ReadAllBytes($Script:Hve) | Should -Be @(9, 8, 7)
        }
        It 'desmonta so a propria hive mesmo quando a leitura lanca' {
            Mock Get-RegSubchaves { throw 'falha leitura' }
            { Get-VestigioAmcache -CopiaHve $Script:Hve -PastaTmp $Script:Tmp } | Should -Throw '*falha leitura*'
            Should -Invoke Dismount-HivesColeta -Times 1 -Exactly -ParameterFilter { @($Somente).Count -eq 1 -and $Somente[0] -eq 'HKLM\COLETA_AMCACHE' }
            Should -Invoke Dismount-HivesColeta -Times 0 -Exactly -ParameterFilter { $null -eq $Somente }
        }
        It 'nome padrao ocupado usa COLETA_AMCACHE_2 sem desmontar a sobra' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\COLETA_AMCACHE' }
            Mock Get-RegSubchaves { @() }
            $null = @(Get-VestigioAmcache -CopiaHve $Script:Hve -PastaTmp $Script:Tmp)
            $Script:ArgsReg.Count | Should -Be 1
            $Script:ArgsReg[0] | Should -BeLike 'load|HKLM\COLETA_AMCACHE_2|*'
            $Script:Ctx.HivesMontadas | Should -Contain 'HKLM\COLETA_AMCACHE_2'
            $Script:Ctx.HivesMontadas | Should -Not -Contain 'HKLM\COLETA_AMCACHE'
            Should -Invoke Get-RegSubchaves -ParameterFilter { $Caminho -eq 'Registry::HKEY_LOCAL_MACHINE\COLETA_AMCACHE_2\Root\InventoryApplication' }
            Should -Invoke Dismount-HivesColeta -Times 1 -Exactly -ParameterFilter { @($Somente).Count -eq 1 -and $Somente[0] -eq 'HKLM\COLETA_AMCACHE_2' }
            Should -Invoke Dismount-HivesColeta -Times 0 -Exactly -ParameterFilter { $Somente -contains 'HKLM\COLETA_AMCACHE' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*AVISO*COLETA_AMCACHE ja esta montada*' }
        }
        It 'reg load com falha lanca com a saida' {
            Mock reg.exe { $global:LASTEXITCODE = 1; 'acesso negado' }
            { Get-VestigioAmcache -CopiaHve $Script:Hve -PastaTmp $Script:Tmp } | Should -Throw '*acesso negado*'
            $Script:Ctx.HivesMontadas | Should -Not -Contain 'HKLM\COLETA_AMCACHE'
        }
    }

    Context 'Copy-BrutoAmcache' {
        It 'Copy-BrutoAmcache falha lanca' {
            Mock esentutl.exe { $global:LASTEXITCODE = 1; 'erro x' }
            { Copy-BrutoAmcache -Destino (Join-Path $TestDrive 'ba') } | Should -Throw '*erro x*'
            @($Script:Ctx.Escritas | Where-Object { $_ -like 'esentutl /vss*' }).Count | Should -Be 1
        }
        It 'copia hve e LOGs existentes com /vss' {
            $o = Join-Path $TestDrive 'orig'
            $null = New-Item -ItemType Directory -Path $o -Force
            $hve = Join-Path $o 'Amcache.hve'
            [System.IO.File]::WriteAllBytes($hve, [byte[]](1))
            [System.IO.File]::WriteAllBytes($hve + '.LOG2', [byte[]](2))
            $Script:ArgsEse = New-Object System.Collections.Generic.List[string]
            Mock esentutl.exe { $Script:ArgsEse.Add(($args -join '|')); $global:LASTEXITCODE = 0 }
            $d = Join-Path $TestDrive 'ba2'
            $c = Copy-BrutoAmcache -Destino $d -Origem $hve
            $c | Should -Be (Join-Path $d 'Amcache.hve')
            Test-Path $d | Should -BeTrue
            $Script:ArgsEse.Count | Should -Be 2
            $Script:ArgsEse[0] | Should -Be ('/y|' + $hve + '|/vss|/d|' + (Join-Path $d 'Amcache.hve'))
            $Script:ArgsEse[1] | Should -Be ('/y|' + $hve + '.LOG2|/vss|/d|' + (Join-Path $d 'Amcache.hve.LOG2'))
            # LOG1 ausente nao e erro; um registro de escrita por snapshot
            @($Script:Ctx.Escritas | Where-Object { $_ -like 'esentutl /vss*' }).Count | Should -Be 2
        }
        It 'falha ao copiar LOG existente lanca com a saida' {
            $o = Join-Path $TestDrive 'orig3'
            $null = New-Item -ItemType Directory -Path $o -Force
            $hve = Join-Path $o 'Amcache.hve'
            [System.IO.File]::WriteAllBytes($hve, [byte[]](1))
            [System.IO.File]::WriteAllBytes($hve + '.LOG1', [byte[]](2))
            Mock esentutl.exe { if (($args -join ' ') -like '*.LOG1 *') { $global:LASTEXITCODE = 5; 'log travado' } else { $global:LASTEXITCODE = 0 } }
            $d = Join-Path $TestDrive 'ba3'
            { Copy-BrutoAmcache -Destino $d -Origem $hve } | Should -Throw '*log travado*'
            @($Script:Ctx.Escritas | Where-Object { $_ -like 'esentutl /vss*' }).Count | Should -Be 2
        }
    }

    Context 'ShimCache' {
        It 'converte o valor binario' {
            Mock Get-RegValores { @{ AppCompatCache = [byte[]](1, 2, 3, 4) } } -ParameterFilter { $Caminho -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache' }
            Mock ConvertFrom-ShimCache { [pscustomobject]@{ Posicao = 3; Caminho = 'C:\t\a.exe'; Modificado = '2026-01-02 03:04:05' } }
            $r = @(Get-VestigioShimCache)
            $r.Count | Should -Be 1
            $r[0].Fonte | Should -Be 'ShimCache'
            $r[0].Item | Should -Be 'a.exe'
            $r[0].Caminho | Should -Be 'C:\t\a.exe'
            $r[0].Data | Should -Be '2026-01-02 03:04:05'
            $r[0].TipoData | Should -Be 'ArquivoModificado'
            $r[0].Detalhe | Should -Be 'Posicao=3'
        }
        It 'cache sem entradas loga INFO e nao falha' {
            Mock Write-Log { }
            Mock Get-RegValores { @{ AppCompatCache = (New-Object byte[] 52) } } -ParameterFilter { $Caminho -like '*AppCompatCache' }
            Mock ConvertFrom-ShimCache { }
            @(Get-VestigioShimCache).Count | Should -Be 0
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Nivel -eq 'INFO' -and $Mensagem -eq 'AppCompatCache sem entradas (52 bytes, so cabecalho)' }
        }
    }

    Context 'InstallerCache' {
        It 'le propriedades e marca Erro leitura sem abortar' {
            $p = Join-Path $TestDrive 'inst'
            $null = New-Item -ItemType Directory -Path $p -Force
            [System.IO.File]::WriteAllBytes((Join-Path $p 'a1.msi'), [byte[]](1))
            [System.IO.File]::WriteAllBytes((Join-Path $p 'b2.msp'), [byte[]](1))
            [System.IO.File]::WriteAllBytes((Join-Path $p 'c3.txt'), [byte[]](1))
            Mock Get-MsiPropriedades { @{ ProductName = 'Prod A'; Manufacturer = 'Fab A'; ProductVersion = '2.0' } } -ParameterFilter { $Caminho -like '*a1.msi' }
            Mock Get-MsiPropriedades { throw 'ruim' } -ParameterFilter { $Caminho -like '*b2.msp' }
            $r = @(Get-VestigioInstallerCache -Pasta $p)
            $r.Count | Should -Be 2
            $a = $r | Where-Object Caminho -like '*a1.msi'
            $a.Item | Should -Be 'Prod A'
            $a.Fabricante | Should -Be 'Fab A'
            $a.Versao | Should -Be '2.0'
            $a.TipoData | Should -Be 'ArquivoCriado'
            $a.Fonte | Should -Be 'InstallerCache'
            $a.Data | Should -Not -BeNullOrEmpty
            $b = $r | Where-Object Caminho -like '*b2.msp'
            $b.Item | Should -Be 'b2.msp'
            $b.Detalhe | Should -Be 'Erro leitura'
        }
        It 'Get-MsiPropriedades abre .msp em modo 32 com MsiPatchMetadata' {
            $Script:Recs = @(@('DisplayName', 'Patch P'), @('ManufacturerName', 'Fab P'), @('Classification', 'Update'))
            $Script:Idx = 0
            Mock New-ObjetoCom { [pscustomobject]@{ T = 'inst' } } -ParameterFilter { $ProgId -eq 'WindowsInstaller.Installer' }
            Mock Invoke-ComMembro {
                switch ($Nome) {
                    'OpenDatabase' { [pscustomobject]@{ T = 'db' } }
                    'OpenView' { [pscustomobject]@{ T = 'view' } }
                    'Execute' { }
                    'Fetch' { if ($Script:Idx -lt $Script:Recs.Count) { $Script:Idx++; [pscustomobject]@{ T = 'rec'; V = $Script:Recs[$Script:Idx - 1] } } }
                    'StringData' { $Objeto.V[$Argumentos[0] - 1] }
                }
            }
            $h = Get-MsiPropriedades -Caminho 'C:\Windows\Installer\b.msp'
            $h.ProductName | Should -Be 'Patch P'
            $h.Manufacturer | Should -Be 'Fab P'
            [string]$h.ProductVersion | Should -Be ''
            $h.Count | Should -Be 2
            Should -Invoke Invoke-ComMembro -Times 1 -Exactly -ParameterFilter { $Nome -eq 'OpenDatabase' -and $Argumentos[1] -eq 32 }
            Should -Invoke Invoke-ComMembro -Times 1 -Exactly -ParameterFilter { $Nome -eq 'OpenView' -and $Argumentos[0] -eq 'SELECT Property, Value FROM MsiPatchMetadata' }
        }
        It 'Get-MsiPropriedades le a tabela Property via InvokeMember' {
            $Script:Recs = @(@('ProductName', 'P'), @('Manufacturer', 'M'), @('ProductVersion', '1.0'), @('Outro', 'x'))
            $Script:Idx = 0
            $Script:Chamadas = New-Object System.Collections.Generic.List[string]
            Mock New-ObjetoCom { [pscustomobject]@{ T = 'inst' } } -ParameterFilter { $ProgId -eq 'WindowsInstaller.Installer' }
            Mock Invoke-ComMembro {
                $Script:Chamadas.Add(('{0}:{1}' -f $Objeto.T, $Nome))
                switch ($Nome) {
                    'OpenDatabase' { [pscustomobject]@{ T = 'db' } }
                    'OpenView' { [pscustomobject]@{ T = 'view' } }
                    'Execute' { }
                    'Fetch' { if ($Script:Idx -lt $Script:Recs.Count) { $Script:Idx++; [pscustomobject]@{ T = 'rec'; V = $Script:Recs[$Script:Idx - 1] } } }
                    'StringData' { $Objeto.V[$Argumentos[0] - 1] }
                }
            }
            $h = Get-MsiPropriedades -Caminho 'C:\Windows\Installer\a.msi'
            $h.ProductName | Should -Be 'P'
            $h.Manufacturer | Should -Be 'M'
            $h.ProductVersion | Should -Be '1.0'
            $h.ContainsKey('Outro') | Should -BeFalse
            Should -Invoke Invoke-ComMembro -Times 1 -Exactly -ParameterFilter { $Nome -eq 'OpenDatabase' -and $Argumentos[0] -eq 'C:\Windows\Installer\a.msi' -and $Argumentos[1] -eq 0 }
            Should -Invoke Invoke-ComMembro -Times 1 -Exactly -ParameterFilter { $Nome -eq 'OpenView' -and $Argumentos[0] -eq 'SELECT Property, Value FROM Property' }
        }
    }

    Context 'Atalhos' {
        It 'Atalho alvo inexistente' {
            $perfil = Join-Path $TestDrive 'Users/ana'
            $desk = Join-Path $perfil 'Desktop'
            $null = New-Item -ItemType Directory -Path (Join-Path $desk 'sub') -Force
            [System.IO.File]::WriteAllBytes((Join-Path $desk 'sub/Programa X.lnk'), [byte[]](1))
            Mock New-ObjetoCom {
                $o = [pscustomobject]@{}
                $o | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value { param($c) [pscustomobject]@{ TargetPath = 'C:\nao\x.exe' } }
                $o
            } -ParameterFilter { $ProgId -eq 'WScript.Shell' }
            $p = [pscustomobject]@{ SID = 'S-1'; Usuario = 'PC\ana'; Caminho = $perfil; Disponivel = $true }
            $r = @(Get-VestigioAtalhos -Perfis @($p))
            $r.Count | Should -Be 1
            $r[0].Fonte | Should -Be 'Atalho'
            $r[0].Item | Should -Be 'Programa X'
            $r[0].Caminho | Should -Be 'C:\nao\x.exe'
            $r[0].TipoData | Should -Be 'ArquivoModificado'
            $r[0].Usuario | Should -Be 'PC\ana'
            $r[0].Detalhe | Should -BeLike ('Atalho=*Programa X.lnk;*')
            $r[0].Detalhe | Should -BeLike '*AlvoExiste=Nao'
        }
        It 'alvo vazio deixa AlvoExiste vazio' {
            $perfil = Join-Path $TestDrive 'Users/bia'
            $null = New-Item -ItemType Directory -Path (Join-Path $perfil 'Desktop') -Force
            [System.IO.File]::WriteAllBytes((Join-Path $perfil 'Desktop/Y.lnk'), [byte[]](1))
            Mock New-ObjetoCom {
                $o = [pscustomobject]@{}
                $o | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value { param($c) [pscustomobject]@{ TargetPath = '' } }
                $o
            } -ParameterFilter { $ProgId -eq 'WScript.Shell' }
            $p = [pscustomobject]@{ SID = 'S-2'; Usuario = 'PC\bia'; Caminho = $perfil; Disponivel = $true }
            $r = @(Get-VestigioAtalhos -Perfis @($p))
            $r[0].Detalhe | Should -BeLike '*;AlvoExiste='
        }
    }

    Context 'Firewall' {
        It 'junta filtro de aplicacao com a regra por InstanceID' {
            Mock Get-NetFirewallRule { [pscustomobject]@{ InstanceID = 'R1'; DisplayName = 'Regra X'; Direction = 'Inbound'; Action = 'Allow'; Enabled = 'True' } }
            Mock Get-NetFirewallApplicationFilter { [pscustomobject]@{ InstanceID = 'R1'; Program = 'C:\nao\fw.exe' }; [pscustomobject]@{ InstanceID = 'R2'; Program = 'Any' } }
            $r = @(Get-VestigioFirewall)
            $r.Count | Should -Be 1
            $r[0].Fonte | Should -Be 'Firewall'
            $r[0].Item | Should -Be 'Regra X'
            $r[0].Caminho | Should -Be 'C:\nao\fw.exe'
            $r[0].Data | Should -Be ''
            $r[0].Detalhe | Should -Be 'Direcao=Inbound;Acao=Allow;Habilitada=Sim;ProgramaExiste=Nao'
            Should -Invoke Get-NetFirewallRule -Times 1 -Exactly
        }
        It 'regra desabilitada vira Habilitada=Nao' {
            Mock Get-NetFirewallRule { [pscustomobject]@{ InstanceID = 'R1'; DisplayName = 'Regra Y'; Direction = 'Outbound'; Action = 'Block'; Enabled = 'False' } }
            Mock Get-NetFirewallApplicationFilter { [pscustomobject]@{ InstanceID = 'R1'; Program = 'C:\nao\fw.exe' } }
            @(Get-VestigioFirewall)[0].Detalhe | Should -Be 'Direcao=Outbound;Acao=Block;Habilitada=Nao;ProgramaExiste=Nao'
        }
    }

    Context 'Defender' {
        It 'deteccoes e eventos 1116/1117' {
            Mock Get-MpThreat { [pscustomobject]@{ ThreatID = 77; ThreatName = 'Trojan:Win32/X' } }
            Mock Get-MpThreatDetection { [pscustomobject]@{ ThreatID = 77; Resources = @('file:_C:\a.exe', 'file:_C:\b.exe'); InitialDetectionTime = [datetime]'2026-06-01 10:00:00'; ActionSuccess = $true; ProcessName = 'C:\p.exe' } }
            $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData><Data Name="Threat Name">HackTool:Y</Data><Data Name="Path">file:_C:\y.exe</Data></EventData></Event>'
            $ev = [pscustomobject]@{ Id = 1116; TimeCreated = [datetime]'2026-06-02 11:00:00' }
            $ev | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $xml }.GetNewClosure()
            Mock Get-WinEvent { $ev } -ParameterFilter { $FilterHashtable.LogName -eq 'Microsoft-Windows-Windows Defender/Operational' }
            $r = @(Get-VestigioDefender)
            $r.Count | Should -Be 2
            $d = $r | Where-Object Detalhe -like 'Acao=*'
            $d.Item | Should -Be 'Trojan:Win32/X'
            $d.Caminho | Should -Be 'file:_C:\a.exe; file:_C:\b.exe'
            $d.Data | Should -Be '2026-06-01 10:00:00'
            $d.TipoData | Should -Be 'Deteccao'
            $d.Detalhe | Should -Be 'Acao=Sim;Processo=C:\p.exe'
            $e = $r | Where-Object Detalhe -eq 'EventId=1116'
            $e.Item | Should -Be 'HackTool:Y'
            $e.Caminho | Should -Be 'file:_C:\y.exe'
            $e.TipoData | Should -Be 'Deteccao'
            $e.Fonte | Should -Be 'Defender'
        }
        It 'nome cai para ThreatID sem Get-MpThreat' {
            Mock Get-MpThreat { }
            Mock Get-MpThreatDetection { [pscustomobject]@{ ThreatID = 88; Resources = @(); InitialDetectionTime = $null; ActionSuccess = $false; ProcessName = '' } }
            Mock Get-WinEvent { throw [Exception]'No events were found that match the specified selection criteria.' }
            $r = @(Get-VestigioDefender)
            $r.Count | Should -Be 1
            $r[0].Item | Should -Be '88'
            $r[0].Detalhe | Should -Be 'Acao=Nao;Processo='
        }
    }

    Context 'Get-ColetaVestigios' {
        BeforeEach {
            foreach ($f in 'Get-VestigioEventoMsi', 'Get-VestigioAmcache', 'Get-VestigioShimCache', 'Get-VestigioBam', 'Get-VestigioPrefetch',
                'Get-VestigioUserAssist', 'Get-VestigioMuiCache', 'Get-VestigioCompatAssistant', 'Get-VestigioChaveSoftware',
                'Get-VestigioInstallerCache', 'Get-VestigioAtalhos', 'Get-VestigioFirewall', 'Get-VestigioDefender') {
                Mock $f ([scriptblock]::Create("New-Vestigio -Fonte 'X' -Item '$f'"))
            }
            Mock Copy-BrutoAmcache { 'C:\copia\Amcache.hve' }
        }
        It 'Fonte com admin pulada' {
            $Script:Ctx.Admin = $false
            $r = @(Get-ColetaVestigios -Perfis @() -PastaColeta (Join-Path $TestDrive 'c1'))
            foreach ($n in '08:Amcache', '08:ShimCache', '08:BAM', '08:Prefetch', '08:InstallerCache') {
                $Script:Ctx.FontesPuladas | Should -Contain $n
            }
            $Script:Ctx.FontesPuladas.Count | Should -Be 5
            foreach ($f in 'Get-VestigioEventoMsi', 'Get-VestigioUserAssist', 'Get-VestigioMuiCache', 'Get-VestigioCompatAssistant',
                'Get-VestigioChaveSoftware', 'Get-VestigioAtalhos', 'Get-VestigioFirewall', 'Get-VestigioDefender') {
                Should -Invoke $f -Times 1 -Exactly
            }
            foreach ($f in 'Get-VestigioAmcache', 'Get-VestigioShimCache', 'Get-VestigioBam', 'Get-VestigioPrefetch', 'Get-VestigioInstallerCache') {
                Should -Invoke $f -Times 0 -Exactly
            }
            Should -Invoke Copy-BrutoAmcache -Times 0 -Exactly
            $r.Count | Should -Be 8
        }
        It 'com admin roda todas e usa brutos e _tmp' {
            $pc = Join-Path $TestDrive 'c2'
            $r = @(Get-ColetaVestigios -Perfis @() -PastaColeta $pc)
            $r.Count | Should -Be 13
            $Script:Ctx.FontesPuladas.Count | Should -Be 0
            Should -Invoke Copy-BrutoAmcache -Times 1 -Exactly -ParameterFilter { $Destino -eq (Join-Path (Join-Path $pc 'brutos') 'Amcache') }
            Should -Invoke Get-VestigioAmcache -Times 1 -Exactly -ParameterFilter { $CopiaHve -eq 'C:\copia\Amcache.hve' -and $PastaTmp -eq (Join-Path $pc '_tmp') }
            Should -Invoke Get-VestigioPrefetch -Times 1 -Exactly -ParameterFilter { $Destino -eq (Join-Path (Join-Path $pc 'brutos') 'Prefetch') }
        }
        It 'falha numa fonte nao derruba as outras' {
            Mock Get-VestigioFirewall { throw 'sem firewall' }
            $r = @(Get-ColetaVestigios -Perfis @() -PastaColeta (Join-Path $TestDrive 'c3'))
            $r.Count | Should -Be 12
            $Script:Ctx.FontesComFalha | Should -Contain '08:Firewall'
        }
    }
}
