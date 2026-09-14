#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Applies custom Go style transformations then runs gofmt across a project.

.DESCRIPTION
    Processes all .go files under ProjectPath in parallel (skipping generated,
    packages/, and format:skip files) and applies four transformations:
      1. ParametersOnSeparateLines — splits long function signatures onto separate lines
      2. RemoveBlankLinesBeforeClosingBrace — removes trailing blank lines before }
      3. SpaceAfterCurlyClose — ensures a blank line after a closing brace
      4. EnsureBlankLineBeforeComment — inserts a blank line before standalone comments

    Modified files are written to a temp file (<file>.fmt.go), batched through
    `gofmt -w`, and moved back to the original path only if the formatted result
    differs from the original. Unmodified temp files are discarded.

.PARAMETER ProjectPath
    Root directory of the Go module to format.

.EXAMPLE
    ./FormatGoCode.ps1 -ProjectPath ../internal/server-base
#>
param(
    [Parameter(Mandatory = $True)]
    [string]$ProjectPath
)

if ($null -eq (Get-Command gofmt -ErrorAction SilentlyContinue)) {
    Write-Host "gofmt not found on PATH" -ForegroundColor Red
    exit 1
}

$originalPath = Get-Location
$startTime = Get-Date

Set-Location $ProjectPath

# Thread-safe collections for parallel phase
$needsFormat = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
$processedBag = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
$parallelErrors = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

# Phase 1: Apply custom transformations in parallel across all .go files
Get-ChildItem -Path $ProjectPath -Filter "*.go" -Recurse | ForEach-Object -Parallel {

    $fullName = $_.FullName.Replace("\", "/")

    # Skip generated / dependency paths and our own temp files
    if ($fullName.IndexOf("/packages/") -ge 0 -or
        $fullName.IndexOf("/codegen/") -ge 0 -or
        $fullName.IndexOf("/gencode/") -ge 0 -or
        $fullName.IndexOf(".fmt.go") -ge 0) {
        return
    }

    # --- Transformation functions (inlined for parallel runspace isolation) ---

    function ParametersOnSeparateLines([string]$goCode) {
        $pattern = [regex]"func (\w+)\((\s*([a-zA-Z_]+) (\*?[a-zA-Z.0-9]+),?)+\)((\s+[a-zA-Z.0-9]+)?(\s+\{)?)"
        $matchList = $pattern.Matches($goCode)
        $changeCount = 0

        foreach ($match in $matchList) {
            $find = $match.Value
            $name = $match.Groups[1].Value
            $suffix = $match.Groups[5].Value
            $paramList = @()
            foreach ($capture in $match.Groups[2].Captures) {
                $paramList += "`t" + $capture.Value.TrimStart().TrimEnd(",") + ","
            }

            $replace = ""
            if ($paramList.Count -gt 3 -and $find.Length -gt 100) {
                $replace = @"
func $name(
$([string]::Join("`n", $paramList))
)$suffix
"@.Trim()
            }
            else {
                # Strip the tab prefix and trailing comma from each param for the inline case
                $inlineParams = ($paramList | ForEach-Object { $_.TrimStart("`t").TrimEnd(",") }) -join ", "
                $replace = "func $name($inlineParams)$suffix"
            }

            if ($find -cne $replace) {
                $goCode = $goCode.Replace($find, $replace)
                $changeCount++
            }
        }

        return @{Code = $goCode; Changed = $changeCount -gt 0 }
    }

    function RemoveBlankLinesBeforeClosingBrace([string]$goCode) {
        $pattern = [regex]"(?:\n[\t ]*)+\n([\t ]*})"
        $newCode = $pattern.Replace($goCode, "`n`$1")
        return @{Code = $newCode; Changed = $goCode -cne $newCode }
    }

    function SpaceAfterCurlyClose([string]$goCode) {
        $pattern = [regex]"[}{]?}\n[\t ]*\w+"
        $matchList = $pattern.Matches($goCode)
        $changeCount = 0

        $diff = 0
        $aInt = [int][char]"a"; $zInt = [int][char]"z"
        $zeroInt = [int][char]"0"; $nineInt = [int][char]"9"
        $quoteInt = [int][char]'"'

        foreach ($match in $matchList) {
            $find = $match.Value
            if ($find.StartsWith("{") -or $find.StartsWith("}}")) {
                continue
            }

            $matchIndex = $match.Index + $diff
            $char = $goCode.Substring($matchIndex - 1, 1)
            $charBefore = [int][char]$char
            if (($charBefore -ge $aInt -and $charBefore -le $zInt) -or
                ($charBefore -ge $zeroInt -and $charBefore -le $nineInt) -or
                ($charBefore -eq $quoteInt)) {
                continue
            }

            $startOfLine = $goCode.LastIndexOf("`n", $matchIndex)
            if ($startOfLine -ge 0) {
                $line = $goCode.Substring($startOfLine + 1, $matchIndex - $startOfLine)
                if ($line.StartsWith("func ") -or $line.StartsWith("//")) {
                    continue
                }
            }

            $replace = "}`n`n" + $find.TrimStart("}`n")
            $goCode = $goCode.Substring(0, $matchIndex) + $replace + $goCode.Substring($matchIndex + $match.Length)
            $diff += $replace.Length - $find.Length
            $changeCount++
        }

        return @{Code = $goCode; Changed = $changeCount -gt 0 }
    }

    function EnsureBlankLineBeforeComment([string]$goCode) {
        $lines = $goCode -split "`n"
        $out = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $trimmed = $lines[$i].Trim()
            $isComment = $trimmed.StartsWith("//")
            if ($isComment) {
                $prevNonBlank = -1
                for ($j = $i - 1; $j -ge 0; $j--) {
                    if ($lines[$j].Trim() -ne "") {
                        $prevNonBlank = $j; break
                    }
                }

                $needBlank = $true
                if ($prevNonBlank -lt 0) {
                    $needBlank = $false
                }
                else {
                    $prevLineTrimmed = $lines[$prevNonBlank].Trim()
                    if ($prevLineTrimmed.StartsWith("//")) {
                        $needBlank = $false
                    }
                    else {
                        foreach ($suffix in @("{", "(", ":")) {
                            if ($prevLineTrimmed.EndsWith($suffix)) {
                                $needBlank = $false; break
                            }
                        }
                    }
                }

                $prevIsBlank = ($i -gt 0 -and $lines[$i - 1].Trim() -eq "")
                if ($needBlank -and -not $prevIsBlank) {
                    [void]$out.Add("")
                }
            }

            [void]$out.Add($lines[$i])
        }

        $newCode = $out -join "`n"
        return @{Code = $newCode; Changed = $goCode -cne $newCode }
    }

    try {
        # Single read — use the same content for skip-check and transformation
        $goCode = Get-Content -Path $fullName -Raw
        if ($null -eq $goCode) {
            return
        }

        $top10 = ($goCode -split "`n" | Select-Object -First 10) -join "`n"
        if ($top10 -match "// format:skip" -or
            $top10 -match "code is auto-generated" -or
            $top10 -match "code has been auto-generated") {
            return
        }

        ($using:processedBag).Add(1)

        # Normalize line endings once
        $originalCode = $goCode.Replace("`r", "").Replace("`f", "")
        $goCode = $originalCode

        # Apply transformations in sequence, chaining output
        $r1 = ParametersOnSeparateLines      -goCode $goCode; $goCode = $r1.Code
        $r2 = RemoveBlankLinesBeforeClosingBrace -goCode $goCode; $goCode = $r2.Code
        $r3 = SpaceAfterCurlyClose           -goCode $goCode; $goCode = $r3.Code
        $r4 = EnsureBlankLineBeforeComment   -goCode $goCode; $goCode = $r4.Code

        if ($r1.Changed -or $r2.Changed -or $r3.Changed -or $r4.Changed) {
            # Write temp file — go fmt will be batched in phase 2
            $tempFile = $fullName + ".fmt.go"
            [System.IO.File]::WriteAllText($tempFile, $goCode, [System.Text.UTF8Encoding]::new($false))
            ($using:needsFormat).Add(@{
                    TempFile     = $tempFile
                    OriginalFile = $fullName
                    OriginalCode = $originalCode
                })
        }
        else {
            Write-Host $fullName -ForegroundColor Gray
        }
    }
    catch {
        ($using:parallelErrors).Add("$($fullName): $_")
    }

} -ThrottleLimit 8

