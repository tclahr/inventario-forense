BeforeAll {
    . "$PSScriptRoot/../../InventarioForense.ps1"
    $Script:Sep = [System.IO.Path]::DirectorySeparatorChar
    function Script:Novo-Arq { param([string]$Caminho, [int]$Bytes = 3)
        $dir = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [System.IO.File]::WriteAllBytes($Caminho, (New-Object byte[] $Bytes))
    }
}

Describe 'Get-ArquivosAlvo' {
    BeforeEach {
        Mock Write-Log { }
        $Script:R = Join-Path $TestDrive ('t' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $Script:R
    }

    It 'Filtra extensoes case-insensitive' {
        Novo-Arq (Join-Path $Script:R 'a.EXE'); Novo-Arq (Join-Path $Script:R 'b.txt'); Novo-Arq (Join-Path $Script:R 'sub/c.iso')
        $r = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes $Script:ExtensoesInstaladores)
        $r.Count | Should -Be 2
        $r[0] | Should -BeOfType [System.IO.FileInfo]
    }

    It 'Nao segue link de diretorio' -Skip:($IsWindows -and -not $env:CF_TEST_SYMLINK) {
        Novo-Arq (Join-Path $Script:R 'a.exe')
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $Script:R 'loop') -Target $Script:R
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe'))
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
        $r.Count | Should -Be 1
    }

    It 'Excluir com excecao' {
        Novo-Arq (Join-Path $Script:R 'win/x.exe'); Novo-Arq (Join-Path $Script:R 'win/Installer/y.msi'); Novo-Arq (Join-Path $Script:R 'outro/z.exe')
        $ex = @{ Prefixo = (Join-Path $Script:R 'win'); Excecoes = [string[]]@((Join-Path $Script:R 'win/Installer')) }
        $r = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe', '.msi') -Excluir @($ex))
        ($r.Name | Sort-Object) -join ',' | Should -Be 'y.msi,z.exe'
    }

    It 'Prefixo de exclusao e case-insensitive e exige separador' {
        Novo-Arq (Join-Path $Script:R 'Win/x.exe'); Novo-Arq (Join-Path $Script:R 'Windows2/k.exe')
        $ex = @{ Prefixo = (Join-Path $Script:R 'WIN'); Excecoes = @() }
        $r = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe') -Excluir @($ex))
        $r.Name | Should -Be 'k.exe'
    }

    It 'Acesso negado contado' -Skip:($IsWindows -or (id -u) -eq '0') {
        Novo-Arq (Join-Path $Script:R 'ok.exe')
        $null = New-Item -ItemType Directory -Path (Join-Path $Script:R 'negado')
        chmod 000 (Join-Path $Script:R 'negado')
        try {
            { $null = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe')) } | Should -Not -Throw
            Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensagem -like '*1 pastas sem acesso' -and $Mensagem -like "$($Script:R): 1 arquivos*" }
        } finally { chmod 755 (Join-Path $Script:R 'negado') }
    }

    It 'Loga INFO quando nenhuma pasta negada' {
        Novo-Arq (Join-Path $Script:R 'ok.exe')
        $null = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe'))
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'INFO' -and $Area -eq 'Arquivos' -and $Mensagem -eq "$($Script:R): 1 arquivos, 0 pastas sem acesso" }
    }

    It 'Emite em streaming (consumidor ve o 1o item antes do fim da varredura)' {
        Novo-Arq (Join-Path $Script:R 'a/1.exe'); Novo-Arq (Join-Path $Script:R 'b/2.exe')
        $Script:emitidos = 0; $Script:novoVisto = $false
        $Script:Raiz13 = $Script:R
        Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe') | ForEach-Object {
            $Script:emitidos++
            if ($Script:emitidos -eq 1) {
                # cria arquivo na pasta que a varredura ainda nao visitou
                $outra = if ($_.DirectoryName -like '*a') { 'b' } else { 'a' }
                Novo-Arq (Join-Path $Script:Raiz13 "$outra/novo.exe")
            }
            if ($_.Name -eq 'novo.exe') { $Script:novoVisto = $true }
        }
        $Script:novoVisto | Should -BeTrue
        $Script:emitidos | Should -Be 3
    }

    It 'Falha so em GetFiles nao descarta subpastas legiveis e conta 1 pasta' {
        Novo-Arq (Join-Path $Script:R 'bloq/fundo/ok.exe')
        $Script:OrigEnt = ${function:Get-EntradasDiretorio}
        Mock Get-EntradasDiretorio {
            $e = & $Script:OrigEnt -Dir $Dir -ComArquivos $ComArquivos
            if ($Dir.Name -eq 'bloq') { $e.Arquivos = @(); $e.Falhou = $true }
            $e
        }
        $r = @(Get-ArquivosAlvo -Raiz $Script:R -Extensoes @('.exe'))
        $r.Name | Should -Be 'ok.exe'
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensagem -like '*1 pastas sem acesso' }
    }
}

