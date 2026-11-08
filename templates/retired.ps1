# @TOOL@ was retired on @DATE@. This notice replaces its install script.
& {
  $Notice = @'

@TOOL@ is no longer distributed here (retired @DATE@).

@BLOCK@

'@
  Write-Host $Notice -ForegroundColor Yellow
  throw '@TOOL@ has been retired.'
}
