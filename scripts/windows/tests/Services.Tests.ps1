# Regression tests for the service trimming and stock-app lists.
#
# The tests assert the lists that the profiles rely on, plus the -IncludeSearch
# and -IncludeSysMain behavior of optimize-services.ps1.

Describe 'Service trimming' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Initialize-WindowsCmdletStubs

        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ('winslim-services-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
        $env:ProgramData = $script:testRoot

        . (Join-Path $PSScriptRoot '..' 'optimize-services.ps1')
        . (Join-Path $PSScriptRoot '..' 'trim-stock.ps1')
    }

    AfterAll {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'optimize-services.ps1' {
        BeforeEach {
            Mock Get-Service { [pscustomobject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' } }
            Mock Set-Service { }
            Mock Stop-Service { }
            Mock Set-ServiceState { }
            Mock Stop-SearchProcesses { }
        }

        It 'disables WSearch and SysMain only when the switches are set' {
            Invoke-OptimizeServices -IncludeSearch -IncludeSysMain

            Should -Invoke Set-ServiceState -Times 1 -ParameterFilter {
                $Name -eq 'WSearch' -and $StartupType -eq 'Disabled'
            }
            Should -Invoke Set-ServiceState -Times 1 -ParameterFilter {
                $Name -eq 'SysMain' -and $StartupType -eq 'Disabled'
            }
            Should -Invoke Stop-SearchProcesses -Times 1
        }

        It 'leaves WSearch and SysMain alone by default' {
            Invoke-OptimizeServices

            Should -Invoke Set-ServiceState -Times 0 -ParameterFilter { $Name -eq 'WSearch' }
            Should -Invoke Set-ServiceState -Times 0 -ParameterFilter { $Name -eq 'SysMain' }
            Should -Invoke Stop-SearchProcesses -Times 0
        }

        }

    Context 'Set-ServiceState' {
        BeforeEach {
            Mock Get-Service { [pscustomobject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' } }
            Mock Set-Service { }
            Mock Stop-Service { }
        }

        It 'disables and stops a service' {
            Set-ServiceState -Name WSearch -Label 'Windows Search' -StartupType Disabled

            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WSearch' -and $StartupType -eq 'Disabled'
            }
            Should -Invoke Stop-Service -Times 1 -ParameterFilter { $Name -eq 'WSearch' }
        }

        It 'tolerates protected services' {
            Mock Set-Service { throw [System.UnauthorizedAccessException]::new('Access is denied') }

            { Set-ServiceState -Name WinDefend -Label 'Defender' -StartupType Disabled } |
                Should -Not -Throw
        }
    }

    Context 'trim-stock.ps1 lists' {
        It 'uses the aggressive list for Developer and keeps Defender out of all lists' {
            ($aggressiveServices | Where-Object Name -eq 'WSearch').Type | Should -Be 'Disabled'
            ($aggressiveServices | Where-Object Name -eq 'SysMain').Type | Should -Be 'Disabled'

            foreach ($list in @($leanServices, $balancedServices, $aggressiveServices)) {
                $list.Name | Should -Not -Contain 'WinDefend'
                $list.Name | Should -Not -Contain 'WdNisSvc'
                $list.Name | Should -Not -Contain 'SecurityHealthService'
                $list.Name | Should -Not -Contain 'wscsvc'
            }
        }

        It 'keeps Search and SysMain out of the lean and balanced lists' {
            $leanServices.Name | Should -Not -Contain 'WSearch'
            $leanServices.Name | Should -Not -Contain 'SysMain'
            $balancedServices.Name | Should -Not -Contain 'WSearch'
            $balancedServices.Name | Should -Not -Contain 'SysMain'
        }

        It 'removes the Store only in the aggressive app list' {
            $leanApps | Should -Not -Contain 'Microsoft.WindowsStore'
            $aggressiveApps | Should -Contain 'Microsoft.WindowsStore'
        }

        It 'Invoke-Recommended uses the lean list, not the aggressive one' {
            Mock Disable-OneDrive { }
            Mock Remove-StockApps { }
            Mock Disable-StockServices { }

            Invoke-Recommended

            Should -Invoke Disable-StockServices -Times 1 -ParameterFilter {
                $Entries.Name -contains 'DiagTrack' -and
                $Entries.Name -notcontains 'WSearch'
            }
        }
    }
}