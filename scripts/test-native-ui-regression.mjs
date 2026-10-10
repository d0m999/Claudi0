// Driver regression only: fixture frames and AX responses do not verify native UI.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {createNativeUIRegression} from './native-ui-regression.mjs';

const destinations=['events-and-sounds','sounds','integrations','notifications','general','shortcuts','usage','about'];
const sidebarLabels={
  'zh-Hans':['工作区','声音','集成','通知','通用','快捷键','活动与诊断','关于'],
  en:['Workspace','Sounds','Integrations','Notifications','General','Shortcuts','Activity & Diagnostics','About'],
};
const currentGaps=[0,0,0,16,0,16,0];

async function createDriverFixture(t,gaps,{mutateReadback=()=>{},mutateState=state=>state}={}) {
  const root=path.join(os.tmpdir(),'claudio-sidebar-driver-test');
  const bundle=path.join(root,'fixture.app');
  const buildEvidence=path.join(root,'build-evidence.json');
  const screenshotOCR=path.join(root,'screenshot-ocr');
  const outputDirectory=path.join(root,'evidence');
  const activeFile=path.join(os.tmpdir(),'claudio-native-regression-active.json');
  const files=new Map([
    [buildEvidence,JSON.stringify({bundle,screenshotOCR,bundleSHA256:'driver-test'})],
    [activeFile,JSON.stringify({bundle,root})],
    [screenshotOCR,Buffer.from('unused OCR fixture')],
  ]);
  let matrixIndex=1;
  let destination=destinations[0];
  let showingControls=false;

  function readback() {
    const minimum=matrixIndex%2===0;
    const dark=matrixIndex%4===3||matrixIndex%4===0;
    const frameWidth=minimum?960:1240;
    const frameHeight=minimum?640:820;
    // Native toolbar safe area makes content shorter than the requested window frame.
    const width=frameWidth;
    const height=frameHeight-72;
    const sidebarWidth=minimum?210:252;
    const padding=minimum?26:32;
    const reading={x:sidebarWidth+padding,y:60,width:Math.min(780,width-sidebarWidth)-padding*2,height:500};
    const frames={
      'settings.sidebar':{x:0,y:0,width:sidebarWidth,height},
      'settings.content':{x:sidebarWidth,y:0,width:width-sidebarWidth,height},
      [`settings.reading.${destination}`]:reading,
    };
    let y=60;
    destinations.forEach((id,i)=> {
      // Vary row heights to ensure gaps are measured from each preceding row's bottom.
      const height=i%2===0?32:44;
      frames[`settings.sidebar.item.${id}`]={x:12,y,width:sidebarWidth-24,height};
      y+=height+(gaps[i]??0);
    });
    for (const prefix of ['workspace','sound-packs']) {
      frames[`${prefix}.events.group`]={...reading,y:140,height:200};
      for (let i=0;i<5;i++) frames[`${prefix}.event-row.${i}`]={...reading,y:140+i*40,height:40};
    }
    // Deliberately differ from the old fixed RGB palette; these are simulated semantic colors.
    const background=dark?[27,29,32]:[236,235,234];
    const card=dark?[40,43,47]:[250,249,248];
    const result={
      destination,
      windowGeometry:{width,height,frameWidth,frameHeight,appearance:dark?'NSAppearanceNameDarkAqua':'NSAppearanceNameAqua'},
      settingsLayout:{sampleColorSpace:'sRGB',frames,semanticColors:{window:background,group:card},colors:{background:[background,background,background],card}},
    };
    mutateReadback(result);
    return result;
  }

  // Mock all driver I/O, including the global active marker; never touch a running fixture.
  const readFile=fs.readFile.bind(fs);
  t.mock.method(fs,'readFile',async(file,...args)=> {
    if (file instanceof URL) return readFile(file,...args);
    if (file===path.join(root,'readback.json')) return JSON.stringify(readback());
    if (files.has(file)) return files.get(file);
    throw Object.assign(new Error(`Fixture file not found: ${file}`),{code:'ENOENT'});
  });
  t.mock.method(fs,'realpath',async file=>file);
  t.mock.method(fs,'mkdir',async()=>undefined);
  t.mock.method(fs,'writeFile',async(file,bytes)=> {files.set(file,bytes);});

  function state() {
    if (showingControls) return 'Window: "Claudio UI Regression"\n'+Array.from({length:8},(_,i)=>`${i+1} button Matrix ${i+1}`).join('\n')+'\n9 button Capture state';
    const labels=sidebarLabels[matrixIndex<=4?'zh-Hans':'en'];
    return mutateState(`Window: "claudi0 · Settings"\n20 heading ID: settings.title.${destination}\n21 table ID: settings.sidebar\n`+destinations.map((id,i)=>`  ${30+i} row ${id===destination?'(selected) ':''}\n    ${60+i} text ${labels[i]}`).join('\n'));
  }
  const app={
    async getAXState() {return state();},
    async getAXStateAndScreenshot() {return {state:state(),screenshot:Buffer.from([255,216,255,217])};},
    async pressKey(key) {showingControls=key==='super+shift+0';},
    async click(index) {
      if (index>=1&&index<=8) {matrixIndex=index;showingControls=false;}
      else if (index>=30&&index<38) destination=destinations[index-30];
      else assert.equal(index,9,'Unexpected fixture action');
    },
  };
  return createNativeUIRegression({cua:{},app,buildEvidence,outputDirectory});
}

