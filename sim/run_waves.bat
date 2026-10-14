@echo off
rem Optional: simulate both HLS cores in QuestaSim and save waveform screenshots
rem (..\report\figures\questa_*.png). The report uses the Icarus Verilog figures
rem from run_icarus.bat. Keep the QuestaSim window visible until it closes.
cd /d "%~dp0"
vsim -do run_waves.do
