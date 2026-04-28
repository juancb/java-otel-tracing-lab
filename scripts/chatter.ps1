# PowerShell counterpart to chatter.sh.
#
# Usage:
#   .\scripts\chatter.ps1
#   .\scripts\chatter.ps1 -IntervalSecs 30
#
# Stop with Ctrl+C.

param(
    [int]$IntervalSecs = 15
)

$ErrorActionPreference = "Continue"
$cycle = 0

while ($true) {
    $cycle++
    $table = "chatter_$cycle"
    Write-Host "[chatter] cycle $cycle  table=$table  ts=$(Get-Date -Format HH:mm:ss)"

    $script = @"
create '$table', 'cf'
put '$table', 'r1', 'cf:c', 'v1'
put '$table', 'r2', 'cf:c', 'v2'
put '$table', 'r3', 'cf:c', 'v3'
flush '$table'
scan '$table'
disable '$table'
drop '$table'
"@
    $script | docker compose exec -T hbase-master hbase shell -n 2>&1 |
        Where-Object { $_ -notmatch '^\s*$|deprecation|SLF4J' }

    if (($cycle % 5) -eq 0) {
        Write-Host "[chatter] cycle $cycle  cluster status + balancer toggle"
        @"
status 'detailed'
balance_switch true
balancer
"@ | docker compose exec -T hbase-master hbase shell -n 2>&1 |
            Where-Object { $_ -notmatch '^\s*$|deprecation|SLF4J' }
    }

    Start-Sleep -Seconds $IntervalSecs
}
