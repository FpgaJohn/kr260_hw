@echo off
setlocal

set XSCT=C:\Xilinx\Vitis\2024.1\bin\xsct.bat
set DIR=%~dp0

echo === Step 1: Create platform ===
call "%XSCT%" "%DIR%create_platform.tcl"
if errorlevel 1 ( echo FAILED: create_platform.tcl & goto :error )

echo === Step 2: Create bare-metal app ===
call "%XSCT%" "%DIR%create_baremetal_app.tcl"
if errorlevel 1 ( echo FAILED: create_baremetal_app.tcl & goto :error )

echo === Step 3: Create FreeRTOS app ===
call "%XSCT%" "%DIR%create_freertos_app.tcl"
if errorlevel 1 ( echo FAILED: create_freertos_app.tcl & goto :error )

echo.
echo === All builds complete ===
echo Bare-metal ELF : %DIR%win_hw\Debug\win_hw.elf
echo FreeRTOS ELF   : %DIR%freertos_hw\Debug\freertos_hw.elf
echo.
echo To run on hardware:
echo   xsct.bat "%DIR%run_baremetal.tcl"
echo   xsct.bat "%DIR%run_freertos.tcl"
goto :eof

:error
echo.
echo Build stopped due to error.
exit /b 1
