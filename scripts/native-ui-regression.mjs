// Run through mcp__cua_repl only. No AppleScript, synthetic events, or remote command channel.
// const { createNativeUIRegression } = await import('/repo/scripts/native-ui-regression.mjs');
// const run = await createNativeUIRegression({cua, app, buildEvidence, outputDirectory, screenshotOCR});
// await run.matrix(1); ... await run.flow(1); await run.flow(8); await run.exceptions();
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const executeFile=promisify(execFile);

export async function createNativeUIRegression({cua, app, buildEvidence, outputDirectory, screenshotOCR}) {
  if (!cua || !app) throw new Error('mcp__cua_repl native interfaces are required');
  const build = JSON.parse(await fs.readFile(buildEvidence, 'utf8'));
  const active = JSON.parse(await fs.readFile(path.join(os.tmpdir(), 'claudio-native-regression-active.json'), 'utf8'));
  if (await fs.realpath(active.bundle) !== await fs.realpath(build.bundle)) throw new Error('The running fixture does not match the built bundle');
  const root = active.root;
  const ocr=screenshotOCR??build.screenshotOCR;
  if (!ocr) throw new Error('The screenshot-only OCR helper is required');
  await fs.mkdir(outputDirectory, {recursive: true});
  const report = {build, driverSHA256: crypto.createHash('sha256').update(await fs.readFile(new URL(import.meta.url))).digest('hex'), active, screenshotOCRSHA256:crypto.createHash('sha256').update(await fs.readFile(ocr)).digest('hex'),actions:[], results: [], boundary: 'Native fixture and local disk effects only. External provider and application activation are substituted. Keyboard, VoiceOver, listening and formal acceptance are separate.'};
  try {
    const previous=JSON.parse(await fs.readFile(path.join(outputDirectory,'results.json'),'utf8'));
    if (previous.build.bundleSHA256===build.bundleSHA256) {
      report.results=previous.results.map(result=>({...result,active:result.active??previous.active,driverSHA256:result.driverSHA256??previous.driverSHA256}));
      report.actions=previous.actions??[];
    }
  } catch (error) { if (error.code!=='ENOENT') throw error; }
  let lastAction='initial state';
  const state = () => app.getAXState({disableDiffing:true,emit:false});
  const number = line => Number(line.match(/^\s*(\d+)/)?.[1]);
  function find(s, predicate) {
    const lines = s.split('\n').filter(line=>/^\s*\d+\b/.test(line)&&predicate(line));
    if (lines.length !== 1) throw new Error(`AX locator expected one control, found ${lines.length}`);
    if (/disabled/i.test(lines[0])) throw new Error(`AX control is disabled: ${lines[0]}`);
    return number(lines[0]);
  }
  async function clickID(id) {
    const s = await state();
    if (id.startsWith('settings.sidebar.') && destinations.includes(id.slice('settings.sidebar.'.length))) {
      const destination=id.slice('settings.sidebar.'.length);
      const row=sidebarRow(s,destination);
      assert(row,'The current native source list has no unique destination row');
      lastAction=`select native sidebar ${destination}`; await app.click(number(row));
      lastAction=`observe after native sidebar ${destination}`; return state();
    }
    const index = find(s, line => line.includes(`ID: ${id}`) && (line.endsWith(id) || line.includes(`ID: ${id},`)));
    lastAction=`click ${id}`; await app.click(index);
    lastAction=`observe after click ${id}`; return state();
  }
  const normalizedText=value=>value.replace(/[^\p{L}\p{N}]/gu,'').toLowerCase();
  async function pointerID(id,{text,anchor,anchorPlacement="below",returnToControls=false,scrollDownIfMissing=false,scrollAttempts=0}={}) {
    const before=await state(); const index=find(before,line=>line.includes(`ID: ${id}`)&&(line.endsWith(id)||line.includes(`ID: ${id},`)));
    const target=before.split('\n').find(line=>number(line)===index);
    const label=text??target.match(/button (?:\(disabled\) )?(?:Description: )?(.+?)(?:,|$)/)?.[1];
    assert(label,'The current AX control has no button label');
    const capture=await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    const filename=`pointer-${report.actions.length+1}.jpg`; const file=path.join(outputDirectory,filename);
    await fs.writeFile(file,capture.screenshot);
    const {stdout}=await executeFile(ocr,[file]); const records=JSON.parse(stdout);
    let candidates=records.filter(record=>normalizedText(record.text)===normalizedText(label));
    if (!candidates.length) candidates=records.filter(record=>normalizedText(record.text).endsWith(normalizedText(label))&&normalizedText(record.text).length<=normalizedText(label).length+2);
    async function scrollAndLocate() {
      assert(scrollDownIfMissing&&scrollAttempts<5,`Screenshot target is not visible: ${label}`);
      const current=await state(); const scroll=current.split('\n').find(line=>/^\s*\d+ scroll area/.test(line)&&!line.includes('sidebar'));
      assert(scroll,'No current content scroll area');
      lastAction=`scroll current content to ${id}`; await app.scroll(number(scroll),'down',0.35); await state();
      return pointerID(id,{text,anchor,anchorPlacement,returnToControls,scrollDownIfMissing,scrollAttempts:scrollAttempts+1});
    }
    if (anchor) {
      const anchorText=normalizedText(anchor);
      let anchors=records.filter(record=>normalizedText(record.text)===anchorText);
      if (!anchors.length) anchors=records.filter(record=>normalizedText(record.text).endsWith(anchorText)&&normalizedText(record.text).length<=anchorText.length+3);
      if (!anchors.length && !id.startsWith('settings.sounds.ai-cue.event.')) anchors=records.filter(record=>normalizedText(record.text).startsWith(anchorText));
      if (!anchors.length && !id.startsWith('settings.sounds.ai-cue.event.')) anchors=records.filter(record=>normalizedText(record.text).includes(anchorText));
      if (!anchors.length && scrollDownIfMissing) return scrollAndLocate();
      assert(anchors.length===1,`Screenshot anchor is not unique: ${anchor}`);
      candidates=anchorPlacement==='same-row'
        ? candidates.filter(record=>Math.abs(record.y-anchors[0].y)<120 && record.x>anchors[0].x).sort((a,b)=>Math.abs(a.y-anchors[0].y)-Math.abs(b.y-anchors[0].y))
        : candidates.filter(record=>record.y>anchors[0].y).sort((a,b)=>a.y-b.y);
      if (candidates.length) candidates=[candidates[0]];
    }
    if (!candidates.length && scrollDownIfMissing) return scrollAndLocate();
    assert(candidates.length===1,`Screenshot button is not unique: ${label}`);
    // OCR reads only the captured artifact. Check the current AX identity again before input.
    const current=await state(); find(current,line=>line.includes(`ID: ${id}`)&&(line.endsWith(id)||line.includes(`ID: ${id},`)));
    const back=await readback();
    const geometry=back.windowGeometry;
    const pixelScale=before.includes('Window: "claudi0 ·') ? geometry.frameWidth*geometry.backingScale/imageWidth(Buffer.from(capture.screenshot)) : 1;
    assert(Number.isFinite(pixelScale)&&pixelScale>0,'Native screenshot coordinate scale is unavailable');
    const point=[candidates[0].x*pixelScale,candidates[0].y*pixelScale];
    report.actions.push({id,AX:target,screenshot:filename,point,pixelScale,OCR:candidates[0],driverSHA256:report.driverSHA256});
    lastAction=`current screenshot pointer ${id}`; await app.click(point);
    if (returnToControls) await app.pressKey('super+shift+0');
    return state();
  }
  async function clickMatching(predicate) {
    const s = await state(); const index=find(s,predicate); lastAction=`click ${s.split('\n').find(line=>number(line)===index)?.trim()}`; await app.click(index); return state();
  }
  async function textID(id,value) {
    lastAction=`focus ${id}`; let s=await state(); const index=find(s,line=>line.includes(`ID: ${id}`) && !line.includes('The focused UI element'));
    const node=s.split('\n').find(line=>number(line)===index);
    if (/text (field|entry area) \(settable\)/.test(node)) {lastAction=`set native text ${id}`; await app.setValue(index,value); return state();}
    for (let count=0; count<10 && !s.split('The focused UI element is ')[1]?.includes(`ID: ${id}`); count++) s=await key('Tab');
    assert(s.split('The focused UI element is ')[1]?.includes(`ID: ${id}`),`Text input could not acquire native focus: ${id}`);
    await key('super+a'); lastAction=`type ${id}`;
    if (/[^\x00-\x7F]/.test(value)) await app.paste(value,{format:'text'});
    else await app.typeText(value);
    await state();
    await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    return state();
  }
  async function key(value) { await state(); lastAction=`key ${value}`; await app.pressKey(value); return state(); }
  async function controls() {
    const s = await key('super+shift+0');
    if (!s.includes('Window: "Claudio UI Regression"')) throw new Error('Fixed fixture control window did not appear');
    return s;
  }
  async function control(label) {
    await controls();
    return clickMatching(line => new RegExp(`\\bbutton ${label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}$`).test(line));
  }
  const readback = async () => JSON.parse(await fs.readFile(path.join(root,'readback.json'),'utf8'));
  async function waitUntil(predicate, description) {
    const deadline=Date.now()+8000;
    do {
      const current=await state();
      if (await predicate(current)) return current;
    } while (Date.now()<deadline);
    throw new Error(`Native result timed out: ${description}`);
  }
  const manifest = async () => JSON.parse(await fs.readFile(path.join(root,'packs/regression-pack/manifest.json'),'utf8'));
  function assert(condition, description) { if (!condition) throw new Error(description); }
  async function observe(label) {
    const observation = await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    const file = label.replace(/[^a-zA-Z0-9._-]/g,'-');
    await fs.writeFile(path.join(outputDirectory,file+'.ax.txt'),observation.state);
    if (!observation.screenshot) throw new Error('Screenshot interface returned no image');
    const extension=observation.screenshot[0]===255&&observation.screenshot[1]===216?'.jpg':'.png';
    await fs.writeFile(path.join(outputDirectory,file+extension),observation.screenshot);
    return {ax:observation.state,readback:await readback(),screenshot:file+extension,axFile:file+'.ax.txt'};
  }
  async function test(label, action) {
    let result;
    try { const assertions = await action(); result = {label,status:'passed',assertions,...await observe(label)}; }
    catch (error) {
      result = {label,status:'failed',reason:`${lastAction}: ${String(error.message || error)}`,stack:error.stack};
      try { Object.assign(result,await observe(label+'-failure')); } catch (captureError) { result.captureFailure=String(captureError); }
    }
    result.driverSHA256=report.driverSHA256;
    result.active=active;
    report.results.push(result);
    await fs.writeFile(path.join(outputDirectory,'results.json'),JSON.stringify(report,null,2));
    return {label:result.label,status:result.status,reason:result.reason};
  }
  async function pick(id, label) {
    const current=await state();
    const control=current.split('\n').find(line=>line.includes(`ID: ${id}`));
    const selectedLabel=new RegExp(`Value: ${label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}(?=[,，]|$)`);
    if (control&&selectedLabel.test(control)) return current;
    await clickID(id);
    const menuState=await state();
    const matches=menuState.split('\n').filter(line=>/menu item|ID: menuAction:/.test(line)&&line.includes(label));
    const exactLabel=new RegExp(`(?:^|\\s)${label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}(?=,|，|$)`);
    const exact=matches.filter(line=>exactLabel.test(line));
    const target=exact.length===1?exact:matches;
    assert(target.length===1,`Native menu label is not unique: ${label}`);
    const chosen=target[0];
    return clickMatching(line=>line.trim()===chosen.trim());
  }
  const destinations=['events-and-sounds','sounds','integrations','notifications','general','shortcuts','usage','about'];
  const sidebarLabels={
    'events-and-sounds':['工作区','Workspace'],sounds:['声音','Sounds'],
    integrations:['集成','Integrations'],notifications:['通知','Notifications'],general:['通用','General'],
    shortcuts:['快捷键','Shortcuts'],usage:['活动与诊断','Activity & Diagnostics'],about:['关于','About']
  };
  function sidebarRow(snapshot,destination) {
    const lines=snapshot.split('\n'); const table=lines.findIndex(line=>/\btable\b/.test(line)&&line.includes('ID: settings.sidebar'));
    assert(table>=0,'The Settings sidebar must be a native source-list table');
    const indent=line=>line.match(/^\s*/)[0].length;
    let row; const matches=[];
    for (let i=table+1;i<lines.length&&indent(lines[i])>indent(lines[table]);i++) {
      if (/\brow\b/.test(lines[i])&&/^\s*\d+ row/.test(lines[i])) row=lines[i];
      if (row&&sidebarLabels[destination].some(label=>lines[i].trim().endsWith(`text ${label}`))) matches.push(row);
    }
    assert(matches.length===1,`Native source-list row is not unique: ${destination}`);
    return matches[0];
  }

  function assertSettingsLayout(read, index, destination) {
    const evidence=read.settingsLayout;
    assert(evidence?.sampleColorSpace==='sRGB','Mounted Settings color evidence is unavailable');
    const {frames,colors}=evidence;
    const dark=index%4===3||index%4===0;
    const matches=(actual,expected)=>Array.isArray(actual)&&actual.length===3&&actual.every((value,i)=>Math.abs(value-expected[i])<=3);
    const background=evidence.semanticColors?.window;
    assert(Array.isArray(background)&&background.length===3,'The system window semantic color was not resolved');
    assert(colors.background?.length===3&&colors.background.every(sample=>matches(sample,background)),`Settings background differs at ${destination}: ${JSON.stringify(colors.background)}`);
    const sidebar=frames['settings.sidebar'];
    assert(sidebar&&Math.abs(sidebar.width-(index%2===0?210:252))<1,'Sidebar width does not match the window');
    const reading=frames[`settings.reading.${destination}`], content=frames['settings.content'];
    const padding=index%2===0?26:32;
    assert(reading&&content&&reading.width<=780-padding*2+1&&reading.x>=content.x+padding-1&&reading.x+reading.width<=content.x+content.width-padding+1,`Single reading column overflows: ${JSON.stringify(reading)}`);
    const rows=destinations.map(id=>frames[`settings.sidebar.item.${id}`]);
    assert(rows.every(Boolean),'One or more mounted sidebar rows are unavailable');
    const sidebarGaps=rows.slice(1).map((row,i)=>row.y-rows[i].y-rows[i].height);
    assert(sidebarGaps.every((gap,i)=>[3,5].includes(i)?gap>=16:Math.abs(gap)<1),`Sidebar group spacing differs: ${sidebarGaps}`);
    const result={destination,background:colors.background,sidebarGaps,reading};
    if (destination==='events-and-sounds'||destination==='sounds') {
      const prefix=destination==='sounds'?'sound-packs':'workspace';
      const events=Object.entries(frames).filter(([id])=>id.startsWith(`${prefix}.event-row.`)).map(([,frame])=>frame).sort((a,b)=>a.y-b.y);
      const group=frames[`${prefix}.events.group`];
      assert(events.length===5&&group,`Five grouped event rows were not mounted: ${prefix}`);
      assert(events.every(row=>row.x>=group.x-1&&row.x+row.width<=group.x+group.width+1),'Event rows overflow their functional group');
      const eventGaps=events.slice(1).map((row,i)=>row.y-events[i].y-events[i].height);
      assert(eventGaps.every(gap=>Math.abs(gap)<=2),`Event row dividers differ: ${eventGaps}`);
      assert(matches(colors.card,evidence.semanticColors?.group),`Settings group surface differs: ${colors.card}`);
      Object.assign(result,{eventGaps,card:colors.card,group});
    }
    return result;
  }
  async function matrix(index,{pages=destinations}={}) {
    const suffix=pages.length===destinations.length?'':'-'+pages.join('-');
    return test(`matrix-${index}${suffix}`,async()=> {
      assert(index>=1 && index<=8,'Unknown fixed matrix');
      assert(pages.length>0&&new Set(pages).size===pages.length&&pages.every(page=>destinations.includes(page)),'Unknown or duplicate matrix destination');
      await control(`Matrix ${index}`);
      const geometry=(await readback()).windowGeometry;
      assert(Math.abs(geometry.frameWidth-(index%2===0?960:1240))<1 && Math.abs(geometry.frameHeight-(index%2===0?640:820))<1 && geometry.width>0 && geometry.height>0 && geometry.height<=geometry.frameHeight,`Requested window size was constrained: ${JSON.stringify(geometry)}`);
      assert(geometry.appearance===(index%4===3||index%4===0?'NSAppearanceNameDarkAqua':'NSAppearanceNameAqua'),'Requested appearance was not applied');
      const layouts=[];
      for (const destination of pages) {
        const s = await clickID(`settings.sidebar.${destination}`);
        assert(s.includes(`ID: settings.title.${destination}`),`Destination title did not appear: ${destination}`);
        assert(sidebarRow(s,destination).includes('(selected)'),`Sidebar selection did not match ${destination}`);
        assert((await readback()).destination===destination,`Typed route did not match ${destination}`);
        await control('Capture state');
        await key('super+shift+l');
        layouts.push(assertSettingsLayout(await readback(),index,destination));
        await observe(`matrix-${index}-${destination}-top`);
        const scroll = s.split('\n').find(line => /scroll area/.test(line) && !line.includes('sidebar'));
        if (scroll) {
          // Derive the current scroll index again; never reuse the index from s after capture.
          const current = await state();
          const scrollNow = current.split('\n').find(line => /scroll area/.test(line) && !line.includes('sidebar'));
          if (!scrollNow) throw new Error('Scrollable content disappeared');
          if (scrollNow.includes('Scroll Down')) await app.scroll(number(scrollNow),'down',20);
          else assert(!current.includes('scroll bar'),'Required AX scroll action is unavailable');
          await state();
          await observe(`matrix-${index}-${destination}-bottom`);
        }
      }
      return {navigation:pages,layouts,language:index<=4?'zh-Hans':'en',appearance:index%4===3 || index%4===0?'dark':'light',requestedSize:index%2===0?'960x640':'1240x820',actualGeometry:geometry};
    });
  }
  function imageWidth(bytes) {
    if (bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) return bytes.readUInt32BE(16);
    if (bytes[0]===255 && bytes[1]===216) {
      let offset=2;
      while (offset<bytes.length) {
        while (bytes[offset]===255) offset++;
        const marker=bytes[offset++]; const length=bytes.readUInt16BE(offset);
        if ([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)) return bytes.readUInt16BE(offset+5);
        offset+=length;
      }
    }
    throw new Error('Screenshot dimensions cannot be determined');
  }
  async function focusSettingsWindow({requireKey=false}={}) {
    const current=await state(); assert(/Window: "claudi0 · (设置|Settings)"/.test(current),'Settings window is not the current surface');
    const window=find(current,line=>/^\s*\d+ system dialog/.test(line)&&line.includes('Secondary Actions: Raise'));
    lastAction='native Settings window Raise'; await app.performSecondaryAction(window,'Raise');
    await key('super+shift+l');
    if (requireKey) await waitUntil(async()=>/^claudi0 · (设置|Settings)$/.test((await readback()).keyWindow),'Settings must acquire key focus');
  }
  async function flow(index, {composerPoint} = {}) {
    return test(`flow-${index}-ai`,async()=> {
      await control(`Matrix ${index}`);
      await focusSettingsWindow();
      const initialGenerationRequests=(await readback()).generationRequests;
      let s = await pick('workspace.scope-selector','workspace');
      const scopeBefore = await fs.readFile(path.join(root,'config.json'),'utf8');
      await clickID('workspace.event.stop.edit'); s=await state();
      assert(s.includes('ID: settings.sounds.return-to-scope'),'Typed return control did not appear');
      assert((await readback()).aiPhase==='editing' && (await readback()).generationRequests===initialGenerationRequests,'Directional edit started a provider generation');
      await clickID('settings.sounds.return-to-scope');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===scopeBefore,'Navigation rewrote workspace configuration');
      await clickID('settings.sidebar.sounds');
      await pick('sound-packs.pack-list','regression-pack');
      await observe(`flow-${index}-composer-entry`);
      await clickID('sound-packs.event.stop.edit');
      await pointerID('settings.sounds.ai-cue.event.stop',{text:(await readback()).language==='zh-Hans'?'描述生成':'Describe & Generate',scrollDownIfMissing:true});
      assert((await state()).includes('settings.sounds.ai-cue.composer.stop'),'Composer did not target the selected stop event');
      const description='A short soft chime for a finished response.';
      await textID('event-settings.ai-cue.description',description);
      const requestsBefore=(await readback()).generationRequests;
      await pointerID('event-settings.ai-cue.generate',{scrollDownIfMissing:true});
      s=await state(); assert(s.includes('event-settings.ai-cue.cancel-generation'),'Generating controls did not appear');
      const locked=s.split('\n').find(line=>/^\s*\d+/.test(line)&&line.includes('ID: event-settings.ai-cue.description'));
      assert(locked && !locked.includes('(settable)') && /locked|锁定/i.test(locked) && (await readback()).description===description,'Description did not lock while generating');
      await clickID('event-settings.ai-cue.cancel-generation');
      await waitUntil(async()=>(await readback()).aiPhase==='editing','Cancellation must restore editing');
      assert((await readback()).aiPhase==='editing','Cancellation did not restore editing');
      await pointerID('event-settings.ai-cue.generate',{scrollDownIfMissing:true}); await key('super+shift+g');
      await waitUntil(async()=>(await readback()).candidateCount===3,'Completed generation must expose three route-owned candidates');
      s=await state(); assert((await readback()).candidateCount===3,'Route-owned complete candidate count was not three');
      const generationCount=(await readback()).generationRequests;
      await textID('event-settings.ai-cue.name',`Fixture adopted cue ${index}`);
      assert((await readback()).generationRequests===generationCount,'Rename triggered a new generation');
      const oldMapping=(await manifest()).events.stop;
      await pointerID('event-settings.ai-cue.candidate.clear.use',{text:index<=4?'用于此事件':'Use for this event',anchor:index<=4?'A · 清晰':'A · Clear',anchorPlacement:'same-row',scrollDownIfMissing:true});
      await waitUntil(current=>current.includes('event-settings.ai-cue.applied'),'Adoption must show its actual result');
      s=await state(); assert(s.includes('event-settings.ai-cue.applied'),'Adoption did not show its result');
      assert((await manifest()).events.stop!==oldMapping || (await manifest()).audio_names?.[(await manifest()).events.stop]===`Fixture adopted cue ${index}`,'Successful adoption did not update the real isolated manifest');
      await clickID('settings.sidebar.general');
      assert((await readback()).candidateCount===0,'Leaving Sounds retained unadopted candidates');
      return {workspaceReturn:true,cancel:true,completeCandidates:3,renameWithoutGeneration:true,adoptedMapping:(await manifest()).events.stop,requestsBefore};
    });
  }
  async function copyFlow() {
    return test('pack-copy-cancel-confirm-and-factory-restore',async()=> {
      await control('Matrix 5'); await focusSettingsWindow();
      await clickID('settings.sidebar.sounds'); await pick('sound-packs.pack-list','regression-pack');
      const configBefore=await fs.readFile(path.join(root,'config.json'),'utf8');
      const originalBefore=await fs.readFile(path.join(root,'packs/regression-pack/manifest.json'),'utf8');
      const before=(await fs.readdir(path.join(root,'packs'))).sort();
      const protectedState=await state();
      assert(protectedState.split('\n').some(line=>line.includes('sound-packs.delete-selected-pack')&&line.includes('disabled')),'Used package deletion is not protected');
      await clickID('sound-packs.copy-selected-pack');
      let s=await state(); assert(/author|attribution|license/i.test(s),'Copy confirmation did not explain attribution');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===configBefore,'Opening copy confirmation rewrote a group');
      await key('Escape');
      assert(JSON.stringify((await fs.readdir(path.join(root,'packs'))).sort())===JSON.stringify(before),'Cancelling copy created an installed package');
      await clickID('sound-packs.copy-selected-pack'); await clickID('sound-packs.confirm-copy');
      await control('Capture state'); await key('super+shift+l');
      const created=(await fs.readdir(path.join(root,'packs'))).filter(id=>!before.includes(id));
      assert(created.length===1,'Confirmed copy did not create exactly one package');
      assert((await readback()).inspectedPack===created[0],'Confirmed copy did not inspect its result');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===configBefore,'Plain copy changed the selected group package');
      const copy=JSON.parse(await fs.readFile(path.join(root,'packs',created[0],'manifest.json'),'utf8'));
      assert(!copy.license&&!copy.author,'Copy retained whole-package license or author claims');
      assert(await fs.readFile(path.join(root,'packs/regression-pack/manifest.json'),'utf8')===originalBefore,'Copy changed the original manifest');
      const copyBefore=await fs.readFile(path.join(root,'packs',created[0],'manifest.json'),'utf8');
      await clickID('sound-packs.restore-library'); await clickID('sound-packs.confirm-factory-restore');
      await control('Capture state'); await key('super+shift+l');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===configBefore,'Factory restore changed group configuration');
      assert(await fs.readFile(path.join(root,'packs',created[0],'manifest.json'),'utf8')===copyBefore,'Factory restore changed a user copy');
      assert(await fs.readFile(path.join(root,'packs/regression-pack/manifest.json'),'utf8')===originalBefore,'Factory restore changed a user package');
      return {cancelPreserved:true,plainCopy:created[0],plainCopyPreservedGroups:true,attributionRemoved:true,factoryRestorePreservedUsers:true,usedDeletionProtected:true};
    });
  }
  async function targetCopyFlow() {
    return test('workspace-copy-and-apply-stable-return',async()=> {
      await control('Matrix 5'); await focusSettingsWindow(); await pick('workspace.scope-selector','workspace');
      await pick('event-settings.sound-pack-picker','builtin-pack');
      const before=JSON.parse(await fs.readFile(path.join(root,'config.json'),'utf8'));
      const rules=Object.values(before.workspace_rules??{}); assert(rules.length===1,'Fixture workspace is unavailable');
      const targetID=rules[0].id; const targetDirectory=JSON.stringify(rules[0].directory);
      const packsBefore=await fs.readdir(path.join(root,'packs'));
      await clickID('workspace.event.stop.edit');
      assert((await state()).includes('settings.sounds.return-to-scope'),'Directional return is unavailable');
      await clickID('sound-packs.copy-and-apply');
      assert((await state()).includes('workspace'),'Copy-and-apply confirmation lost its workspace target');
      await clickID('sound-packs.confirm-copy'); await control('Capture state'); await key('super+shift+l');
      const created=(await fs.readdir(path.join(root,'packs'))).filter(id=>!packsBefore.includes(id));
      assert(created.length===1,'Copy-and-apply did not retain exactly one copy');
      const after=JSON.parse(await fs.readFile(path.join(root,'config.json'),'utf8'));
      const rule=Object.values(after.workspace_rules??{}).find(rule=>rule.id===targetID);
      assert(rule&&rule.profile.selectedPack===created[0]&&JSON.stringify(rule.directory)===targetDirectory,'Copy-and-apply missed its stable workspace identity');
      assert(after.selected_pack===before.selected_pack,'Workspace copy-and-apply changed Default Group');
      const appliedBytes=await fs.readFile(path.join(root,'config.json'),'utf8');
      await clickID('settings.sounds.return-to-scope');
      assert((await state()).includes('workspace')&&(await readback()).destination==='events-and-sounds','Directional return lost the originating workspace');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===appliedBytes,'Directional return rewrote the applied configuration');
      return {copy:created[0],targetID,directoryPreserved:true,defaultGroupPreserved:true,returnPreserved:true};
    });
  }
  async function draftFlow() {
    return test('draft-name-cancel-save-system-publish-and-cleanup',async()=> {
      await control('Matrix 5'); await focusSettingsWindow(); await clickID('settings.sidebar.sounds');
      const configBefore=await fs.readFile(path.join(root,'config.json'),'utf8');
      const before=await fs.readdir(path.join(root,'packs'));
      await clickID('settings.sounds.ai-cue.new-pack');
      assert((await state()).includes('settings.sounds.ai-cue.draft'),'Draft context did not appear');
      assert(JSON.stringify(await fs.readdir(path.join(root,'packs')))===JSON.stringify(before),'Empty draft appeared in installed library');
      await clickID('settings.sounds.ai-cue.rename-draft');
      await textID('settings.sounds.ai-cue.draft-name','Draft fixture cancelled'); await key('Escape');
      assert(!(await state()).includes('Draft fixture cancelled'),'Cancelling rename changed the draft name');
      await clickID('settings.sounds.ai-cue.rename-draft'); await textID('settings.sounds.ai-cue.draft-name','');
      assert((await state()).split('\n').some(line=>line.includes('settings.sounds.ai-cue.save-draft-name')&&line.includes('disabled')),'Invalid draft name can be saved');
      await textID('settings.sounds.ai-cue.draft-name','Native fixture draft'); await clickID('settings.sounds.ai-cue.save-draft-name');
      assert((await state()).includes('Native fixture draft'),'Saved draft name did not appear');
      await clickID('sound-packs.event.task_start.mapping');
      const menu=await state(); const systemLine=menu.split('\n').find(line=>line.includes('Basso')&&/menu item|menuAction:/.test(line)&&!line.includes('disabled'));
      assert(systemLine,'Available local system sound was not offered');
      await app.click(number(systemLine)); await state();
      await control('Capture state'); await key('super+shift+l');
      const created=(await fs.readdir(path.join(root,'packs'))).filter(id=>!before.includes(id));
      assert(created.length===1,'First successful system binding did not publish exactly one draft');
      const published=JSON.parse(await fs.readFile(path.join(root,'packs',created[0],'manifest.json'),'utf8'));
      assert(published.name==='Native fixture draft','Published manifest lost the confirmed draft name');
      assert(JSON.stringify(published).includes('Basso'),'Published manifest lost its first system sound');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===configBefore,'Draft publication changed group selection');
      const publishedState=await state();
      if (publishedState.includes('ID: sound-packs.detail.back')) await clickID('sound-packs.detail.back');
      await clickID('settings.sounds.ai-cue.new-pack'); await clickID('settings.sidebar.general');
      assert((await fs.readdir(path.join(root,'packs'))).filter(id=>!before.includes(id)).length===1,'Leaving Sounds published a second empty draft');
      return {cancelRename:true,invalidNameProtected:true,confirmedName:published.name,firstSystemBindingPublished:created[0],groupsPreserved:true,unpublishedCleanup:true};
    });
  }
  async function keyboardNavigation() {
    return test('keyboard-native-scope-and-pack', async()=> {
      await control('Matrix 5');
      await focusSettingsWindow({requireKey:true});
      await clickID('settings.sidebar.sounds');
      await pick('settings.sounds.management-scope','Default Group');
      await clickID('settings.sidebar.about');
      await clickID('settings.sidebar.sounds');
      await focusSettingsWindow({requireKey:true});
      await waitUntil(current=>current.split('The focused UI element is ')[1]?.includes('ID: settings.sidebar'),'Native sidebar selection must retain source-list keyboard focus');
      let s=await key('Tab');
      assert(s.split('The focused UI element is ')[1]?.includes('ID: settings.sounds.management-scope'),'The first Sounds Tab stop is not management scope');
      const before=await fs.readFile(path.join(root,'config.json'),'utf8');
      await focusSettingsWindow({requireKey:true});
      assert((await state()).split('The focused UI element is ')[1]?.includes('ID: settings.sounds.management-scope'),'Explicit window Raise changed the focused scope control');
      await key('space'); await waitUntil(current=>current.includes('ID: menuAction:'),'Space must open the native scope menu');
      await key('Down'); await waitUntil(current=>current.split('\n').some(line=>line.includes('(selected) workspace, ID: menuAction:')),'Down must highlight Workspace');
      await key('Return');
      s=await waitUntil(current=>current.includes('Value: workspace, ID: settings.sounds.management-scope'),'Return must select Workspace');
      assert(s.includes('Value: workspace, ID: settings.sounds.management-scope'),'Arrow/Return did not select Workspace');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===before,'Management scope selection wrote group configuration');
      // Mouse sidebar navigation retains the native source list; the toolbar heading is not a Tab stop.
      await clickID('settings.sidebar.about'); await clickID('settings.sidebar.sounds');
      await focusSettingsWindow({requireKey:true});
      await waitUntil(current=>current.split('The focused UI element is ')[1]?.includes('ID: settings.sidebar'),'Native source-list focus must be retained before pack traversal');
      await key('Tab'); s=await key('Tab');
      assert(s.split('The focused UI element is ')[1]?.includes('ID: sound-packs.pack-list'),'Scope and pack picker do not have one stop each');
      const inspected=(await readback()).inspectedPack;
      await focusSettingsWindow({requireKey:true});
      assert((await state()).split('The focused UI element is ')[1]?.includes('ID: sound-packs.pack-list'),'Explicit window Raise changed the focused pack control');
      await key('space'); await waitUntil(current=>current.includes('ID: menuAction:'),'Space must open the native pack menu');
      await key('Up'); await key('Return');
      await waitUntil(async()=>(await readback()).inspectedPack!==inspected,'Arrow/Return must inspect another pack');
      assert((await readback()).inspectedPack!==inspected,'Arrow navigation did not inspect another pack');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===before,'Pack inspection applied it to the group');
      return {nativeTab:true,scopeArrowReturn:true,packArrowReturn:true,configurationPreserved:true};
    });
  }
  async function reminderFlow(index) {
    return test(`flow-${index}-reminders`,async()=> {
      await control('Return to settings');
      const settingsState=await state(); await app.click(find(settingsState,line=>/^\s*\d+ close button$/.test(line))); await state();
      await key('super+shift+1');
      await key('super+shift+p');
      await clickID('panel.recent-notices');
      let s=await state(); assert(s.includes('event-notice.reader'),'Panel reader did not expand');
      const recent=(await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.recent.'));
      assert(recent,'The frozen reminder did not expose an action identity');
      await pointerID(recent.match(/ID: (\S+)/)[1]);
      s=await state(); assert(s.includes('fixture-session'),'Effective session ID did not appear');
      await clickID('event-notice.copy-session');
      s=await state(); assert(s.includes('event-notice.copy-result') && /Copied|已复制/i.test(s) && (await readback()).copiedFixtureSession,'Copy result did not appear');
      const beforeRemove=await readback();
      await pointerID('event-notice.remove');
      const afterRemove=await readback();
      assert(afterRemove.reminders===0,'Explicit removal did not remove the fixture reminder');
      for (const fact of ['activity','diagnosticLog','receiptHistories']) assert(JSON.stringify(afterRemove[fact])===JSON.stringify(beforeRemove[fact]),`Reminder removal changed ${fact}`);
      await key('Escape'); await key('Escape');
      // Keep a fixture surface available after the banner's final timer closes it.
      await controls();
      for (let tick=0; tick<4; tick++) await key('super+shift+r');
      await key('super+shift+f'); await key('super+shift+2');
      await key('super+shift+r');
      await key('super+shift+b');
      // Banner is the sole window with this version-bound control.
      await pointerID((await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.open-source.'))?.match(/ID: (\S+)/)?.[1]??'missing-banner-action');
      s=await state(); assert(s.includes('event-notice.open-feedback'),'Open failure did not stay inline');
      const remaining=(await readback()).remaining;
      await key('super+shift+s');
      await pointerID((await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.open-source.'))?.match(/ID: (\S+)/)?.[1]??'missing-banner-action',{returnToControls:true});
      assert((await readback()).reminders===1 && (await readback()).navigation==='applicationFallback','Substitute open success removed the reminder or failed');
      assert((await readback()).remaining<=remaining,'Retry reset the remaining budget');
      await key('super+shift+r');
      await control('Show settings');
      const beforeClose=(await readback()).handbacks;
      s=await state(); await app.click(find(s,line=>/^\s*\d+ close button$/.test(line))); await state();
      assert((await readback()).handbacks===beforeClose+1,'Window close did not consume one handback');
      return {copy:true,remove:true,removalPreserved:{activity:afterRemove.activity,diagnosticLog:afterRemove.diagnosticLog,receiptHistories:afterRemove.receiptHistories},inlineRetry:true,successKeepsReminder:true,closeHandback:true};
    });
  }
  async function receiptHistoryFlow(host, label) {
    assert(['claude-code','codex','workbuddy'].includes(host),'Unknown fixture host');
    return test(`receipt-history-${host}`,async()=> {
      await control('Matrix 5'); await focusSettingsWindow();
      await clickID('settings.sidebar.integrations');
      await clickMatching(line=>line.includes(`button Description: ${label},`)||line.includes(`button (selected) Description: ${label},`));
      const before=await readback(); const facts=before.receiptHistories[host];
      assert(facts.diskCount===4&&facts.presentationCount===4,'Seeded history is incomplete');
      // SwiftUI may inherit a containing group's AX identifier; role + localized name still
      // identifies exactly one current control, checked again before every action.
      await clickMatching(line=>/button Description: View…(?:,|$)/.test(line));
      let s=await state();
      assert(s.includes(`integrations.destination.history.${host}`)&&s.includes(label),'History sheet lost its selected host');
      assert((s.match(/Current installation/g)||[]).length===2&&(s.match(/Previous installation/g)||[]).length===2,'History must show both retained installation generations');
      assert(s.includes('Playback failed')&&s.includes('Muted'),'History omitted actual playback results');
      await observe(`receipt-history-${host}-sheet`);
      await key('Escape');
      assert(!(await state()).startsWith('Window: "",'),'Escape did not dismiss the history sheet');
      await clickID('integrations.destination.open-capabilities'); s=await state();
      for(const event of ['User initiated','Response ended','Execution interrupted','Waiting for input','Subtask ended']) assert(s.includes(event),`Capability detail omits ${event}`);
      assert(/Interface .*supported/.test(s)&&s.includes('Implemented')&&s.includes('Unverified'),'Support, implementation and current activation are not independently visible');
      const after=await readback();
      assert(JSON.stringify(after.receiptHistories)===JSON.stringify(before.receiptHistories),'Viewing history changed receipt facts');
      return {host,entries:4,current:2,previous:2,capabilityEvents:5,currentActivation:facts.connectionStatus,readOnly:true};
    });
  }
  async function clearIsolationFlow(kind) {
    assert(['receipts','log','activity'].includes(kind),'Unknown clear case');
    return test(`independent-clear-${kind}`,async()=> {
      await control('Matrix 5'); await focusSettingsWindow();
      const before=await readback();
      assert(before.reminders>0,'A retained reminder is required to check isolation');
      if(kind==='receipts') {
        await clickID('settings.sidebar.integrations');
        await clickMatching(line=>line.includes('button Description: Claude Code,')||line.includes('button (selected) Description: Claude Code,'));
        await clickMatching(line=>/button Description: Clear Claude Code receipt history,/.test(line));
      } else {
        await clickID('settings.sidebar.usage');
        await clickID(kind==='log'?'settings.activity.clear-log':'settings.activity.clear');
      }
      const confirmation=await state();
      assert(confirmation.includes('sheet Description: alert')&&confirmation.includes('Cancel'),'Clear must expose an explicit confirmation');
      await key('Escape');
      const cancelled=await readback();
      for(const fact of ['activity','diagnosticLog','receiptHistories','reminders']) assert(JSON.stringify(cancelled[fact])===JSON.stringify(before[fact]),`Cancel changed ${fact}`);
      if(kind==='receipts') await clickMatching(line=>/button Description: Clear Claude Code receipt history,/.test(line));
      else await clickID(kind==='log'?'settings.activity.clear-log':'settings.activity.clear');
      await clickID('action-button-1');
      await waitUntil(async()=> {const current=await readback();return kind==='receipts'?current.receiptHistories['claude-code'].diskCount===0:kind==='log'?current.diagnosticLog.bytes===0:current.activity.count===0;},'Cleared owner must publish its actual disk result');
      const after=await readback();
      assert(after.reminders===before.reminders,'Clear removed a retained reminder');
      if(kind==='receipts') {
        const a=after.receiptHistories['claude-code'],b=before.receiptHistories['claude-code'];
        assert(a.presentationCount===0&&a.currentReceiptEvidenceCount===b.currentReceiptEvidenceCount&&a.installationID===b.installationID&&a.connectionStatus===b.connectionStatus,'History clear changed current installation or activation evidence');
        for(const host of ['codex','workbuddy']) assert(JSON.stringify(after.receiptHistories[host])===JSON.stringify(before.receiptHistories[host]),`History clear affected ${host}`);
      } else assert(JSON.stringify(after.receiptHistories)===JSON.stringify(before.receiptHistories),'Local clear changed receipt histories');
      if(kind!=='activity') assert(JSON.stringify(after.activity)===JSON.stringify(before.activity),'Clear changed activity');
      if(kind!=='log') assert(JSON.stringify(after.diagnosticLog)===JSON.stringify(before.diagnosticLog),'Clear changed log');
      return {kind,cancelPreserved:true,before,after};
    });
  }
  async function generationExceptions({outcomes=['partial','failure'],includeTimeout=true}={}) {
    const results=[];
    assert(outcomes.every(outcome=>['partial','failure'].includes(outcome)),'Unknown fixed generation case');
    await control('Matrix 1');
    for (const outcome of outcomes) {
      results.push(await test(`exceptions-ai-${outcome}`,async()=> {
        await control(`AI ${outcome}`); await control('Return to settings');
        await clickID('settings.sidebar.sounds'); await pick('sound-packs.pack-list','regression-pack');
        await clickID('sound-packs.open-service');
        await pick('event-settings.ai-cue.provider-profile', 'SenseAudio');
        await clickID('sound-packs.detail.back');
        await clickID('sound-packs.event.stop.edit');
        await pointerID('settings.sounds.ai-cue.event.stop',{text:(await readback()).language==='zh-Hans'?'描述生成':'Describe & Generate',scrollDownIfMissing:true});
        let s=await textID('event-settings.ai-cue.description','一个简短柔和的铃声提示音。');
        assert((await readback()).description==='一个简短柔和的铃声提示音。','The native description input did not retain its text');
        const before=await manifest(); const requests=(await readback()).generationRequests;
        await pointerID('event-settings.ai-cue.generate',{scrollDownIfMissing:true}); await key('super+shift+g');
        s=await state(); const back=await readback();
        assert(back.generationRequests===requests+1,'Generation did not issue exactly one substitute request');
        if (outcome==='partial') assert(back.candidateCount===2 && /partial|部分|2/i.test(s),'Partial route result did not show its actual candidates');
        else assert(back.candidateCount===0 && s.includes('event-settings.ai-cue.error'),'Provider failure did not show a recovery reason');
        assert(JSON.stringify(await manifest())===JSON.stringify(before),'Unadopted generation changed the existing mapping');
        await clickID('settings.sidebar.general');
        assert((await readback()).candidateCount===0,'Leaving the page retained candidates');
        return {outcome,actualCandidateCount:back.candidateCount,oldMappingPreserved:true};
      }));
    }
    if (!includeTimeout) return results;
    results.push(await test('exceptions-source-timeout',async()=> {
      await control('Source timeout'); await control('Verified-source reminder');
      await control('Return to settings'); await clickID('settings.sidebar.usage');
      const reader=await state();
      if(reader.split('\n').some(line=>line.includes('disclosure triangle')&&line.includes('settings.activity.pending-records')&&line.includes('Value: off'))) await clickID('settings.activity.pending-records');
      const recent=(await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.recent.'));
      assert(recent,'Settings reader did not expose a current reminder');
      await clickID(recent.match(/ID: (\S+)/)[1]);
      await clickID('event-notice.reader.open-source');
      assert((await readback()).navigation==='started','Navigation did not enter its in-flight state');
      await key('super+shift+r'); await key('super+shift+r'); await key('super+shift+r');
      const s=await state(); const back=await readback();
      assert(back.navigation==='timedOut' && /超时|timed out|timeout/i.test(s),'Three-second navigation timeout did not become visible');
      assert(back.reminders>0,'Navigation timeout removed the reminder');
      return {threeSecondTimeout:true,reminderRetained:true};
    }));
    return results;
  }
  async function exceptions({includeReminders=true,scenarios=['zero-volume','invalid-workspace','stale-snapshot','duplicate-mapping','damaged-pack','empty-library']}={}) {
    const output=[];
    assert(scenarios.every(scenario=>['zero-volume','invalid-workspace','stale-snapshot','duplicate-mapping','damaged-pack','empty-library'].includes(scenario)),'Unknown fixed library case');
    if (includeReminders) output.push(await test('exceptions-reminder-update-expiry',async()=> {
      await control('Verified-source reminder');
      await control('Return to settings'); await clickID('settings.sidebar.usage');
      const initial=await state();
      if(initial.split('\n').some(line=>line.includes('disclosure triangle')&&line.includes('settings.activity.pending-records')&&line.includes('Value: off'))) await clickID('settings.activity.pending-records');
      const first=(await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.recent.'));
      assert(first,'Settings reader did not expose its frozen reminder');
      await clickID(first.match(/ID: (\S+)/)[1]);
      const frozen=await state();
      assert(frozen.includes('fixture-session'),'Frozen session identity did not appear');
      await key('super+shift+u'); let s=await state();
      assert(s.includes('event-notice.refresh') && !s.includes('Fixture updated'),'Updated reminder silently replaced the frozen content');
      await clickID('event-notice.refresh');
      const recent=(await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.recent.'));
      assert(recent,'Refreshed reminder did not expose a version-bound identity');
      await clickID(recent.match(/ID: (\S+)/)[1]);
      assert((await state()).includes('Fixture updated'),'Explicit refresh did not display the new reminder');
      await key('super+shift+e'); s=await state();
      assert(!s.includes('fixture-session') && !s.includes('Fixture updated'),'TTL retained private source content');
      assert((await readback()).reminders===0,'Expired reminder remained live');
      return {refresh:true,expiredPrivacyCleared:true};
    }));
    for (const scenario of scenarios) {
      output.push(await test(`exceptions-${scenario}`,async()=> {
        await control('Show settings');
        if (scenario!=='zero-volume') await control('Scenario normal');
        await key('super+shift+l');
        if (scenario!=='invalid-workspace') await pick('workspace.scope-selector','默认组');
        if (scenario==='invalid-workspace') await pick('workspace.scope-selector','workspace');
        await control(`Scenario ${scenario}`); await key('super+shift+l');
        const s=await state(); const back=await readback();
        if (scenario==='zero-volume') assert(back.volume===0 && /音量|volume/.test(s) && s.split('\n').some(line=>line.includes('workspace.preview-available')&&line.includes('disabled')),'Zero-volume preview did not show an unavailable state');
        if (scenario==='invalid-workspace') assert(Object.keys(JSON.parse(await fs.readFile(path.join(root,'config.json'),'utf8')).workspace_rules??{}).length===0 && s.includes('workspace.scope.unavailable') && !s.includes('workspace.preview-available'),'Invalid workspace did not reject the isolated target');
        if (scenario==='stale-snapshot') assert(back.libraryFresh===false,'Snapshot did not become stale');
        if (scenario==='duplicate-mapping') assert((await manifest()).events.task_start===(await manifest()).events.notification,'Shared audio mapping was not preserved');
        if (scenario==='damaged-pack') assert(s.includes('声音包缺失或损坏，请在声音页修复') && s.split('\n').some(line=>line.includes('workspace.preview-available')&&line.includes('disabled')),'Damaged package did not show its pack-level repair reason');
        if (scenario==='empty-library') assert(/没有|No |缺少|missing|不可用|unavailable/i.test(s),'Empty library did not show an honest state');
        return {scenario,readback:back};
      }));
    }
    return output;
  }
  return {pointerID,matrix,flow,copyFlow,targetCopyFlow,draftFlow,keyboardNavigation,reminderFlow,receiptHistoryFlow,clearIsolationFlow,generationExceptions,exceptions,report,readback,state,waitUntil,clickID,control,key,observe,pick,test};
}
