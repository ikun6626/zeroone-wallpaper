import localUnitTest from './LocalUnit.test';
import canvasGeometryTest from './CanvasGeometry.test';
import cropGeometryTest from './CropGeometry.test';
import canvasPresetsTest from './CanvasPresets.test';

export default function testsuite() {
  localUnitTest();
  canvasGeometryTest();
  cropGeometryTest();
  canvasPresetsTest();
}