Describe 'New-LinhaArquivo' {
    BeforeEach {
        Mock Write-Log { }
        $Script:R = Join-Path $TestDrive ('l' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $Script:R
    }

    It 'Hash e limite' {
        $p = Join-Path $Script:R 'dez.zip'
        [System.IO.File]::WriteAllBytes($p, [byte[]](1..10))
        $fi = Get-Item -LiteralPath $p
        $l1 = New-LinhaArquivo -Arquivo $fi -Local 'Downloads' -Usuario 'u' -LimiteHash 5
        $l1.SHA256 | Should -Be ''
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensagem -eq "Hash omitido (> 1 GB): $p" }
        $l2 = New-LinhaArquivo -Arquivo $fi -Local 'Downloads' -Usuario 'u' -LimiteHash 0
        $l2.SHA256 | Should -BeExactly (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
        $l2.TamanhoBytes | Should -BeOfType [long]
        $l2.TamanhoBytes | Should -Be 10
        $l2.CriadoEm | Should -BeOfType [datetime]
        $l2.ModificadoEm | Should -BeOfType [datetime]
        $l2.Extensao | Should -Be '.zip'
        $l2.Caminho | Should -Be $p
    }

    It 'Arquivo em uso deixa SHA256 vazio com AVISO' {
        $p = Join-Path $Script:R 'x.zip'
        [System.IO.File]::WriteAllBytes($p, [byte[]](1..3))
        Mock Get-FileHash { throw 'em uso' }
        $l = New-LinhaArquivo -Arquivo (Get-Item -LiteralPath $p) -Local 'L' -Usuario '' -LimiteHash 0
        $l.SHA256 | Should -Be ''
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'AVISO' }
    }

    It 'Nome com acento' {
        $p = Join-Path $Script:R ('Instala' + [char]0xE7 + [char]0xE3 + 'o.exe')
        [System.IO.File]::WriteAllBytes($p, [byte[]](1..3))
        $l = New-LinhaArquivo -Arquivo (Get-Item -LiteralPath $p) -Local 'L' -Usuario 'u' -LimiteHash 0
        $l.Arquivo | Should -Be ('Instala' + [char]0xE7 + [char]0xE3 + 'o.exe')
    }

    It '.msi chama Get-MsiPropriedades e tolera erro' {
        $p = Join-Path $Script:R 'a.msi'
        [System.IO.File]::WriteAllBytes($p, [byte[]](1..3))
        Mock Get-MsiPropriedades { @{ ProductName = 'Prod'; Manufacturer = 'Fab'; ProductVersion = '1.2' } }
        $l = New-LinhaArquivo -Arquivo (Get-Item -LiteralPath $p) -Local 'L' -Usuario '' -LimiteHash 0
        $l.ProductName | Should -Be 'Prod'; $l.CompanyName | Should -Be 'Fab'; $l.ProductVersion | Should -Be '1.2'
        Mock Get-MsiPropriedades { throw 'sem COM' }
        $l = New-LinhaArquivo -Arquivo (Get-Item -LiteralPath $p) -Local 'L' -Usuario '' -LimiteHash 0
        $l.ProductName | Should -Be ''
    }
}

