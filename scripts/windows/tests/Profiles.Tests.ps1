# Regression tests for the minimal-profile presets.

Describe 'Profile presets' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'profiles.ps1')
    }

    It 'keeps Developer aggressive and enables Search, SysMain and SSH' {
        $profile = Get-ProfileSettings -Mode developer

        $profile.StockApps | Should -Be 'Lean'
        $profile.StockServices | Should -Be 'Aggressive'
        $profile.IncludeSearch | Should -BeTrue
        $profile.IncludeSysMain | Should -BeTrue
        $profile.EnableSsh | Should -BeTrue
        $profile.SkipGaming | Should -BeFalse
        $profile.SkipServices | Should -BeFalse
    }

    It 'keeps Power user balanced and does not disable Search or SysMain' {
        $profile = Get-ProfileSettings -Mode power

        $profile.StockApps | Should -Be 'Lean'
        $profile.StockServices | Should -Be 'Balanced'
        $profile.IncludeSearch | Should -BeFalse
        $profile.IncludeSysMain | Should -BeFalse
        $profile.EnableSsh | Should -BeFalse
        $profile.SkipGaming | Should -BeTrue
        $profile.SkipServices | Should -BeTrue
    }

    It 'keeps Regular user light and skips app/service changes' {
        $profile = Get-ProfileSettings -Mode regular

        $profile.StockApps | Should -Be 'None'
        $profile.StockServices | Should -Be 'None'
        $profile.IncludeSearch | Should -BeFalse
        $profile.IncludeSysMain | Should -BeFalse
        $profile.SkipGaming | Should -BeTrue
        $profile.SkipServices | Should -BeTrue
    }

    It 'returns null for custom so explicit switches are preserved' {
        Get-ProfileSettings -Mode custom | Should -BeNullOrEmpty
    }

    It 'is wired into minimal.ps1' {
        $minimal = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'minimal.ps1') -Raw
        $minimal | Should -Match 'profiles\.ps1'
        $minimal | Should -Match 'Get-ProfileSettings'
    }
}