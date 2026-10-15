@echo off
rem Double-click to set up the TroyMetrics overlays for a Thermal Grizzly WireView Pro II.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WireViewSetup.ps1" %*