Describe 'Pastas de programas' {
    BeforeEach { Mock Write-Log { } }

    It 'Pastas 1o nivel' {
        $base = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $base 'A/B') -Force
        $r = @(Get-ColetaPastasProgramas -Raizes @(@{ Raiz = 'ProgramFiles'; Usuario = ''; Caminho = $base }))
        $r.Count | Should -Be 1
        $r[0].Pasta | Should -Be 'A'
        $r[0].Raiz | Should -Be 'ProgramFiles'
        $r[0].Caminho | Should -Be (Join-Path $base 'A')
        $r[0].CriadoEm | Should -BeOfType [datetime]
    }

    It 'Get-RaizesPastasProgramas omite inexistentes e remove duplicadas' {
        $pf = Join-Path $TestDrive 'pf'; $null = New-Item -ItemType Directory -Path (Join-Path $pf 'Common Files') -Force
        $pd = Join-Path $TestDrive 'pd'; $null = New-Item -ItemType Directory -Path $pd -Force
        $perfil = Join-Path $TestDrive 'perfil'; $null = New-Item -ItemType Directory -Path (Join-Path $perfil 'AppData/Local') -Force
        $old = @{ pf = $env:ProgramFiles; x86 = ${env:ProgramFiles(x86)}; pd = $env:ProgramData }
        try {
            $env:ProgramFiles = $pf; ${env:ProgramFiles(x86)} = $pf; $env:ProgramData = $pd
            $r = @(Get-RaizesPastasProgramas -Perfis @([pscustomobject]@{ SID = 'S-1'; Usuario = 'u1'; Caminho = $perfil; Disponivel = $false }))
            $r.Count | Should -Be 4
            ($r | Where-Object { $_.Usuario -eq 'u1' }).Raiz | Should -Be 'AppData\Local'
            @($r.Caminho | Select-Object -Unique).Count | Should -Be 4
        } finally {
            $env:ProgramFiles = $old.pf; ${env:ProgramFiles(x86)} = $old.x86; $env:ProgramData = $old.pd
        }
    }
}

