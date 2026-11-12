BeforeAll {
    . "$PSScriptRoot/../../InventarioForense.ps1"
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { function global:Get-AppxPackage { param([switch]$AllUsers) } }
    function New-CtxTeste { param([bool]$Admin = $false) $null = New-ContextoColeta -Parametros @{}; $Script:Ctx.Admin = $Admin }
    $Script:U64 = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $Script:MsiP = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products'
    $Script:MsiU = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
}

Describe 'Get-ColetaSoftwareInstalado' {
    BeforeEach {
        New-CtxTeste
        Mock Get-RegSubchaves { @() }
        Mock Get-RegValores { @{} }
        Mock Get-AppxPackage { @() }
    }

    It 'HKLM64 mapeia campos' {
        Mock Get-RegSubchaves { @('{A}') } -ParameterFilter { $Caminho -eq $Script:U64 }
        Mock Get-RegValores {
            @{ DisplayName = 'AutoCAD 2024'; InstallDate = '20240115'; SystemComponent = 1; DisplayVersion = '24.0'; Publisher = 'Autodesk'; InstallLocation = 'C:\A'; UninstallString = ''; QuietUninstallString = 'q.exe' }
        } -ParameterFilter { $Caminho -eq ($Script:U64 + '\{A}') }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @())
        $r.Count | Should -Be 1
        $r[0].Fonte | Should -Be 'HKLM64'
        $r[0].Nome | Should -Be 'AutoCAD 2024'
        $r[0].DataInstalacao | Should -Be '2024-01-15 00:00:00'
        $r[0].ComponenteSistema | Should -BeTrue
        $r[0].ComponenteSistema | Should -BeOfType [bool]
        $r[0].Desinstalador | Should -Be 'q.exe'
        $r[0].ChaveRegistro | Should -Be 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{A}'
    }

    It 'HKLM32 usa WOW6432Node' {
        Mock Get-RegSubchaves { @('{B}') } -ParameterFilter { $Caminho -like '*WOW6432Node*Uninstall' -and $Caminho -like 'Registry::HKEY_LOCAL_MACHINE*' }
        Mock Get-RegValores { @{ DisplayName = 'X32' } } -ParameterFilter { $Caminho -like '*WOW6432Node*\{B}' }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @())
        $r.Count | Should -Be 1
        $r[0].Fonte | Should -Be 'HKLM32'
        $r[0].ComponenteSistema | Should -BeFalse
    }

    It 'Sem DisplayName ignorado' {
        Mock Get-RegSubchaves { @('{A}') } -ParameterFilter { $Caminho -eq $Script:U64 }
        Mock Get-RegValores { @{ Publisher = 'Z' } } -ParameterFilter { $Caminho -eq ($Script:U64 + '\{A}') }
        @(Get-ColetaSoftwareInstalado -Perfis @()).Count | Should -Be 0
    }

    It 'Perfil indisponivel nao consultado' {
        $p = [pscustomobject]@{ SID = 'S-1-5-21-9-9-9-1001'; Usuario = 'x'; RaizUsuario = 'Registry::HKEY_USERS\COLETA_1'; Disponivel = $false }
        $null = Get-ColetaSoftwareInstalado -Perfis @($p)
        Should -Invoke Get-RegSubchaves -Times 0 -ParameterFilter { $Caminho -like '*COLETA*' -or $Caminho -like '*S-1-5-21-9*' }
    }

    It 'Usuario preenchido' {
        $p = [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1001'; Usuario = 'ana'; RaizUsuario = 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001'; Disponivel = $true }
        Mock Get-RegSubchaves { @('Zoom') } -ParameterFilter { $Caminho -like 'Registry::HKEY_USERS*Uninstall' }
        Mock Get-RegValores { @{ DisplayName = 'Zoom' } } -ParameterFilter { $Caminho -like 'Registry::HKEY_USERS*\Zoom' }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @($p))
        $u = @($r | Where-Object Fonte -eq 'Usuario')
        $u.Count | Should -Be 2
        $u | ForEach-Object { $_.Usuario | Should -Be 'ana' }
        $u[0].ChaveRegistro | Should -Be 'HKEY_USERS\S-1-5-21-1-2-3-1001\Software\Microsoft\Windows\CurrentVersion\Uninstall\Zoom'
    }

    It 'MSI junta por id e inclui produto so em Products' {
        Mock Get-RegSubchaves { @('ID1', 'ID2') } -ParameterFilter { $Caminho -eq $Script:MsiP }
        Mock Get-RegValores { @{ ProductName = 'Prod Um' } } -ParameterFilter { $Caminho -eq ($Script:MsiP + '\ID1') }
        Mock Get-RegValores { @{ ProductName = 'Prod Dois' } } -ParameterFilter { $Caminho -eq ($Script:MsiP + '\ID2') }
        Mock Get-RegSubchaves { @('S-1-5-18') } -ParameterFilter { $Caminho -eq $Script:MsiU }
        Mock Get-RegSubchaves { @('ID1') } -ParameterFilter { $Caminho -eq ($Script:MsiU + '\S-1-5-18\Products') }
        Mock Get-RegValores { @{ DisplayVersion = '1.2'; Publisher = 'Pub'; InstallDate = '20230301'; InstallLocation = 'C:\P'; UninstallString = 'msiexec /x' } } -ParameterFilter { $Caminho -eq ($Script:MsiU + '\S-1-5-18\Products\ID1\InstallProperties') }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @())
        $r.Count | Should -Be 2
        $a = $r | Where-Object Nome -eq 'Prod Um'
        $a.Fonte | Should -Be 'MSI'
        $a.Versao | Should -Be '1.2'
        $a.Usuario | Should -Be 'SYSTEM'
        $a.DataInstalacao | Should -Be '2023-03-01 00:00:00'
        $b = $r | Where-Object Nome -eq 'Prod Dois'
        $b.Fonte | Should -Be 'MSI'
        $b.Versao | Should -Be ''
    }

    It 'Appx mapeia campos e usa -AllUsers com admin' {
        New-CtxTeste -Admin $true
        Mock Get-AppxPackage {
            @([pscustomobject]@{ Name = 'Pkg'; Version = '1.0'; Publisher = 'CN=X'; InstallLocation = 'C:\W'; SignatureKind = 'System'; IsFramework = $false
                PackageUserInformation = @([pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Username = 'a'; Sid = 'S-1-5-21-1' } }) },
              [pscustomobject]@{ Name = 'Pkg2'; Version = '2'; Publisher = 'P'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $true; PackageUserInformation = $null })
        }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @())
        Should -Invoke Get-AppxPackage -Times 1 -ParameterFilter { $AllUsers }
        $r.Count | Should -Be 2
        $r[0].Fonte | Should -Be 'Appx'
        $r[0].ComponenteSistema | Should -BeTrue
        $r[0].DataInstalacao | Should -Be ''
        $r[1].ComponenteSistema | Should -BeTrue
        $r[1].Usuario | Should -Be ''
    }

    It 'Appx sem admin nao usa -AllUsers' {
        $null = Get-ColetaSoftwareInstalado -Perfis @()
        Should -Invoke Get-AppxPackage -Times 1 -ParameterFilter { -not $AllUsers }
    }

    It 'Sem deduplicacao' {
        Mock Get-RegSubchaves { @('{A}') } -ParameterFilter { $Caminho -eq $Script:U64 }
        Mock Get-RegValores { @{ DisplayName = 'Mesmo' } } -ParameterFilter { $Caminho -eq ($Script:U64 + '\{A}') }
        Mock Get-RegSubchaves { @('ID1') } -ParameterFilter { $Caminho -eq $Script:MsiP }
        Mock Get-RegValores { @{ ProductName = 'Mesmo' } } -ParameterFilter { $Caminho -eq ($Script:MsiP + '\ID1') }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @())
        @($r | Where-Object Nome -eq 'Mesmo').Count | Should -Be 2
    }
}

