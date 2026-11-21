# Regression tests for the tabbed helper menu wiring.
#
# The TUI itself needs a Windows console.  These tests inspect the menu model so
# the Search/Defender actions and the Developer profile cannot silently drift.

Describe 'Tabbed helper menu' {
    BeforeAll {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ('winslim-helper-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
        $env:ProgramData = $script:testRoot
        . (Join-Path $PSScriptRoot '..' 'helper.ps1')

        function Get-MenuNode {
            param([object[]]$Items)
            foreach ($item in $Items) {
                $item
                if ($item.Children) {
                    Get-MenuNode -Items $item.Children
                }
            }
        }

        $script:allNodes = @(
            foreach ($tab in $script:Tabs) {
                Get-MenuNode -Items $tab.Items
            }
        )
    }

    AfterAll {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'has Restore, Profiles and Changes tabs' {
        $script:Tabs.Count | Should -Be 3
        $script:Tabs.Title | Should -Be @('Restore', 'Profiles', 'Changes')
    }

    It 'has a plain Developer profile that keeps Defender on' {
        $profiles = ($script:Tabs | Where-Object Title -eq 'Profiles').Items
        $developer = $profiles | Where-Object Label -eq 'Developer (most aggressive)'

        $developer | Should -Not -BeNullOrEmpty
        $developer.Description | Should -Match 'Defender stays on'
        $developer.Action.ToString() | Should -Match "minimal\.ps1"
        $developer.Action.ToString() | Should -Match "Mode\s*=\s*'developer'"
        $developer.Action.ToString() | Should -Not -Match 'manage-defender\.ps1'
    }

    It 'has a separate Developer + Defender off profile' {
        $profiles = ($script:Tabs | Where-Object Title -eq 'Profiles').Items
        $developerOff = $profiles | Where-Object Label -eq 'Developer + Defender off'

        $developerOff | Should -Not -BeNullOrEmpty
        $developerOff.Description | Should -Match 'Tamper Protection'
        $developerOff.Action.ToString() | Should -Match 'minimal\.ps1'
        $developerOff.Action.ToString() | Should -Match 'manage-defender\.ps1'
        $developerOff.Action.ToString() | Should -Match 'Disable\s*=\s*\$true'
    }

    It 'has Power and Regular profile entries' {
        $profiles = ($script:Tabs | Where-Object Title -eq 'Profiles').Items
        $profiles.Label | Should -Contain 'Power user (balanced)'
        $profiles.Label | Should -Contain 'Regular user (light)'
    }

    It 'exposes Search disable, enable and status actions' {
        $script:allNodes.Label | Should -Contain 'Windows Search: disable'
        $script:allNodes.Label | Should -Contain 'Windows Search: enable'
        $script:allNodes.Label | Should -Contain 'Windows Search: status'

        $disable = $script:allNodes | Where-Object Label -eq 'Windows Search: disable'
        $disable.Action.ToString() | Should -Match "toggle-search\.ps1"
        $disable.Action.ToString() | Should -Match 'Disable\s*=\s*\$true'
    }

    It 'exposes Defender status, disable, enable and Tamper Protection actions' {
        $script:allNodes.Label | Should -Contain 'Microsoft Defender: status'
        $script:allNodes.Label | Should -Contain 'Disable Microsoft Defender'
        $script:allNodes.Label | Should -Contain 'Enable Microsoft Defender'
        $script:allNodes.Label | Should -Contain 'Open Tamper Protection settings'

        $tamper = $script:allNodes | Where-Object Label -eq 'Open Tamper Protection settings'
        $tamper.Action.ToString() | Should -Match 'OpenTamper\s*=\s*\$true'
    }
}