Describe 'Raizes e coletas de arquivos' {
    BeforeEach { Mock Write-Log { } }

    It 'Get-RaizesInstaladores inclui Lixeira e tolera falha do CIM' {
        $perfil = Join-Path $TestDrive 'pu'; $null = New-Item -ItemType Directory -Path (Join-Path $perfil 'Downloads') -Force
        $pf = @([pscustomobject]@{ SID = 'S-1'; Usuario = 'u1'; Caminho = $perfil })
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:' }) }
        $r = @(Get-RaizesInstaladores -Perfis $pf)
        ($r | Where-Object Local -eq 'Downloads').Usuario | Should -Be 'u1'
        $l = @($r | Where-Object Local -eq 'Lixeira')
        $l.Count | Should -Be 1
        $l[0].Caminho | Should -Be ('C:' + $Script:Sep + '$Recycle.Bin')
        $l[0].Usuario | Should -Be ''
        Mock Get-CimSafe { throw 'sem cim' }
        $r = @(Get-RaizesInstaladores -Perfis $pf)
        $r.Count | Should -Be 1
    }

    It 'Get-ColetaArquivosInstaladores gera linhas com hash' {
        $base = Join-Path $TestDrive ('i' + [guid]::NewGuid().ToString('N'))
        Novo-Arq (Join-Path $base 'sub/a.zip') 4; Novo-Arq (Join-Path $base 'n.txt')
        $r = @(Get-ColetaArquivosInstaladores -Raizes @(@{ Local = 'Downloads'; Usuario = 'u1'; Caminho = $base }))
        $r.Count | Should -Be 1
        $r[0].Local | Should -Be 'Downloads'; $r[0].Usuario | Should -Be 'u1'
        $r[0].SHA256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'Falha em New-LinhaArquivo loga o caminho do arquivo' {
        $base = Join-Path $TestDrive ('e' + [guid]::NewGuid().ToString('N'))
        Novo-Arq (Join-Path $base 'ruim.zip'); Novo-Arq (Join-Path $base 'bom.zip')
        $ruim = Join-Path $base 'ruim.zip'
        Mock New-LinhaArquivo { if ($Arquivo.Name -eq 'ruim.zip') { throw 'falhou' } else { [pscustomobject]@{ Arquivo = $Arquivo.Name } } }
        $r = @(Get-ColetaArquivosInstaladores -Raizes @(@{ Local = 'Downloads'; Usuario = 'u'; Caminho = $base }))
        $r.Count | Should -Be 1
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensagem -eq "${ruim}: falhou" }
    }

    It 'Get-UnidadeColeta devolve a letra do volume da coleta' {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.PastaColeta = 'e:\Coleta\InventarioForense_H_20261112143000'
        Get-UnidadeColeta | Should -Be 'E:'
        $Script:Ctx.PastaColeta = '\\srv\share\x'
        Get-UnidadeColeta | Should -Be ''
        $Script:Ctx.PastaColeta = ''
        Get-UnidadeColeta | Should -Be ''
    }

    It 'Lixeira (15) exclui a unidade da coleta e loga INFO' {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.PastaColeta = 'E:\InventarioForense_H_20261112143000'
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:' }, [pscustomobject]@{ DeviceID = 'e:' }) }
        $r = @(Get-RaizesInstaladores -Perfis @())
        $r.Count | Should -Be 1
        $r[0].Caminho | Should -Be ('C:' + $Script:Sep + '$Recycle.Bin')
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'INFO' -and $Mensagem -eq 'Unidade da coleta excluida: E:' }
    }

    It 'Varredura completa (16) nao varre a unidade da coleta' {
        $null = New-ContextoColeta -Parametros @{}
        $Script:Ctx.PastaColeta = 'E:\InventarioForense_H_20261112143000'
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:' }, [pscustomobject]@{ DeviceID = 'E:' }) }
        Mock Get-ArquivosAlvo { }
        $null = @(Get-ColetaArquivosCompleta)
        Should -Invoke Get-ArquivosAlvo -Times 1 -Exactly
        Should -Invoke Get-ArquivosAlvo -Times 1 -Exactly -ParameterFilter { $Raiz -eq ('C:' + $Script:Sep) }
        Should -Invoke Write-Log -ParameterFilter { $Nivel -eq 'INFO' -and $Mensagem -eq 'Unidade da coleta excluida: E:' }
    }

    It 'Coleta no disco do sistema (16): varre C: e exclui so a pasta da coleta e os ZIPs anteriores' {
        $antes = $env:SystemDrive
        try {
            $env:SystemDrive = 'C:'
            $null = New-ContextoColeta -Parametros @{}
            $Script:Ctx.PastaColeta = 'C:' + $Script:Sep + 'Ferramentas' + $Script:Sep + 'InventarioForense_H_20261112143000'
            Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:' }, [pscustomobject]@{ DeviceID = 'D:' }) }
            $dirC = 'C:' + $Script:Sep + 'Ferramentas'
            $Script:ArqsFalsos = @(
                [pscustomobject]@{ Name = 'InventarioForense_H_20261101100000.zip'; DirectoryName = $dirC; Attributes = 32 },
                [pscustomobject]@{ Name = 'InventarioForense_H_20261101100000.zip'; DirectoryName = 'C:' + $Script:Sep + 'Outro'; Attributes = 32 },
                [pscustomobject]@{ Name = 'setup.zip'; DirectoryName = $dirC; Attributes = 32 })
            Mock Get-ArquivosAlvo { $Script:ArqsFalsos }
            Mock New-LinhaArquivo { [pscustomobject]@{ Arquivo = $Arquivo.Name } } -RemoveParameterType Arquivo
            $r = @(Get-ColetaArquivosCompleta)
            Should -Invoke Get-ArquivosAlvo -Times 2 -Exactly
            Should -Invoke Get-ArquivosAlvo -Times 1 -Exactly -ParameterFilter { $Raiz -eq ('C:' + $Script:Sep) }
            Should -Invoke Get-ArquivosAlvo -Times 2 -Exactly -ParameterFilter { @($Excluir | Where-Object { $_['Prefixo'] -eq $Script:Ctx.PastaColeta }).Count -eq 1 }
            Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Mensagem -like 'Unidade da coleta excluida*' }
            # por disco: setup.zip e o ZIP de outra pasta ficam; o ZIP ao lado da coleta sai
            ($r | Where-Object { $_.Arquivo -eq 'setup.zip' }).Count | Should -Be 2
            ($r | Where-Object { $_.Arquivo -like 'InventarioForense_*' }).Count | Should -Be 2
        } finally { $env:SystemDrive = $antes }
    }

    It 'Coleta no disco do sistema (15): Lixeira do C: continua' {
        $antes = $env:SystemDrive
        try {
            $env:SystemDrive = 'C:'
            $null = New-ContextoColeta -Parametros @{}
            $Script:Ctx.PastaColeta = 'C:\InventarioForense_H_20261112143000'
            Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'C:' }) }
            $r = @(Get-RaizesInstaladores -Perfis @())
            $r.Count | Should -Be 1
            $r[0].Caminho | Should -Be ('C:' + $Script:Sep + '$Recycle.Bin')
        } finally { $env:SystemDrive = $antes }
    }

    It 'Test-ArquivoSomenteNuvem reconhece Offline, RecallOnOpen e RecallOnDataAccess, nao ReparsePoint' {
        Test-ArquivoSomenteNuvem -Atributos 0x1000 | Should -BeTrue
        Test-ArquivoSomenteNuvem -Atributos 0x40000 | Should -BeTrue
        Test-ArquivoSomenteNuvem -Atributos (0x400000 -bor 0x400 -bor 0x20) | Should -BeTrue
        Test-ArquivoSomenteNuvem -Atributos 0x400 | Should -BeFalse
        Test-ArquivoSomenteNuvem -Atributos ([int][System.IO.FileAttributes]::Archive) | Should -BeFalse
    }

    It 'Arquivo somente na nuvem nao e lido (sem hash nem versao) e a contagem e logada por raiz' {
        $base = Join-Path $TestDrive ('n' + [guid]::NewGuid().ToString('N'))
        Novo-Arq (Join-Path $base 'a.exe'); Novo-Arq (Join-Path $base 'b.msi')
        Mock Test-ArquivoSomenteNuvem { $true }
        Mock Get-FileHash { throw 'nao deveria ler' }
        Mock Get-MsiPropriedades { throw 'nao deveria ler' }
        $r = @(Get-ColetaArquivosInstaladores -Raizes @(@{ Local = 'Documents'; Usuario = 'u'; Caminho = $base }))
        $r.Count | Should -Be 2
        foreach ($l in $r) { $l.SHA256 | Should -Be ''; $l.ProductName | Should -Be '' }
        Should -Invoke Get-FileHash -Times 0 -Exactly
        Should -Invoke Get-MsiPropriedades -Times 0 -Exactly
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Nivel -eq 'AVISO' -and $Mensagem -eq "${base}: 2 arquivos somente na nuvem nao lidos" }
    }

    It 'Arquivo local segue com hash e sem aviso de nuvem' {
        $base = Join-Path $TestDrive ('l' + [guid]::NewGuid().ToString('N'))
        Novo-Arq (Join-Path $base 'a.zip')
        $r = @(Get-ColetaArquivosInstaladores -Raizes @(@{ Local = 'Documents'; Usuario = 'u'; Caminho = $base }))
        $r[0].SHA256 | Should -Match '^[0-9a-f]{64}$'
        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Mensagem -like '*somente na nuvem*' }
    }

    It 'Get-ColetaArquivosCompleta usa discos fixos e Local Disco' {
        $base = Join-Path $TestDrive ('c' + [guid]::NewGuid().ToString('N'))
        Novo-Arq (Join-Path $base 'a.exe')
        Mock Get-CimSafe { @([pscustomobject]@{ DeviceID = 'Z:' }) }
        Mock Get-ArquivosAlvo { Get-ChildItem -LiteralPath $base -File } -ParameterFilter { $Raiz -eq ('Z:' + $Script:Sep) }
        $r = @(Get-ColetaArquivosCompleta)
        $r.Count | Should -Be 1
        $r[0].Local | Should -Be 'Disco Z'
        Should -Invoke Get-ArquivosAlvo -Times 1
    }
}
