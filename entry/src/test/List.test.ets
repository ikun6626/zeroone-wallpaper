import localUnitTest from './LocalUnit.test';
import canvasGeometryTest from './CanvasGeometry.test';

export default function testsuite() {
  localUnitTest();
  canvasGeometryTest();
}
