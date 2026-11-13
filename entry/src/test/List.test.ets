import localUnitTest from './LocalUnit.test';
import canvasGeometryTest from './CanvasGeometry.test';
import cropGeometryTest from './CropGeometry.test';
import canvasPresetsTest from './CanvasPresets.test';
import layerStoreTest from './LayerStore.test';
import canvasStateTest from './CanvasState.test';
import filterPipelineTest from './FilterPipeline.test';
import homeRulesTest from './HomeRules.test';

export default function testsuite() {
  localUnitTest();
  canvasGeometryTest();
  cropGeometryTest();
  canvasPresetsTest();
  layerStoreTest();
  canvasStateTest();
  filterPipelineTest();
  homeRulesTest();
}
