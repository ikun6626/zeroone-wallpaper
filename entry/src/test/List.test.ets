import localUnitTest from './LocalUnit.test';
import canvasGeometryTest from './CanvasGeometry.test';
import cropGeometryTest from './CropGeometry.test';

export default function testsuite() {
  localUnitTest();
  canvasGeometryTest();
  cropGeometryTest();
}
