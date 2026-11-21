# Regression tests for the Defender helper.
#
# The tests never touch a real Defender installation.  Tamper Protection,
# services, policies and the settings page are mocked.

Describe 'Defender helper' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Initialize-WindowsCmdletStubs
        . (Join-Path $PSScriptRoot '..' 'manage-defender.ps1')
    }

    BeforeEach {
        Mock Test-Admin { $true }
        Mock Get-Command { [pscustomobject]@{ Name = $Name } }
        Mock Get-MpComputerStatus {
            [pscustomobject]@{
                AntivirusEnabled         = $false
                RealTimeProtectionEnabled = $false
                IsTamperProtected        = $false
                AntivirusSignatureVersion = '1.0.0.0'
                AntivirusSignatureLastUpdated = Get-Date
            }
        }
        Mock Get-MpPreference {
            [pscustomobject]@{ DisableRealtimeMonitoring = $true; ExclusionPath = @() }
        }
        Mock Set-MpPreference { }
        Mock Get-Service {
            [pscustomobject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Set-Service { }
        Mock Stop-Service { }
        Mock Start-Service { }
        Mock Set-Dword { }
        Mock Remove-ItemProperty { }
        Mock Start-Process { }
    }

    Context 'Disable-Defender' {
        It 'sets the policy keys and disables both Defender services' {
            Disable-Defender

            Should -Invoke Set-Dword -Times 1 -ParameterFilter {
                $Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -and
                $Name -eq 'DisableAntiSpyware' -and $Value -eq 1
            }
            Should -Invoke Set-Dword -Times 1 -ParameterFilter {
                $Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -and
                $Name -eq 'DisableAntiVirus' -and $Value -eq 1
            }
            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WinDefend' -and $StartupType -eq 'Disabled'
            }
            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WdNisSvc' -and $StartupType -eq 'Disabled'
            }
            Should -Invoke Stop-Service -Times 2
            Should -Invoke Set-MpPreference -Times 1
        }

        It 'refuses to change anything while Tamper Protection is on' {
            Mock Get-MpComputerStatus { [pscustomobject]@{ IsTamperProtected = $true } }

            Disable-Defender

            Should -Invoke Start-Process -Times 1 -ParameterFilter {
                $FilePath -eq 'windowsdefender://threatsettings'
            }
            Should -Invoke Set-MpPreference -Times 0
            Should -Invoke Set-Dword -Times 0
            Should -Invoke Set-Service -Times 0
            Should -Invoke Stop-Service -Times 0
        }

        It 'warns and changes nothing without elevation' {
            Mock Test-Admin { $false }
            Mock Write-Warning { }

            Disable-Defender

            Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                $Message -match 'elevated'
            }
            Should -Invoke Set-Dword -Times 0
            Should -Invoke Set-Service -Times 0
        }
    }

    Context 'Enable-Defender' {
        It 'removes the policies and restores the service start types' {
            Enable-Defender

            Should -Invoke Remove-ItemProperty -Times 1 -ParameterFilter {
                $Name -eq 'DisableAntiSpyware'
            }
            Should -Invoke Remove-ItemProperty -Times 1 -ParameterFilter {
                $Name -eq 'DisableAntiVirus'
            }
            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WinDefend' -and $StartupType -eq 'Automatic'
            }
            Should -Invoke Set-Service -Times 1 -ParameterFilter {
                $Name -eq 'WdNisSvc' -and $StartupType -eq 'Manual'
            }
            Should -Invoke Start-Service -Times 2
            Should -Invoke Set-MpPreference -Times 1
        }

        It 'warns and changes nothing without elevation' {
            Mock Test-Admin { $false }
            Mock Write-Warning { }

            Enable-Defender

            Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                $Message -match 'elevated'
            }
            Should -Invoke Remove-ItemProperty -Times 0
            Should -Invoke Set-Service -Times 0
        }
    }

    Context 'Show-DefenderStatus' {
        It 'reports status without changing settings' {
            { Show-DefenderStatus } | Should -Not -Throw
            Should -Invoke Set-Dword -Times 0
            Should -Invoke Set-Service -Times 0
            Should -Invoke Set-MpPreference -Times 0
        }
    }
}