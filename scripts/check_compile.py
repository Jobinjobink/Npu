"""Compile and elaborate RTL and testbench with pyslang 12.x (no simulation)."""
import os
from pathlib import Path
from pyslang.driver import Driver

os.chdir(Path(__file__).resolve().parents[1])
sources = Path('filelist.f').read_text().splitlines()
for top, extra in [('npu_top', []), ('tb_npu', ['tb/tb_npu.sv'])]:
    driver = Driver()
    driver.addStandardArgs()
    command = 'slang --top ' + top + ' ' + ' '.join(sources + extra)
    if not (driver.parseCommandLine(command) and driver.processOptions() and driver.parseAllSources()):
        raise SystemExit(1)
    compilation = driver.createCompilation()
    driver.reportCompilation(compilation, False)
    if not driver.reportDiagnostics(False):
        raise SystemExit(1)
print('PASS: RTL and testbench compilation/elaboration. Simulation not performed.')
