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
    if (!candidates.length) candidates=records.filter(record=>normalizedText(record.text).endsWith(normalizedText(label)));
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
    if (control?.includes(`Value: ${label},`)) return current;
    await clickID(id);
    return clickMatching(line => /menu item|ID: menuAction:/.test(line) && line.includes(label));
  }
  const destinations=['events-and-sounds','sounds','integrations','notifications','general','shortcuts','usage','about'];
  function assertSettingsLayout(read, index, destination) {
    const evidence=read.settingsLayout;
    assert(evidence?.sampleColorSpace==='sRGB','Mounted Settings color evidence is unavailable');
    const {frames,colors}=evidence;
    const dark=index%4===3||index%4===0;
    const matches=(actual,expected)=>Array.isArray(actual)&&actual.length===3&&actual.every((value,i)=>Math.abs(value-expected[i])<=3);
    const background=dark?[26,24,21]:[250,248,244];
    assert(colors.background?.length===3&&colors.background.every(sample=>matches(sample,background)),`Settings background differs at ${destination}: ${JSON.stringify(colors.background)}`);
    const rows=destinations.map(id=>frames[`settings.sidebar.item.${id}`]);
    assert(rows.every(Boolean),'One or more mounted sidebar rows are unavailable');
    const sidebarGaps=rows.slice(1).map((row,i)=>row.y-rows[i].y-rows[i].height);
    assert(sidebarGaps.every((gap,i)=>Math.abs(gap-([3,5].includes(i)?24:3))<1),`Sidebar group spacing differs: ${sidebarGaps}`);
    const result={destination,background:colors.background,sidebarGaps};
    if (destination==='events-and-sounds'||destination==='sounds') {
      const sounds=destination==='sounds'; const prefix=sounds?'sound-packs':'workspace';
      const cards=Object.entries(frames).filter(([id])=>id.startsWith(`${prefix}.event-card.`)).map(([,frame])=>frame).sort((a,b)=>a.y-b.y);
      assert(cards.length===5,`Five independent event cards were not mounted: ${prefix}`);
      const eventGaps=cards.slice(1).map((card,i)=>card.y-cards[i].y-cards[i].height);
      assert(eventGaps.every(gap=>Math.abs(gap-12)<1),`Event card spacing differs: ${eventGaps}`);
      const selector=frames[sounds?'sound-packs.selector.card':'workspace.scope-selector.card'];
      const info=frames[sounds?'sound-packs.information.card':'workspace.configuration.card'];
      assert(selector?.height>=70&&info,'Selector or information card is unavailable');
      assert(Math.abs(cards[0].y-info.y-info.height-24)<1,'Information-to-event spacing differs');
      assert(matches(colors.card,dark?[28,26,23]:[255,255,255]),`Settings card surface differs: ${colors.card}`);
      assert(matches(colors.border,dark?[63,60,55]:[228,225,224]),`Settings card border is unavailable: ${colors.border}`);
      const auxiliary=frames[sounds?'settings.sounds.ai-cue.service':'workspace.auxiliary.card'];
      assert(auxiliary,'Mounted auxiliary card is unavailable');
      if (index%2===0) assert(auxiliary.y>cards[4].y+cards[4].height,'Minimum-window auxiliary card is not after the events');
      else assert(Math.abs(auxiliary.width-260)<1&&auxiliary.x>cards[4].x+cards[4].width,'Default-window auxiliary card is not a 260 pt right column');
      Object.assign(result,{eventGaps,selectorHeight:selector.height,card:colors.card,border:colors.border,auxiliary});
    }
    return result;
  }
  async function matrix(index) {
    return test(`matrix-${index}`,async()=> {
      assert(index>=1 && index<=8,'Unknown fixed matrix');
      await control(`Matrix ${index}`);
      const geometry=(await readback()).windowGeometry;
      assert(Math.abs(geometry.width-(index%2===0?960:1240))<1 && Math.abs(geometry.height-(index%2===0?640:820))<1,`Requested window size was constrained: ${JSON.stringify(geometry)}`);
      assert(geometry.appearance===(index%4===3||index%4===0?'NSAppearanceNameDarkAqua':'NSAppearanceNameAqua'),'Requested appearance was not applied');
      const layouts=[];
      for (const destination of destinations) {
        const s = await clickID(`settings.sidebar.${destination}`);
        assert(s.includes(`ID: ${destination==='integrations'?'integrations.destination.title':`settings.title.${destination}`}`),`Destination title did not appear: ${destination}`);
        assert(s.split('\n').some(line => line.includes('(selected)') && line.includes(`ID: settings.sidebar.${destination}`)),`Sidebar selection did not match ${destination}`);
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
          if (scrollNow.includes('Scroll Down')) await app.performSecondaryAction(number(scrollNow),'Scroll Down');
          else assert(!current.includes('scroll bar'),'Required AX scroll action is unavailable');
          await state();
          await observe(`matrix-${index}-${destination}-bottom`);
        }
      }
      return {navigation:destinations,layouts,language:index<=4?'zh-Hans':'en',appearance:index%4===3 || index%4===0?'dark':'light',requestedSize:index%2===0?'960x640':'1240x820',actualGeometry:geometry};
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
  async function focusSettingsWindow() {
    const current=await state(); assert(/Window: "claudi0 · (设置|Settings)"/.test(current),'Settings window is not the current surface');
    const capture=await app.getAXStateAndScreenshot({disableDiffing:true,emit:false});
    const bytes=Buffer.from(capture.screenshot); const width=imageWidth(bytes);
    const geometry=(await readback()).windowGeometry;
    lastAction='current screenshot settings title'; await app.click([geometry.frameWidth*geometry.backingScale/2,14*geometry.backingScale]); await state();
  }
  async function flow(index, {composerPoint} = {}) {
    return test(`flow-${index}-ai`,async()=> {
      await control(`Matrix ${index}`);
      await focusSettingsWindow();
      const initialGenerationRequests=(await readback()).generationRequests;
      let s = await pick('workspace.scope-selector','workspace');
      const scopeBefore = await fs.readFile(path.join(root,'config.json'),'utf8');
      // Each event card has one directional edit button; locate it under the current stop card.
      let lines=s.split('\n'); let start=lines.findIndex(line=>line.includes('container workspace.event.stop'));
      assert(start>=0,'Workspace stop event did not mount');
      let candidate=lines.slice(start+1).find(line=>/button (?:Manage sounds|管理声音)/i.test(line));
      assert(candidate,'Directional workspace editor did not appear');
      await app.click(number(candidate)); s=await state();
      assert(s.includes('ID: settings.sounds.return-to-scope'),'Typed return control did not appear');
      assert((await readback()).aiPhase==='editing' && (await readback()).generationRequests===initialGenerationRequests,'Directional edit started a provider generation');
      await clickID('settings.sounds.return-to-scope');
      assert(await fs.readFile(path.join(root,'config.json'),'utf8')===scopeBefore,'Navigation rewrote workspace configuration');
      await clickID('settings.sidebar.sounds');
      await pick('sound-packs.pack-list','regression-pack');
      await observe(`flow-${index}-composer-entry`);
      if (composerPoint) {
        const fresh=await state(); find(fresh,line=>line.includes('ID: settings.sounds.ai-cue.event.stop')&&!line.includes('stop_failure'));
        lastAction='screenshot-confirmed composer pointer'; await app.click(composerPoint); await state();
      } else {
        const current=await state(); const row=current.split('\n').find(line=>line.includes('ID: sound-packs.event.stop,')||line.endsWith('ID: sound-packs.event.stop'));
        const anchor=row?.match(/Description: ([^，,]+)/)?.[1];
        await pointerID('settings.sounds.ai-cue.event.stop',{text:index<=4?'描述生成':'Describe & generate',anchor,scrollDownIfMissing:true});
      }
      assert((await state()).includes('settings.sounds.ai-cue.composer.stop'),'Composer did not target the selected stop event');
      const description='A short soft chime for a finished response.';
      await textID('event-settings.ai-cue.description',description);
      const requestsBefore=(await readback()).generationRequests;
      await clickID('event-settings.ai-cue.generate');
      s=await state(); assert(s.includes('event-settings.ai-cue.cancel-generation'),'Generating controls did not appear');
      const locked=s.split('\n').find(line=>/^\s*\d+/.test(line)&&line.includes('ID: event-settings.ai-cue.description'));
      assert(locked && !locked.includes('(settable)') && /locked|锁定/i.test(locked) && (await readback()).description===description,'Description did not lock while generating');
      await pointerID('event-settings.ai-cue.cancel-generation',{scrollDownIfMissing:true});
      assert((await readback()).aiPhase==='editing','Cancellation did not restore editing');
      await clickID('event-settings.ai-cue.generate'); await key('super+shift+g');
      s=await state(); assert((await readback()).candidateCount===3,'Route-owned complete candidate count was not three');
      const generationCount=(await readback()).generationRequests;
      await textID('event-settings.ai-cue.name',`Fixture adopted cue ${index}`);
      assert((await readback()).generationRequests===generationCount,'Rename triggered a new generation');
      const oldMapping=(await manifest()).events.stop;
      await pointerID('event-settings.ai-cue.candidate.clear.use',{text:index<=4?'用于此事件':'Use for this event',anchor:index<=4?'A · 清晰':'A · Clear',anchorPlacement:'same-row',scrollDownIfMissing:true});
      s=await state(); assert(s.includes('event-settings.ai-cue.applied'),'Adoption did not show its result');
      assert((await manifest()).events.stop!==oldMapping || (await manifest()).audio_names?.[(await manifest()).events.stop]===`Fixture adopted cue ${index}`,'Successful adoption did not update the real isolated manifest');
      await clickID('settings.sidebar.general');
      assert((await readback()).candidateCount===0,'Leaving Sounds retained unadopted candidates');
      return {workspaceReturn:true,cancel:true,completeCandidates:3,renameWithoutGeneration:true,adoptedMapping:(await manifest()).events.stop,requestsBefore};
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
      await pointerID('event-notice.remove');
      assert((await readback()).reminders===0,'Explicit removal did not remove the fixture reminder');
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
      assert((await readback()).reminders===1 && (await readback()).navigation==='opened','Substitute open success removed the reminder or failed');
      assert((await readback()).remaining<=remaining,'Retry reset the remaining budget');
      await key('super+shift+r');
      await control('Show settings');
      const beforeClose=(await readback()).handbacks;
      s=await state(); await app.click(find(s,line=>/^\s*\d+ close button$/.test(line))); await state();
      assert((await readback()).handbacks===beforeClose+1,'Window close did not consume one handback');
      return {copy:true,remove:true,inlineRetry:true,successKeepsReminder:true,closeHandback:true};
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
        await pick('event-settings.ai-cue.provider-profile', 'SenseAudio');
        const row=(await state()).split('\n').find(line=>line.includes('ID: sound-packs.event.stop,')||line.endsWith('ID: sound-packs.event.stop'));
        await pointerID('settings.sounds.ai-cue.event.stop',{text:'描述生成',anchor:row?.match(/Description: ([^，,]+)/)?.[1],scrollDownIfMissing:true});
        let s=await textID('event-settings.ai-cue.description','一个简短柔和的铃声提示音。');
        assert((await readback()).description==='一个简短柔和的铃声提示音。','The native description input did not retain its text');
        const before=await manifest(); const requests=(await readback()).generationRequests;
        await clickID('event-settings.ai-cue.generate'); await key('super+shift+g');
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
      await control('Advance 4 seconds');
      await control('Source timeout'); await control('Verified-source reminder');
      await key('super+shift+b');
      await pointerID((await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.open-source.'))?.match(/ID: (\S+)/)?.[1]??'missing-banner-action');
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
      await control('Return to settings');
      let settingsState=await state(); await app.click(find(settingsState,line=>/^\s*\d+ close button$/.test(line))); await state();
      await key('super+shift+p'); await clickID('panel.recent-notices');
      await key('super+shift+u'); let s=await state();
      assert(s.includes('event-notice.refresh'),'Updated frozen reminder did not request explicit refresh');
      await clickID('event-notice.refresh');
      const recent=(await state()).split('\n').find(line=>/^\s*\d+ button/.test(line)&&line.includes('ID: event-notice.recent.'));
      assert(recent,'Refreshed reminder did not expose a version-bound identity');
      await pointerID(recent.match(/ID: (\S+)/)[1]);
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
        if (scenario==='invalid-workspace') assert((JSON.parse(await fs.readFile(path.join(root,'config.json'),'utf8')).workspace_rules??[]).length===0 && s.includes('workspace.scope.unavailable') && !s.includes('workspace.preview-available'),'Invalid workspace did not reject the isolated target');
        if (scenario==='stale-snapshot') assert(back.libraryFresh===false,'Snapshot did not become stale');
        if (scenario==='duplicate-mapping') assert((await manifest()).events.task_start===(await manifest()).events.notification,'Shared audio mapping was not preserved');
        if (scenario==='damaged-pack') assert(s.includes('声音包缺失或损坏，请在声音页修复') && s.split('\n').some(line=>line.includes('workspace.preview-available')&&line.includes('disabled')),'Damaged package did not show its pack-level repair reason');
        if (scenario==='empty-library') assert(/没有|No |缺少|missing|不可用|unavailable/i.test(s),'Empty library did not show an honest state');
        return {scenario,readback:back};
      }));
    }
    return output;
  }
  return {pointerID,matrix,flow,reminderFlow,generationExceptions,exceptions,report,readback,state,clickID,control,key,observe,pick,test};
}