for (let index=1;index<=8;index++) {
  test(`matrix ${index} accepts current sidebar spacing on all eight pages`,async t=> {
    const run=await createDriverFixture(t,currentGaps);
    const result=await run.matrix(index);
    assert.equal(result.status,'passed',result.reason);
    const layouts=run.report.results[0].assertions.layouts;
    const geometry=run.report.results[0].assertions.actualGeometry;
    assert.equal(geometry.frameWidth,index%2===0?960:1240);
    assert.equal(geometry.frameHeight,index%2===0?640:820);
    assert.ok(geometry.height<geometry.frameHeight,'Native toolbar must reduce the fixture content height');
    assert.deepEqual(layouts.map(layout=>layout.destination),destinations);
    for (const layout of layouts) assert.deepEqual(layout.sidebarGaps,currentGaps);
  });
}

test('matrix rejects legacy sidebar spacing at the first page',async t=> {
  const run=await createDriverFixture(t,[3,3,3,24,3,24,3]);
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/Sidebar group spacing differs: 3,3,3,24,3,24,3/);
});

currentGaps.forEach((gap,i)=> {
  test(`matrix rejects incorrect spacing at sidebar gap ${i+1}`,async t=> {
    // Group boundaries have a minimum; ordinary rows still have no inter-row gap.
    const gaps=currentGaps.with(i,[3,5].includes(i)?gap-2:gap+2);
    const run=await createDriverFixture(t,gaps);
    const result=await run.matrix(1);
    assert.equal(result.status,'failed');
    assert.ok(result.reason.includes(`Sidebar group spacing differs: ${gaps}`),result.reason);
  });
});

test('matrix accepts native group spacing above the minimum',async t=> {
  const gaps=[0,0,0,20,0,24,0];
  const run=await createDriverFixture(t,gaps);
  const result=await run.matrix(1);
  assert.equal(result.status,'passed',result.reason);
  for (const layout of run.report.results[0].assertions.layouts) assert.deepEqual(layout.sidebarGaps,gaps);
});

test('matrix rejects missing native frame dimensions',async t=> {
  const run=await createDriverFixture(t,currentGaps,{mutateReadback(read) {
    delete read.windowGeometry.frameWidth;
    delete read.windowGeometry.frameHeight;
  }});
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/Requested window size was constrained/);
});

test('matrix rejects a constrained native window frame',async t=> {
  const run=await createDriverFixture(t,currentGaps,{mutateReadback(read) {
    read.windowGeometry.frameWidth=1100;
  }});
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/Requested window size was constrained/);
});

test('matrix rejects missing system semantic colors',async t=> {
  const run=await createDriverFixture(t,currentGaps,{mutateReadback(read) {
    delete read.settingsLayout.semanticColors;
  }});
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/The system window semantic color was not resolved/);
});

for (const surface of ['background','card']) {
  test(`matrix rejects sampled ${surface} that differs from the system semantic color`,async t=> {
    const run=await createDriverFixture(t,currentGaps,{mutateReadback(read) {
      read.settingsLayout.colors[surface]=surface==='background'?[[1,2,3],[1,2,3],[1,2,3]]:[1,2,3];
    }});
    const result=await run.matrix(1);
    assert.equal(result.status,'failed');
    assert.match(result.reason,surface==='background'?/Settings background differs/:/Settings group surface differs/);
  });
}

test('matrix rejects an AX sidebar without a native source-list table',async t=> {
  const run=await createDriverFixture(t,currentGaps,{mutateState:state=>state.replace('table ID: settings.sidebar','group ID: settings.sidebar')});
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/The Settings sidebar must be a native source-list table/);
});

test('matrix rejects a native row whose selection did not update',async t=> {
  const run=await createDriverFixture(t,currentGaps,{mutateState:state=>state.replace('(selected) ','')});
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/Sidebar selection did not match events-and-sounds/);
});

test('matrix rejects ambiguous native source-list rows',async t=> {
  const run=await createDriverFixture(t,currentGaps,{mutateState:state=>state+'\n  80 row\n    81 text 工作区'});
  const result=await run.matrix(1);
  assert.equal(result.status,'failed');
  assert.match(result.reason,/Native source-list row is not unique: events-and-sounds/);
});
