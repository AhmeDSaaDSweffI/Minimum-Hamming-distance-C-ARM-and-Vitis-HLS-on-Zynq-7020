# ============================================================================
# make_overleaf_zip.ps1 - pack the Overleaf project of the report
#
#   overleaf_project.zip = min_hamming_report.tex + figures\   (in this folder)
#
# Upload it in Overleaf with  New Project > Upload Project  (compiler: pdfLaTeX).
# Uses Windows' tar.exe: Compress-Archive in Windows PowerShell 5 stores paths
# with backslashes, which Overleaf would take as file names, not folders.
# ============================================================================
$report = $PSScriptRoot
$zip = Join-Path $report 'overleaf_project.zip'
if (Test-Path $zip) {
    Remove-Item $zip -Force
}
Push-Location $report
try {
    tar -a -c -f overleaf_project.zip min_hamming_report.tex figures
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
"zip: $zip"
