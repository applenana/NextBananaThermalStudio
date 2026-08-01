Unicode true

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!ifndef APP_FILE_VERSION
  !define APP_FILE_VERSION "${APP_VERSION}.0"
!endif

!define APP_NAME "BananaThermal Studio"
!define APP_EXE "banana_thermal.exe"
!define APP_PUBLISHER "applenana"
!define APP_URL "https://github.com/applenana/NextBananaThermalStudio"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\BananaThermalStudio"

!include "MUI2.nsh"

Name "${APP_NAME}"
OutFile "..\dist\BananaThermal-windows-x64-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\BananaThermalStudio"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
BrandingText "${APP_NAME} ${APP_VERSION}"

VIProductVersion "${APP_FILE_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=2052 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyright ${APP_PUBLISHER}"

!define MUI_ICON "..\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "..\windows\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  ; 应用内启动安装器时旧进程仍在运行。确认后先正常结束它，避免覆盖失败。
  FindWindow $0 "" "BananaThermalStudio"
  IntCmp $0 0 app_not_running
  MessageBox MB_OKCANCEL|MB_ICONINFORMATION \
    "安装程序需要关闭正在运行的 ${APP_NAME}。$\n$\n点击“确定”继续，未保存的操作将会停止。" \
    IDOK close_app IDCANCEL cancel_install

  close_app:
    nsExec::ExecToLog 'taskkill /IM "${APP_EXE}" /T'
    Sleep 1500
    Goto app_not_running

  cancel_install:
    Abort

  app_not_running:
FunctionEnd

Section "主程序" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"
  SetOverwrite on
  File /r "..\build\windows\x64\runner\Release\*"

  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "${APP_URL}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APP_NAME}"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  RMDir /r "$INSTDIR"
SectionEnd
