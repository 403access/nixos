# Regression tests for the Windows Search switch.
#
# These tests run on any platform.  Service, process and registry cmdlets are
# mocked; the JSON state file is written to a temporary ProgramData directory.

Describe 'Windows Search switch' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Initialize-WindowsCmdletStubs

        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ('winslim-search-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
        $env:ProgramData = $script:testRoot
        . (Join-Path $PSScriptRoot '..' 'toggle-search.ps1')
    }

    AfterAll {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $stateDir = Join-Path $env:ProgramData 'WindowsSlim'
        Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue

        Mock Get-Service {
            [pscustomobject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Set-Service { }
        Mock Stop-Service { }
        Mock Start-Service { }
        Mock Stop-SearchProcesses { }
        Mock Set-TaskbarSearchMode { }
        Mock Get-ItemProperty { [pscustomobject]@{ SearchboxTaskbarMode = 2 } }
    }

    Context 'Disable-Search' {
        It 'disables WSearch, hides the taskbar box and stops search processes' {
            Disable-Search

            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WSearch' -and $StartupType -eq 'Disabled'
            }
            Should -Invoke Stop-Service -Times 1 -ParameterFilter { $Name -eq 'WSearch' }
            Should -Invoke Set-TaskbarSearchMode -Times 1 -ParameterFilter { $Mode -eq 0 }
            Should -Invoke Stop-SearchProcesses -Times 1
        }

        It 'saves the previous start type and taskbar mode for Enable-Search' {
            Disable-Search

            $stateFile = Join-Path $env:ProgramData 'WindowsSlim/search-state.json'
            Test-Path -LiteralPath $stateFile | Should -BeTrue

            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            $state.StartType | Should -Be 'Automatic'
            $state.SearchboxTaskbarMode | Should -Be 2
        }

        It 'does not overwrite an existing saved state' {
            $stateDir = Join-Path $env:ProgramData 'WindowsSlim'
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            $stateFile = Join-Path $stateDir 'search-state.json'
            '{"StartType":"Manual","SearchboxTaskbarMode":1}' | Set-Content -LiteralPath $stateFile

            Disable-Search

            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            $state.StartType | Should -Be 'Manual'
            $state.SearchboxTaskbarMode | Should -Be 1
        }

        It 'warns and changes nothing when WSearch is missing' {
            Mock Get-Service { $null }
            Mock Write-Warning { }

            Disable-Search

            Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                $Message -match 'WSearch is not present'
            }
            Should -Invoke Set-Service -Times 0
            Should -Invoke Stop-Service -Times 0
            Should -Invoke Stop-SearchProcesses -Times 0
        }
    }

    Context 'Enable-Search' {
        It 'restores the saved start type and taskbar mode' {
            $stateDir = Join-Path $env:ProgramData 'WindowsSlim'
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            $stateFile = Join-Path $stateDir 'search-state.json'
            '{"StartType":"Manual","SearchboxTaskbarMode":1}' | Set-Content -LiteralPath $stateFile

            Enable-Search

            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WSearch' -and $StartupType -eq 'Manual'
            }
            Should -Invoke Start-Service -Times 1 -ParameterFilter { $Name -eq 'WSearch' }
            Should -Invoke Set-TaskbarSearchMode -Times 1 -ParameterFilter { $Mode -eq 1 }
            Test-Path -LiteralPath $stateFile | Should -BeFalse
        }

        It 'falls back to Automatic and mode 2 without a saved state' {
            Enable-Search

            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WSearch' -and $StartupType -eq 'Automatic'
            }
            Should -Invoke Set-TaskbarSearchMode -Times 1 -ParameterFilter { $Mode -eq 2 }
        }
    }

    Context 'Invoke-SearchToggle' {
        It 'shows status without touching the service' {
            Mock Show-SearchStatus { }
            Mock Get-Command { [pscustomobject]@{ Name = $Name } }

            Invoke-SearchToggle -Status

            Should -Invoke Show-SearchStatus -Times 1
            Should -Invoke Set-Service -Times 0
        }

        It 'dispatches -Disable to Disable-Search' {
            Mock Disable-Search { }
            Mock Get-Command { [pscustomobject]@{ Name = $Name } }

            Invoke-SearchToggle -Disable

            Should -Invoke Disable-Search -Times 1
        }

        It 'dispatches -Enable to Enable-Search' {
            Mock Enable-Search { }
            Mock Get-Command { [pscustomobject]@{ Name = $Name } }

            Invoke-SearchToggle -Enable

            Should -Invoke Enable-Search -Times 1
        }
    }
}