Describe 'Appx usuarios e falhas' {
    BeforeEach { New-CtxTeste; Mock Get-RegSubchaves { @() }; Mock Get-RegValores { @{} } }
    It 'Usuario usa Username ou Sid resolvido' {
        Mock Get-AppxPackage {
            @([pscustomobject]@{ Name = 'P'; Version = '1'; Publisher = 'x'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false
                PackageUserInformation = @([pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Username = 'ana'; Sid = 'S-1-5-21-1' } },
                                           [pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Username = ''; Sid = 'S-1-5-18' } },
                                           [pscustomobject]@{ UserSecurityId = [pscustomobject]@{ Username = ''; Sid = '' } }) })
        }
        @(Get-ColetaSoftwareInstalado -Perfis @())[0].Usuario | Should -Be 'ana, SYSTEM'
    }
    It 'falha no Appx preserva HKLM64 e registra falha' {
        Mock Get-RegSubchaves { @('{A}') } -ParameterFilter { $Caminho -eq $Script:U64 }
        Mock Get-RegValores { @{ DisplayName = 'Keep' } } -ParameterFilter { $Caminho -eq ($Script:U64 + '\{A}') }
        Mock Get-AppxPackage { throw 'boom' }
        $r = @(Get-ColetaSoftwareInstalado -Perfis @())
        $r.Count | Should -Be 1
        $r[0].Fonte | Should -Be 'HKLM64'
        @($Script:Ctx.FontesComFalha) | Should -Contain '07:Appx'
    }
}

Describe 'Resolve-NomeSid' {
    It 'S-1-5-18 vira SYSTEM' { Resolve-NomeSid -Sid 'S-1-5-18' | Should -Be 'SYSTEM' }
    It 'SID invalido volta o proprio' { Resolve-NomeSid -Sid 'xyz' | Should -Be 'xyz' }
    It 'Resultado fica em cache por SID' {
        $Script:CacheNomesSid = @{}
        $Script:CacheNomesSid['S-1-5-21-9-9-9-1001'] = 'PC\cacheado'
        Resolve-NomeSid -Sid 'S-1-5-21-9-9-9-1001' | Should -Be 'PC\cacheado'
        $Script:CacheNomesSid = @{}
        Resolve-NomeSid -Sid 'xyz2' | Should -Be 'xyz2'
        $Script:CacheNomesSid.ContainsKey('xyz2') | Should -BeTrue
    }
}
