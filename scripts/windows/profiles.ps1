# Profile presets shared by minimal.ps1 and the test suite.
#
# Keep this file free of Windows-only cmdlets so it can be dot-sourced on any
# platform.  A $null result means "custom": the caller keeps its own switches.

function Get-ProfileSettings {
    param(
        [ValidateSet('custom', 'developer', 'power', 'regular')]
        [string]$Mode = 'custom'
    )

    switch ($Mode) {
        'developer' {
            return [pscustomobject]@{
                StockApps     = 'Lean'
                StockServices = 'Aggressive'
                IncludeSearch = $true
                IncludeSysMain = $true
                EnableSsh     = $true
                SkipGaming    = $false
                SkipServices  = $false
            }
        }
        'power' {
            return [pscustomobject]@{
                StockApps     = 'Lean'
                StockServices = 'Balanced'
                IncludeSearch = $false
                IncludeSysMain = $false
                EnableSsh     = $false
                SkipGaming    = $true
                SkipServices  = $true
            }
        }
        'regular' {
            return [pscustomobject]@{
                StockApps     = 'None'
                StockServices = 'None'
                IncludeSearch = $false
                IncludeSysMain = $false
                EnableSsh     = $false
                SkipGaming    = $true
                SkipServices  = $true
            }
        }
        default {
            return $null
        }
    }
}