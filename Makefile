POWERSHELL := powershell.exe
PS_FLAGS := -NoProfile -ExecutionPolicy Bypass
HWND_ARG := $(if $(HWND),-OnlyHwnd $(HWND),)
BROWSER_ARG := $(if $(BROWSER),-Browser $(BROWSER),)

.PHONY: all capture index open check help

all: capture
	$(POWERSHELL) $(PS_FLAGS) -File ".\build-index.ps1"

capture:
	$(POWERSHELL) $(PS_FLAGS) -File ".\capture.ps1" $(BROWSER_ARG) $(HWND_ARG)

index:
	$(POWERSHELL) $(PS_FLAGS) -File ".\build-index.ps1"

open: index
	$(POWERSHELL) $(PS_FLAGS) -Command "Start-Process -LiteralPath '.\index.html'"

check:
	$(POWERSHELL) $(PS_FLAGS) -Command '$$required = @(".\capture.ps1", ".\build-index.ps1", ".\index.template.html"); $$missing = $$required | Where-Object { -not (Test-Path -LiteralPath $$_ -PathType Leaf) }; if ($$missing) { throw ("Missing required files: " + ($$missing -join ", ")) }; if (-not (Get-Module -ListAvailable -Name VirtualDesktop)) { throw "PowerShell module VirtualDesktop is not installed. Run: Install-Module VirtualDesktop -Scope CurrentUser" }; Write-Host "Browser archive prerequisites are available."'

help:
	@echo make all                  Capture all tabs and generate index.html
	@echo make capture              Capture all Helium and Chrome tabs
	@echo make capture BROWSER=Chrome  Capture only Google Chrome tabs
	@echo make capture HWND=67934   Capture one window for testing
	@echo make index                Generate index.html from tabs.md
	@echo make open                 Generate and open index.html
	@echo make check                Check scripts and PowerShell module
