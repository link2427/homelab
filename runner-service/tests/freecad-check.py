"""Run inside freecadcmd, which supplies its matching embedded Python."""
import json
from pathlib import Path
import FreeCAD
import Part

shape = Part.makeBox(1, 1, 1)
assert shape.isValid() and abs(shape.Volume - 1) < 1e-9
shape.exportStep("cube.step")
Path("freecad-ok.json").write_text(json.dumps({"version": FreeCAD.Version(), "volume": shape.Volume}))
