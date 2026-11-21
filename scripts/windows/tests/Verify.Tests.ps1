# Regression tests for the live verify-minimal.ps1 checks.

Describe 'Live minimal-state verifier' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Initialize-WindowsCmdletStubs
        . (Join-Path $PSScriptRoot '..' 'verify-minimal.ps1')
    }

    BeforeEach {
        $checks.Clear()
    }

    It 'records passing and failing checks' {
        Add-Check 'one' $true 'ok'
        Add-Check 'two' $false 'bad'

        $checks.Count | Should -Be 2
        $checks[0].Ok | Should -BeTrue
        $checks[1].Ok | Should -BeFalse
    }

    It 'reads a registry value and returns null when missing' {
        Mock Get-ItemProperty { [pscustomobject]@{ Start = 4 } }
        Get-RegValue -Path 'HKLM:\TEST' -Name 'Start' | Should -Be 4

        Mock Get-ItemProperty { throw 'missing' }
        Get-RegValue -Path 'HKLM:\TEST' -Name 'Start' | Should -BeNullOrEmpty
    }

    It 'accepts a disabled, stopped service' {
        Mock Get-Service { [pscustomobject]@{ StartType = 'Disabled'; Status = 'Stopped' } }

        Test-ServiceState -Name WSearch -AllowedStartTypes @('Disabled')

        $checks.Count | Should -Be 2
        ($checks | Where-Object { -not $_.Ok }).Count | Should -Be 0
    }

    It 'accepts the Manual/Stopped state Windows uses for WinDefend' {
        Mock Get-Service { [pscustomobject]@{ StartType = 'Manual'; Status = 'Stopped' } }

        Test-ServiceState -Name WinDefend -AllowedStartTypes @('Manual', 'Disabled')

        ($checks | Where-Object { -not $_.Ok }).Count | Should -Be 0
    }

    It 'rejects a running service with the wrong start type' {
        Mock Get-Service { [pscustomobject]@{ StartType = 'Automatic'; Status = 'Running' } }

        Test-ServiceState -Name WinDefend -AllowedStartTypes @('Manual', 'Disabled')

        ($checks | Where-Object { -not $_.Ok }).Count | Should -Be 2
    }

    It 'accepts a missing service' {
        Mock Get-Service { $null }

        Test-ServiceState -Name Sense -AllowedStartTypes @('Disabled')

        $checks.Count | Should -Be 1
        $checks[0].Ok | Should -BeTrue
    }

    It 'detects a running Defender process' {
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'MsMpEng' } }

        Test-NoProcess -Name MsMpEng

        $checks.Count | Should -Be 1
        $checks[0].Ok | Should -BeFalse
    }

    It 'accepts an absent Defender process' {
        Mock Get-Process { $null }

        Test-NoProcess -Name MsMpEng

        $checks.Count | Should -Be 1
        $checks[0].Ok | Should -BeTrue
    }
}