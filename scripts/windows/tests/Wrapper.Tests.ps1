# Packaging regression tests: every launcher points at a real script and every
# PowerShell file parses.

Describe 'Helper packaging' {
    BeforeAll {
        $script:windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    It 'has a valid PowerShell syntax tree for every script' {
        $failures = @()
        Get-ChildItem -LiteralPath $script:windowsRoot -Filter '*.ps1' -Recurse | ForEach-Object {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -gt 0) {
                $failures += ("{0}: {1}" -f $_.Name, ($errors.Message -join '; '))
            }
        }
        $failures | Should -BeNullOrEmpty
    }

    It 'resolves every %~dp0 target from a launcher' {
        $missing = @()
        Get-ChildItem -LiteralPath $script:windowsRoot -Filter '*.bat' | ForEach-Object {
            $content = Get-Content -LiteralPath $_.FullName -Raw
            foreach ($match in [regex]::Matches($content, '%~dp0([^"\s]+\.(?:ps1|bat))')) {
                $target = $match.Groups[1].Value
                $local = Join-Path $script:windowsRoot $target
                $setup = Join-Path $script:repoRoot ("windows/scripts/" + $target)
                if (-not (Test-Path -LiteralPath $local) -and -not (Test-Path -LiteralPath $setup)) {
                    $missing += ("{0} -> {1}" -f $_.Name, $target)
                }
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'has launchers for Search, Defender and the live verifier' {
        foreach ($name in 'disable-search.bat', 'enable-search.bat', 'manage-defender.bat', 'verify-minimal.bat') {
            Test-Path -LiteralPath (Join-Path $script:windowsRoot $name) | Should -BeTrue
        }
    }

    It 'keeps the Search launchers wired to the right switch' {
        (Get-Content -LiteralPath (Join-Path $script:windowsRoot 'disable-search.bat') -Raw) |
            Should -Match 'toggle-search\.ps1"\s+-Disable'
        (Get-Content -LiteralPath (Join-Path $script:windowsRoot 'enable-search.bat') -Raw) |
            Should -Match 'toggle-search\.ps1"\s+-Enable'
    }
}