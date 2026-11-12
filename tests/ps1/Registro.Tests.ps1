BeforeAll {
    . "$PSScriptRoot/../../InventarioForense.ps1"
    if (-not (Get-Command reg.exe -ErrorAction SilentlyContinue)) { function reg.exe { } }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { function Get-CimInstance { param($ClassName) } }
}

Describe 'Leitura de registro' {
    It 'Get-RegSubchaves de chave inexistente' {
        { Get-RegSubchaves 'Registry::HKEY_LOCAL_MACHINE\NaoExiste\X' } | Should -Not -Throw
        $r = @(Get-RegSubchaves 'Registry::HKEY_LOCAL_MACHINE\NaoExiste\X')
        $r.Count | Should -Be 0
    }

    It 'Get-RegValores de chave inexistente' {
        $r = Get-RegValores 'Registry::HKEY_LOCAL_MACHINE\NaoExiste\X'
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It 'Split-CaminhoRegistro aceita HKLM e HKU e recusa outras raizes' {
        $r = Split-CaminhoRegistro 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\X'
        $r.Hive | Should -Be ([Microsoft.Win32.RegistryHive]::LocalMachine)
        $r.Sub | Should -Be 'SOFTWARE\X'
        (Split-CaminhoRegistro 'Registry::HKEY_USERS\S-1-5-21-1').Hive | Should -Be ([Microsoft.Win32.RegistryHive]::Users)
        (Split-CaminhoRegistro 'Registry::HKEY_USERS\S-1-5-21-1').Sub | Should -Be 'S-1-5-21-1'
        Split-CaminhoRegistro 'Registry::HKEY_CURRENT_USER\Software' | Should -BeNullOrEmpty
    }

    It 'Open-ChaveRegistro sem registro (Linux) ou raiz nao suportada devolve nulo sem excecao' {
        { Open-ChaveRegistro 'Registry::HKEY_CLASSES_ROOT\x' } | Should -Not -Throw
        Open-ChaveRegistro 'Registry::HKEY_CLASSES_ROOT\x' | Should -BeNullOrEmpty
        if ($IsLinux) { Open-ChaveRegistro 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE' | Should -BeNullOrEmpty }
    }

    It 'Get-RegSubchaves lista os nomes sem abrir as filhas e libera a chave' {
        $Script:Liberou = 0
        $falsa = [pscustomobject]@{}
        $falsa | Add-Member ScriptMethod GetSubKeyNames { @('A', 'B-ilegivel', 'C') }
        $falsa | Add-Member ScriptMethod OpenSubKey { throw 'nao deveria abrir filhas' }
        $falsa | Add-Member ScriptMethod Dispose { $Script:Liberou++ }
        Mock Open-ChaveRegistro { $falsa }
        $r = @(Get-RegSubchaves 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\X')
        $r -join '|' | Should -Be 'A|B-ilegivel|C'
        $Script:Liberou | Should -Be 1
    }

    It 'Get-RegSubchaves com falha na listagem devolve vazio e libera a chave' {
        $Script:Liberou = 0
        $falsa = [pscustomobject]@{}
        $falsa | Add-Member ScriptMethod GetSubKeyNames { throw 'acesso negado' }
        $falsa | Add-Member ScriptMethod Dispose { $Script:Liberou++ }
        Mock Open-ChaveRegistro { $falsa }
        @(Get-RegSubchaves 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\X').Count | Should -Be 0
        $Script:Liberou | Should -Be 1
    }

    It 'Get-RegValores pula valor ilegivel, nao expande %VAR% e nomeia o padrao' {
        $Script:Liberou = 0
        $Script:Opcoes = New-Object System.Collections.Generic.List[object]
        $falsa = [pscustomobject]@{}
        $falsa | Add-Member ScriptMethod GetValueNames { @('', 'Bom', 'Ruim', 'Exp') }
        $falsa | Add-Member ScriptMethod GetValue {
            param($n, $padrao, $opc)
            $Script:Opcoes.Add($opc)
            switch ($n) { '' { 'padrao' } 'Bom' { 7 } 'Ruim' { throw 'dado corrompido' } 'Exp' { '%SystemRoot%\x' } }
        }
        $falsa | Add-Member ScriptMethod Dispose { $Script:Liberou++ }
        Mock Open-ChaveRegistro { $falsa }
        $v = Get-RegValores 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\X'
        $v | Should -BeOfType [hashtable]
        $v['Bom'] | Should -Be 7
        $v['(default)'] | Should -Be 'padrao'
        $v['Exp'] | Should -Be '%SystemRoot%\x'
        $v.ContainsKey('Ruim') | Should -BeFalse
        $Script:Liberou | Should -Be 1
        foreach ($o in $Script:Opcoes) { $o | Should -Be ([Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }

    It 'Get-RegUltimaEscrita de chave inexistente' {
        Get-RegUltimaEscrita 'Registry::HKEY_LOCAL_MACHINE\NaoExiste\X' | Should -Be ''
    }

    It 'Tipo P/Invoke e criado' {
        $t = Get-TipoPInvokeRegistro
        $t | Should -Not -BeNullOrEmpty
        $m = $t.GetMethod('RegQueryInfoKey')
        $m | Should -Not -BeNullOrEmpty
        $m.GetParameters().Count | Should -Be 12
        $m.GetParameters()[11].ParameterType | Should -Be ([long].MakeByRefType())
        [object]::ReferenceEquals((Get-TipoPInvokeRegistro), $t) | Should -BeTrue
    }
}

Describe 'Get-PerfisSistema' {
    BeforeEach {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.LogPath = Join-Path $TestDrive 'Coleta.log'
        Mock Write-Host {}
    }

    It 'Exclui contas de servico e usa a pasta como fallback do nome' {
        Mock Get-RegSubchaves { @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', 'S-1-5-21-999-1') }
        Mock Get-RegValores { @{ ProfileImagePath = 'C:\Users\fulano' } }
        Mock Get-CimInstance { throw 'sem WMI' }
        $r = @(Get-PerfisSistema)
        $r.Count | Should -Be 1
        $r[0].SID | Should -Be 'S-1-5-21-999-1'
        $r[0].Caminho | Should -Be 'C:\Users\fulano'
        $r[0].Usuario | Should -Be 'fulano'
        $r[0].Carregado | Should -BeOfType [bool]
        $r[0].Especial | Should -BeFalse
        [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[AVISO\].*Win32_UserProfile'
    }
}

Describe 'Get-PerfisSistema expande ProfileImagePath' {
    BeforeEach {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.LogPath = Join-Path $TestDrive 'Coleta.log'
        Mock Write-Host {}
    }
    AfterEach { Remove-Item Env:\COLETA_TESTE_DRV -ErrorAction SilentlyContinue }

    It 'REG_EXPAND_SZ bruto vira caminho expandido' {
        $env:COLETA_TESTE_DRV = 'C:'
        Mock Get-RegSubchaves { @('S-1-5-21-999-1') }
        Mock Get-RegValores { @{ ProfileImagePath = '%COLETA_TESTE_DRV%\Users\fulano' } }
        Mock Get-CimInstance { throw 'sem WMI' }
        $r = @(Get-PerfisSistema)
        $r[0].Caminho | Should -Be 'C:\Users\fulano'
        $r[0].Usuario | Should -Be 'fulano'
    }
}

Describe 'Montagem de hives' {
    BeforeEach {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.LogPath = Join-Path $TestDrive 'Coleta.log'
        $Script:Ctx.Admin = $true
        Mock Write-Host {}
        Mock Start-Sleep {}
        $Script:ChamadasReg = New-Object System.Collections.Generic.List[string]
        Mock reg.exe { $Script:ChamadasReg.Add(($args -join ' ')); $global:LASTEXITCODE = 0 }
    }

    It 'Mount: perfil carregado usa HKU direto' {
        Mock Get-PerfisSistema {}
        $r = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-1'; Usuario = 'ana'; Caminho = 'C:\Users\ana'; Carregado = $true }) -PastaTmp $TestDrive)
        $r.Count | Should -Be 1
        $r[0].RaizUsuario | Should -Be 'Registry::HKEY_USERS\S-1-5-21-1'
        $r[0].RaizClasses | Should -Be 'Registry::HKEY_USERS\S-1-5-21-1_Classes'
        $r[0].Montado | Should -BeFalse
        $r[0].Disponivel | Should -BeTrue
        Should -Invoke reg.exe -Times 0
    }

    It 'Mount: nao carregado sem admin fica indisponivel' {
        $Script:Ctx.Admin = $false
        $r = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-1'; Usuario = 'ana'; Caminho = 'C:\Users\ana'; Carregado = $false }) -PastaTmp $TestDrive)
        $r[0].Disponivel | Should -BeFalse
        $r[0].Montado | Should -BeFalse
        $Script:Ctx.FontesPuladas | Should -Contain 'Hive:ana'
        Should -Invoke reg.exe -Times 0
        [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[AVISO\]'
    }

    It 'Mount: nao carregado com admin monta a COPIA, nunca o original' {
        $perfil = Join-Path $TestDrive 'perfil_bia'
        $pastaUc = Join-Path $perfil 'AppData/Local/Microsoft/Windows'
        $null = New-Item -ItemType Directory -Path $pastaUc -Force
        foreach ($n in 'NTUSER.DAT', 'NTUSER.DAT.LOG1', 'NTUSER.DAT.LOG2') { [IO.File]::WriteAllText((Join-Path $perfil $n), 'x') }
        foreach ($n in 'NTUSER.DAT{abc}.TMContainer00000000000000000001.regtrans-ms', 'NTUSER.DAT{abc}.TM.blf') { [IO.File]::WriteAllText((Join-Path $perfil $n), 'x') }
        [IO.File]::WriteAllText((Join-Path $perfil 'outro.txt'), 'z')
        foreach ($n in 'UsrClass.dat', 'UsrClass.dat.LOG1', 'UsrClass.dat{abc}.TM.blf') { [IO.File]::WriteAllText((Join-Path $pastaUc $n), 'y') }
        $tmp = Join-Path $TestDrive '_tmp'

        $r = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-2'; Usuario = 'bia'; Caminho = $perfil; Carregado = $false }) -PastaTmp $tmp)

        $copia = Join-Path (Join-Path (Join-Path $tmp 'hives') 'S-1-5-21-2') 'NTUSER.DAT'
        $copiaUc = Join-Path (Join-Path (Join-Path $tmp 'hives') 'S-1-5-21-2') 'UsrClass.dat'
        Test-Path -LiteralPath $copia | Should -BeTrue
        Test-Path -LiteralPath ($copia + '.LOG1') | Should -BeTrue
        Test-Path -LiteralPath ($copia + '.LOG2') | Should -BeTrue
        Test-Path -LiteralPath ($copiaUc + '.LOG1') | Should -BeTrue
        $pastaCopia = Split-Path -Parent $copia
        Test-Path -LiteralPath (Join-Path $pastaCopia 'NTUSER.DAT{abc}.TM.blf') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $pastaCopia 'NTUSER.DAT{abc}.TMContainer00000000000000000001.regtrans-ms') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $pastaCopia 'UsrClass.dat{abc}.TM.blf') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $pastaCopia 'outro.txt') | Should -BeFalse
        $Script:ChamadasReg | Should -Be @("load HKU\COLETA_1 $copia", "load HKU\COLETA_1_C $copiaUc")
        foreach ($c in $Script:ChamadasReg) { $c | Should -Not -BeLike "*$(Join-Path $perfil 'NTUSER.DAT')" }
        $r[0].RaizUsuario | Should -Be 'Registry::HKEY_USERS\COLETA_1'
        $r[0].RaizClasses | Should -Be 'Registry::HKEY_USERS\COLETA_1_C'
        $r[0].Montado | Should -BeTrue
        $r[0].Disponivel | Should -BeTrue
        @($Script:Ctx.HivesMontadas) | Should -Be @('HKU\COLETA_1', 'HKU\COLETA_1_C')
        $Script:Ctx.Escritas[0] | Should -Be "reg load HKU\COLETA_1 (copia de $(Join-Path $perfil 'NTUSER.DAT'))"
    }

    It 'Mount: sem perfis (Get-PerfisSistema vazio) nao lanca' {
        Mock Get-PerfisSistema {}
        { Mount-HivesColeta -Perfis (Get-PerfisSistema) -PastaTmp $TestDrive } | Should -Not -Throw
        $r = @(Mount-HivesColeta -Perfis (Get-PerfisSistema) -PastaTmp $TestDrive)
        $r.Count | Should -Be 0
        Should -Invoke reg.exe -Times 0
    }

    It 'Mount: arquivo auxiliar bloqueado gera AVISO e segue; hive base bloqueado e falha' {
        $perfil = Join-Path $TestDrive 'perfil_eva'
        $null = New-Item -ItemType Directory -Path $perfil -Force
        foreach ($n in 'NTUSER.DAT', 'NTUSER.DAT.LOG1', 'NTUSER.DAT{abc}.TM.blf') { [IO.File]::WriteAllText((Join-Path $perfil $n), 'x') }
        Mock Copy-Item { [IO.File]::Copy($LiteralPath[0], $Destination, $true) }
        Mock Copy-Item { throw 'arquivo em uso' } -ParameterFilter { $LiteralPath -like '*.blf' }
        $r = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-5'; Usuario = 'eva'; Caminho = $perfil; Carregado = $false }) -PastaTmp (Join-Path $TestDrive '_tmp5'))
        $r[0].Disponivel | Should -BeTrue
        $r[0].Montado | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $TestDrive '_tmp5/hives/S-1-5-21-5/NTUSER.DAT.LOG1') | Should -BeTrue
        [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[AVISO\].*arquivo em uso'

        Mock Copy-Item { throw 'hive em uso' } -ParameterFilter { $LiteralPath -like '*NTUSER.DAT' }
        $r2 = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-6'; Usuario = 'eva2'; Caminho = $perfil; Carregado = $false }) -PastaTmp (Join-Path $TestDrive '_tmp6'))
        $r2[0].Disponivel | Should -BeFalse
        $Script:Ctx.FontesComFalha | Should -Contain 'Hive:eva2'
        Should -Invoke reg.exe -Times 1 -Exactly
    }

    It 'Mount: nome em uso incrementa n' {
        $perfil = Join-Path $TestDrive 'perfil_caio'
        $null = New-Item -ItemType Directory -Path $perfil -Force
        [IO.File]::WriteAllText((Join-Path $perfil 'NTUSER.DAT'), 'x')
        Mock Test-Path { [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath) }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_USERS\COLETA_1' }
        $r = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-3'; Usuario = 'caio'; Caminho = $perfil; Carregado = $false }) -PastaTmp (Join-Path $TestDrive '_tmp3'))
        $r[0].RaizUsuario | Should -Be 'Registry::HKEY_USERS\COLETA_2'
        $r[0].RaizClasses | Should -Be ''
        @($Script:Ctx.HivesMontadas) | Should -Be @('HKU\COLETA_2')
    }

    It 'Mount: falha do reg load deixa o perfil indisponivel' {
        $perfil = Join-Path $TestDrive 'perfil_davi'
        $null = New-Item -ItemType Directory -Path $perfil -Force
        [IO.File]::WriteAllText((Join-Path $perfil 'NTUSER.DAT'), 'x')
        Mock reg.exe { $global:LASTEXITCODE = 1 }
        $r = @(Mount-HivesColeta -Perfis @([pscustomobject]@{ SID = 'S-1-5-21-4'; Usuario = 'davi'; Caminho = $perfil; Carregado = $false }) -PastaTmp (Join-Path $TestDrive '_tmp4'))
        $r[0].Disponivel | Should -BeFalse
        $r[0].Montado | Should -BeFalse
        $Script:Ctx.HivesMontadas.Count | Should -Be 0
        $Script:Ctx.Escritas.Count | Should -Be 0
    }

    It 'Dismount idempotente' {
        Dismount-HivesColeta
        Dismount-HivesColeta
        Should -Invoke reg.exe -Times 0
    }

    It 'Dismount desmonta tudo e esvazia a lista' {
        $Script:Ctx.HivesMontadas.Add('HKU\COLETA_1')
        $Script:Ctx.HivesMontadas.Add('HKU\COLETA_1_C')
        Dismount-HivesColeta
        $Script:ChamadasReg | Should -Be @('unload HKU\COLETA_1', 'unload HKU\COLETA_1_C')
        $Script:Ctx.HivesMontadas.Count | Should -Be 0
        Dismount-HivesColeta
        Should -Invoke reg.exe -Times 2 -Exactly
    }

    It 'Dismount tenta 3 vezes e registra a falha' {
        Mock reg.exe { $Script:ChamadasReg.Add(($args -join ' ')); $global:LASTEXITCODE = 1 }
        $Script:Ctx.HivesMontadas.Add('HKU\COLETA_1')
        Dismount-HivesColeta
        $Script:ChamadasReg.Count | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -Exactly
        $Script:Ctx.HivesMontadas.Count | Should -Be 0
        [IO.File]::ReadAllText($Script:Ctx.LogPath) | Should -Match '\[ERRO\].*HKU\\COLETA_1'
    }

    It 'Dismount -Somente desmonta so os itens listados' {
        $Script:Ctx.HivesMontadas.Add('HKU\COLETA_1')
        $Script:Ctx.HivesMontadas.Add('HKLM\COLETA_AMCACHE')
        Dismount-HivesColeta -Somente 'HKLM\COLETA_AMCACHE'
        $Script:ChamadasReg | Should -Be @('unload HKLM\COLETA_AMCACHE')
        @($Script:Ctx.HivesMontadas) | Should -Be @('HKU\COLETA_1')
    }
}