# Phase 2: Batch go fmt across all temp files (one process call per batch)
$filesChanged = 0
$gofmtErrors = [System.Collections.Generic.List[string]]::new()

if ($needsFormat.Count -gt 0) {
    $tempFiles = @($needsFormat | ForEach-Object { $_.TempFile })

    # Batch in groups of 50 to stay well within Windows command-line length limits
    $batchSize = 50
    $failedTempFiles = [System.Collections.Generic.HashSet[string]]::new()
    for ($i = 0; $i -lt $tempFiles.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $tempFiles.Count - 1)
        $batch = $tempFiles[$i..$end]
        $gofmtOutput = & gofmt -w @batch 2>&1
        if ($LASTEXITCODE -ne 0) {
            $gofmtErrors.Add("gofmt failed (exit $LASTEXITCODE) on batch starting at index $i`:`n$($gofmtOutput -join "`n")")
            foreach ($batchFile in $batch) {
                [void]$failedTempFiles.Add($batchFile)
            }
        }
    }

    # Phase 3: Compare formatted result to original; move or discard temp file.
    # Files from a failed gofmt batch are never moved over the original — gofmt
    # leaves an unparseable file's content as the pre-gofmt custom-transform
    # output, which must not overwrite real source.
    foreach ($item in $needsFormat) {
        if ($failedTempFiles.Contains($item.TempFile)) {
            Remove-Item -Path $item.TempFile -Force -ErrorAction SilentlyContinue
            continue
        }

        try {
            $formattedCode = Get-Content -Path $item.TempFile -Raw
            $formattedCode = if ($null -ne $formattedCode) {
                $formattedCode.Replace("`r", "").Replace("`f", "")
            }
            else {
                ""
            }

            if ($formattedCode -cne $item.OriginalCode) {
                Write-Host $item.OriginalFile -ForegroundColor Yellow
                Move-Item -Path $item.TempFile -Destination $item.OriginalFile -Force
                $filesChanged++
            }
            else {
                Write-Host $item.OriginalFile -ForegroundColor Gray
                Remove-Item -Path $item.TempFile -Force
            }
        }
        catch {
            $gofmtErrors.Add("Failed to finalize $($item.OriginalFile): $_")
        }
    }
}

Set-Location $originalPath

$endTime = Get-Date
$elapsed = $endTime - $startTime
$filesProcessed = $processedBag.Count
Write-Host "`nProcessed $filesProcessed files, $filesChanged changed" -ForegroundColor Cyan
Write-Host "Completed in $([math]::Round($elapsed.TotalSeconds, 2)) seconds" -ForegroundColor Cyan

$allErrors = @($parallelErrors) + @($gofmtErrors)
if ($allErrors.Count -gt 0) {
    Write-Host "`n$($allErrors.Count) error(s) occurred while formatting:" -ForegroundColor Red
    foreach ($formatError in $allErrors) {
        Write-Host "  $formatError" -ForegroundColor Red
    }

    exit 1
}

exit 0
