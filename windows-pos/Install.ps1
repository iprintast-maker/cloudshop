param([switch]$Uninstall)
$ErrorActionPreference='Stop'
$appRoot=Join-Path $env:LOCALAPPDATA 'IprintDesk\App'
$desktop=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Айпринт - Касса.lnk'
$menu=Join-Path ([Environment]::GetFolderPath('Programs')) 'Айпринт - Касса.lnk'
try {
 if($Uninstall){
  Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'IprintDesk' -ErrorAction SilentlyContinue
  foreach($link in @($desktop,$menu)){Remove-Item $link -Force -ErrorAction SilentlyContinue}
  if(Test-Path $appRoot){Remove-Item $appRoot -Recurse -Force}
  Write-Host 'Программа удалена. Вход и черновики сохранены в LocalAppData\IprintDesk.';exit 0
 }
 if(-not [Environment]::Is64BitOperatingSystem){throw 'Эта версия предназначена для 64-разрядной Windows 10/11.'}
 $source=Join-Path $PSScriptRoot 'IprintDesk.exe';if(-not(Test-Path $source)){throw 'Сначала распакуйте весь ZIP в папку, затем запустите INSTALL.cmd.'}
 $runtime=$false
 foreach($base in @("${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application","$env:ProgramFiles\Microsoft\EdgeWebView\Application","$env:LOCALAPPDATA\Microsoft\EdgeWebView\Application")){
  if(Test-Path $base){foreach($folder in Get-ChildItem $base -Directory -ErrorAction SilentlyContinue){if(Test-Path (Join-Path $folder.FullName 'msedgewebview2.exe')){$runtime=$true}}}
 }
 if(-not $runtime){
  Write-Host 'Устанавливаем бесплатный компонент Microsoft WebView2...'
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $bootstrap=Join-Path $env:TEMP ('Iprint-WebView2-'+[guid]::NewGuid().ToString()+'.exe')
  try{
   Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $bootstrap -UseBasicParsing
   $signature=Get-AuthenticodeSignature $bootstrap
   if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'){throw 'Не удалось проверить подпись установщика Microsoft WebView2.'}
   $p=Start-Process $bootstrap -ArgumentList '/silent','/install' -Wait -PassThru
   if($p.ExitCode -notin @(0,3010)){throw ('Не удалось установить WebView2. Код: '+$p.ExitCode)}
  }finally{Remove-Item $bootstrap -Force -ErrorAction SilentlyContinue}
 }
 New-Item $appRoot -ItemType Directory -Force | Out-Null
 foreach($file in @('IprintDesk.exe','Install.ps1','UNINSTALL.cmd','README.txt')){Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $appRoot $file) -Force}
 $shell=New-Object -ComObject WScript.Shell
 foreach($link in @($desktop,$menu)){$s=$shell.CreateShortcut($link);$s.TargetPath=Join-Path $appRoot 'IprintDesk.exe';$s.WorkingDirectory=$appRoot;$s.Description='Касса Айпринта поверх других окон';$s.Save()}
 Write-Host 'Готово. Создан ярлык «Айпринт - Касса».'
 Start-Process (Join-Path $appRoot 'IprintDesk.exe')
}catch{Write-Host ('Не удалось установить: '+$_.Exception.Message) -ForegroundColor Red;Write-Host 'Если программа уже открыта, завершите продажу, закройте её и повторите установку.';exit 1}
