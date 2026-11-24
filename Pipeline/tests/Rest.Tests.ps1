BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'VDI-GIPipeline.psd1') -Force
}

Describe 'Horizon desktop pool lookup' {
    BeforeEach {
        InModuleScope VDI-GIPipeline { $script:GIHorizon = @{ BaseUri = 'https://hz/rest'; AccessToken = 't'; SkipCert = $false } }
    }
    AfterEach {
        InModuleScope VDI-GIPipeline { $script:GIHorizon = $null }
    }

    It 'returns one pool with a string id when the API hands back the page as a single array object' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIRestWithRetry {
            $page = @([pscustomobject]@{ id = 'p1'; name = 'JWGenTest' }, [pscustomobject]@{ id = 'p2'; name = 'JWPRDTest' })
            Write-Output -NoEnumerate $page
        }
        $pool = Get-GIHorizonPool -Name 'JWPRDTest'
        $pool.id | Should -Be 'p2'
        $pool.id | Should -BeOfType [string]
    }

    It 'unrolls a single-array page in Invoke-GIHorizonApi -All' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIRestWithRetry {
            Write-Output -NoEnumerate @([pscustomobject]@{ id = 'a' }, [pscustomobject]@{ id = 'b' }, [pscustomobject]@{ id = 'c' })
        }
        $r = @(Invoke-GIHorizonApi -Path '/inventory/v1/desktop-pools' -All)
        $r.Count | Should -Be 3
    }

    It 'throws a clear message when the pool is missing' {
        Mock -ModuleName VDI-GIPipeline Invoke-GIRestWithRetry { Write-Output -NoEnumerate @([pscustomobject]@{ id = 'a'; name = 'x' }) }
        { Get-GIHorizonPool -Name 'nope' } | Should -Throw "*'nope' not found*"
    }
}
