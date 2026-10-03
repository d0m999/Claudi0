// Run only from mcp__cua_repl. All input uses its native app binding; disk reads are fixture-only.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createNativeUIRegression} from './native-ui-regression.mjs';

const executeFile = promisify(execFile);

export async function createEventAnimationRegression(options) {
  const run = await createNativeUIRegression(options);
  const {app,outputDirectory} = options;
  const driverSHA256=crypto.createHash('sha256').update(await fs.readFile(new URL(import.meta.url))).digest('hex');
  const styles=['original','mechanicalDuck','pixelGhost','bitcoin'];
  const events=['task_start','notification','stop','subagent_stop','stop_failure'];
  const assert=(value,message)=>{if(!value)throw new Error(message);};
  const restartExpectedFile=path.join(outputDirectory,'event-animation-restart-expected.json');
  const animationKey='Claudio.Notifications.EventAnimation';
  const languageKey='Claudio.InterfaceLanguage';
  const styleLabels={
    'zh-Hans':{original:'原版图标',mechanicalDuck:'机械小鸭',pixelGhost:'像素幽灵',bitcoin:'比特币'},
    en:{original:'Original icons',mechanicalDuck:'Mechanical duck',pixelGhost:'Pixel ghost',bitcoin:'Bitcoin'},
  };
  const preferences=async()=>{
    const read=await run.readback();
    assert(read.eventAnimation,'Animation readback is unavailable');return read;
  };
  function lineForID(state,id) {
    const lines=state.split('\n').filter(line=>/^\s*\d+\b/.test(line)&&line.includes(`ID: ${id}`)&&(line.endsWith(id)||line.includes(`ID: ${id},`)));
    assert(lines.length===1,`Native animation identity is not unique: ${id} (${lines.length})`);
    return lines[0];
  }
  function valueIs(line,value) {
    return line.includes(`Value: ${value},`)||line.endsWith(`Value: ${value}`);
  }
  function resourceFailurePresent(state) {
    return state.split('\n').some(line=>/^\s*\d+ container settings\.animation\.resource-failure(?:,|$)/.test(line)
      ||(/^\s*\d+\b/.test(line)&&line.includes('ID: settings.animation.resource-failure')&&(line.endsWith('settings.animation.resource-failure')||line.includes('ID: settings.animation.resource-failure,'))));
  }
  function assertPreviewIsolation(initial,current) {
    assert(current.reminders===initial.reminders,'Preview changed the real reminder count');
    assert(current.generationRequests===initial.generationRequests,'Preview started a real generation request');
  }
  function assertStyleSelection(state,style,language) {
    const selectedValue=language==='zh-Hans'?'已选择':'Selected';
    const unselectedValue=language==='zh-Hans'?'未选择':'Not selected';
    for(const candidate of styles) {
      const line=lineForID(state,`settings.animation.style.${candidate}`);
      assert(/\bbutton\b/.test(line),`Style is not a native button: ${candidate}`);
      assert(line.includes('(selected)')===(candidate===style),`Native selected trait disagrees with preference: ${line}`);
      assert(valueIs(line,candidate===style?selectedValue:unselectedValue),`Native selected value disagrees with preference: ${line}`);
    }
  }
  function imageDimensions(bytes) {
    if(bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) {
      return {width:bytes.readUInt32BE(16),height:bytes.readUInt32BE(20)};
    }
    if(bytes[0]===255&&bytes[1]===216) {
      let offset=2;
      while(offset<bytes.length) {
        while(bytes[offset]===255)offset++;
        const marker=bytes[offset++];const length=bytes.readUInt16BE(offset);
        if([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)) {
          return {width:bytes.readUInt16BE(offset+5),height:bytes.readUInt16BE(offset+3)};
        }
        offset+=length;
      }
    }
    throw new Error('Screenshot dimensions cannot be determined');
  }
  async function requireSettingsKey() {
    // AX press can leave this nonactivating panel without key focus. Use its current
    // native Raise action before the fixture's explicit focus shortcut.
    let current=await run.state();
    if(!/Window: "claudi0 · (设置|Settings)"/.test(current)) {
      await run.key('super+shift+l');
      current=await run.state();
    }
    assert(/Window: "claudi0 · (设置|Settings)"/.test(current),'Settings window is not the current surface');
    const windows=current.split('\n').filter(line=>/^\s*\d+ system dialog/.test(line)&&line.includes('Secondary Actions: Raise'));
    assert(windows.length===1,`Native Settings Raise locator expected one window, found ${windows.length}`);
    await app.performSecondaryAction(Number(windows[0].match(/^\s*(\d+)/)[1]),'Raise');
    await run.state();
    await run.key('super+shift+l');
    if(!/^claudi0 · (设置|Settings)$/.test((await preferences()).keyWindow)) {
      // Nonactivating panels can stay visibleNonKey after AX Raise and a shortcut.
      // Click the title bar using this window's current capture and measured geometry.
      const capture=await run.observe(`settings-key-recovery-${run.report.actions.length+1}`);
      assert(/Window: "claudi0 · (设置|Settings)"/.test(capture.ax),'Settings focus capture is not the current surface');
      const geometry=capture.readback.windowGeometry;
      const dimensions=imageDimensions(await fs.readFile(path.join(outputDirectory,capture.screenshot)));
      const titleBarHeight=geometry?.frameHeight-geometry?.height;
      const pixelScale=geometry?.frameWidth*geometry?.backingScale/dimensions.width;
      assert(Number.isFinite(pixelScale)&&pixelScale>0&&Number.isFinite(titleBarHeight)&&titleBarHeight>0,'Native Settings title bar geometry is unavailable');
      assert(Math.abs(dimensions.height*pixelScale-geometry.frameHeight*geometry.backingScale)<1,'Settings focus capture does not match the measured window geometry');
      const point=[dimensions.width/2*pixelScale,titleBarHeight/2*geometry.backingScale];
      current=await run.state();
      assert(/Window: "claudi0 · (设置|Settings)"/.test(current),'Settings window changed before title bar input');
      run.report.actions.push({id:'settings.window.titlebar',screenshot:capture.screenshot,point,pixelScale,geometry,driverSHA256});
      await app.click(point);
      await run.state();
    }
    await run.waitUntil(async()=>/^claudi0 · (设置|Settings)$/.test((await preferences()).keyWindow),'Settings must acquire key focus');
    return run.state();
  }
  async function scrollToTop() {
    const state=await run.state();
    const scroll=state.split('\n').find(line=>/^\s*\d+ scroll area/.test(line)&&!line.includes('sidebar'));
    assert(scroll,'Animation Settings has no current content scroll area');
    await app.scroll(Number(scroll.match(/^\s*(\d+)/)[1]),'up',20);
    return run.state();
  }
  function assertMatrix(read,index) {
    const language=index<=4?'zh-Hans':'en';
    const dark=index%4===3||index%4===0;
    const geometry=read.windowGeometry;
    assert(geometry&&Math.abs(geometry.width-(index%2===0?960:1240))<1&&Math.abs(geometry.height-(index%2===0?640:820))<1,`Requested animation window size was constrained: ${JSON.stringify(geometry)}`);
    assert(geometry.appearance===(dark?'NSAppearanceNameDarkAqua':'NSAppearanceNameAqua'),'Requested animation appearance was not applied');
    assert(read.language===language,`Requested animation language was not applied: ${read.language}`);
    const frames=read.settingsLayout?.frames;
    assert(frames&&read.settingsLayout.sampleColorSpace==='sRGB','Mounted animation layout evidence is unavailable');
    const choices=frames['settings.animation.choices'];
    const content=frames['settings.content'];
    const reading=frames['settings.reading.notifications'];
    assert(choices&&content&&reading,'Animation choice container or reading column is missing');
    const contained=(inner,outer)=>inner.x>=outer.x-1&&inner.y>=outer.y-1&&inner.x+inner.width<=outer.x+outer.width+1&&inner.y+inner.height<=outer.y+outer.height+1;
    const cards=styles.map(style=>({style,...frames[`settings.animation.style.${style}`]}));
    assert(cards.every(card=>Number.isFinite(card.x)&&Number.isFinite(card.y)&&card.width>40&&Math.abs(card.height-153)<1),'One or more animation cards have invalid geometry');
    assert(cards.every(card=>contained(card,choices)&&contained(card,content)&&contained(card,reading)),`Animation card is clipped by its visible container: ${JSON.stringify(cards)}`);
    assert(cards.every(card=>Math.abs(card.y-cards[0].y)<1&&Math.abs(card.width-cards[0].width)<1),'Animation choices are not four equal side-by-side cards');
    assert(cards.slice(1).every((card,i)=>card.x>=cards[i].x+cards[i].width+11),'Animation cards overlap or lose their 12 pt gaps');
    return {language,appearance:dark?'dark':'light',requestedSize:index%2===0?'960x640':'1240x820',actualGeometry:geometry,cards};
  }
  async function persistedAnimation() {
    const file=path.join(run.report.active.root,'preferences.plist');
    // This utility only decodes the private fixture file. It cannot send UI input.
    const {stdout}=await executeFile('/usr/bin/plutil',['-convert','xml1','-o','-',file]);
    const data=stdout.match(/<key>Claudio\.Notifications\.EventAnimation<\/key>\s*<data>([\s\S]*?)<\/data>/)?.[1];
    const language=stdout.match(/<key>Claudio\.InterfaceLanguage<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
    assert(data&&language,`Persisted fixture keys are missing: ${animationKey}, ${languageKey}`);
    const bytes=Buffer.from(data.replace(/\s/g,''),'base64');
    return {preferences:JSON.parse(bytes.toString('utf8')),language,SHA256:crypto.createHash('sha256').update(bytes).digest('hex')};
  }
  async function enter() {
    let state=await run.state();
    if(!state.includes('ID: settings.animation.back')) {
      await run.clickID('settings.sidebar.notifications');
      await run.clickID('settings.notifications.event-animation');
    }
    return run.state();
  }
  async function matrix(index) {
    return run.test(`event-animation-matrix-${index}`,async()=>{
      assert(index>=1&&index<=8,'Unknown matrix');
      await run.control(`Matrix ${index}`);
      await requireSettingsKey();
      await enter();
      const captures=[];
      for(const style of styles) {
        await run.clickID(`settings.animation.style.${style}`);
        await run.waitUntil(async()=> (await preferences()).eventAnimation.style===style,'Selected style readback');
        await run.control('Capture state');
        await requireSettingsKey();
        await scrollToTop();
        const state=await run.state();
        const read=await preferences();
        assertStyleSelection(state,style,read.language);
        const layout=assertMatrix(read,index);
        assert(read.eventAnimation.showsCharacter===true,'Selection did not enable the character');
        assert(read.reminders===0&&read.generationRequests===0,'Preview changed real event or sound state');
        const capture=await run.observe(`event-animation-${index}-${style}`);
        captures.push({style,layout,screenshot:capture.screenshot,axFile:capture.axFile});
      }
      return {index,captures,driverSHA256};
    });
  }
  async function interactions() {
    return run.test('event-animation-native-interactions',async()=>{
      await enter();
      await requireSettingsKey();
      await scrollToTop();
      const initial=await preferences();
      const language=initial.language;
      await run.pointerID('settings.animation.style.bitcoin',{text:styleLabels[language].bitcoin});
      await run.waitUntil(async()=> (await preferences()).eventAnimation.style==='bitcoin','Pointer style selection persistence');
      if((await preferences()).eventAnimation.usesStaticExpression) {
        await run.clickID('settings.animation.static-expression');
        await run.waitUntil(async()=> !(await preferences()).eventAnimation.usesStaticExpression,'Initial animated preview mode');
      }
      for(const event of events) {
        await run.clickID(`settings.animation.event.${event}`);
        await run.waitUntil(async()=> (await preferences()).eventAnimation.previewEvent===event,'Preview event readback');
      }
      const before=await preferences();
      await run.clickID('settings.animation.replay');
      await run.waitUntil(async()=> (await preferences()).eventAnimation.previewRevision>before.eventAnimation.previewRevision,'Replay revision');
      assertPreviewIsolation(initial,await preferences());
      await run.clickID('settings.animation.show-character');
      await run.waitUntil(async()=> (await preferences()).eventAnimation.effectiveStyle==='original','Disabled effective style');
      assert((await preferences()).eventAnimation.style==='bitcoin','Disabling lost remembered style');
      await run.clickID('settings.animation.show-character');
      await run.clickID('settings.animation.static-expression');
      await run.waitUntil(async()=> (await preferences()).eventAnimation.usesStaticExpression===true,'Static preference');
      await requireSettingsKey();
      await scrollToTop();
      await run.pointerID('settings.animation.back',{text:language==='zh-Hans'?'返回通知':'Back to Notifications'});
      const returnState=await run.waitUntil(async state=>(await preferences()).eventAnimation.previewActive===false&&state.split('The focused UI element is ')[1]?.includes('settings.notifications.event-animation'),'Back must stop preview and restore entry focus');
      assert(returnState.split('The focused UI element is ')[1]?.includes('settings.notifications.event-animation'),'Back did not restore entry focus');
      await run.clickID('settings.notifications.event-animation');
      await run.clickID('settings.sidebar.general');
      assert((await preferences()).eventAnimation.previewActive===false,'Leaving notifications retained preview');
      await run.clickID('settings.sidebar.notifications');
      await run.clickID('settings.notifications.event-animation');
      await run.clickID('settings.animation.style.original');
      assert(!(await run.state()).includes('ID: settings.animation.show-character'),'Original showed character-only options');
      assertPreviewIsolation(initial,await preferences());
      return {events:events.length,immediatePersistence:true,rememberedSelection:true,previewIsolation:true,leaveCleanup:true,backFocus:true,driverSHA256};
    });
  }
  async function keyboard() {
    return run.test('event-animation-native-keyboard',async()=>{
      await enter();
      await run.clickID('settings.animation.style.original');
      await requireSettingsKey();
      const initial=await preferences();
      // Every iteration obtains new AX indices. Native Space activation must update the
      // persisted projection; reaching a control alone does not count as keyboard coverage.
      const visited=[];
      const activated=[];
      let rememberedStyle=initial.eventAnimation.style;
      const required=[...styles.map(style=>`settings.animation.style.${style}`),...events.map(event=>`settings.animation.event.${event}`),'settings.animation.replay','settings.animation.show-character','settings.animation.static-expression'];
      for(let count=0;count<52;count++) {
        const state=await run.key('Tab');
        const focused=state.split('The focused UI element is ')[1]??'';
        const id=focused.match(/ID: ([^,\n]+)/)?.[1];
        if(id)visited.push(id);
        if(id?.startsWith('settings.animation.style.')&&!activated.includes(id)) {
          const style=id.slice('settings.animation.style.'.length);
          assert(styles.includes(style),`Unexpected style Tab stop: ${id}`);
          await run.key('space');
          await run.waitUntil(async()=> (await preferences()).eventAnimation.style===style,`Keyboard style selection persistence: ${style}`);
          assertStyleSelection(await run.state(),style,initial.language);
          rememberedStyle=style;
          activated.push(id);
        } else if(id?.startsWith('settings.animation.event.')&&!activated.includes(id)) {
          const event=id.slice('settings.animation.event.'.length);
          assert(events.includes(event),`Unexpected event Tab stop: ${id}`);
          await run.key('space');
          await run.waitUntil(async()=> (await preferences()).eventAnimation.previewEvent===event,`Keyboard event selection: ${event}`);
          activated.push(id);
        } else if(id==='settings.animation.replay'&&!activated.includes(id)) {
          const revision=(await preferences()).eventAnimation.previewRevision;
          await run.key('space');
          await run.waitUntil(async()=> (await preferences()).eventAnimation.previewRevision>revision,'Keyboard Replay activation');
          activated.push(id);
        } else if(['settings.animation.show-character','settings.animation.static-expression'].includes(id)&&!activated.includes(id)) {
          assert(/\bcheckbox\b|\bcheck box\b/.test(lineForID(state,id)),`Animation switch does not expose its native checkbox role: ${id}`);
          const field=id.endsWith('show-character')?'showsCharacter':'usesStaticExpression';
          const before=(await preferences()).eventAnimation[field];
          await run.key('space');
          await run.waitUntil(async()=> (await preferences()).eventAnimation[field]===!before,`Keyboard switch persistence: ${field}`);
          assert((await preferences()).eventAnimation.style===rememberedStyle,'Keyboard switch lost the remembered style');
          activated.push(id);
        }
        if(required.every(id=>visited.includes(id)&&activated.includes(id)))break;
      }
      const diagnostics=`visited=${JSON.stringify(visited)}, activated=${JSON.stringify(activated)}`;
      assert(required.every(id=>visited.includes(id)),`Tab did not reach every animation control: ${diagnostics}`);
      assert(styles.every(style=>activated.includes(`settings.animation.style.${style}`)),`Space did not activate all four style choices: ${diagnostics}`);
      assert(events.every(event=>activated.includes(`settings.animation.event.${event}`)),`Space did not activate all five event previews: ${diagnostics}`);
      assert(['settings.animation.replay','settings.animation.show-character','settings.animation.static-expression'].every(id=>activated.includes(id)),`Space did not activate Replay and both switches: ${diagnostics}`);
      assert((await preferences()).eventAnimation.style===rememberedStyle,'Keyboard switches lost the selected style');
      assertPreviewIsolation(initial,await preferences());
      assert((await preferences()).eventAnimation.previewActive,'Keyboard preview was not active before returning');
      const returnVisited=[];
      let backFocused=false;
      for(let count=0;count<36;count++) {
        const state=await run.key('Tab');
        const id=(state.split('The focused UI element is ')[1]??'').match(/ID: ([^,\n]+)/)?.[1];
        if(id)returnVisited.push(id);
        if(id==='settings.animation.back') {
          assert(/\bbutton\b/.test(lineForID(state,id)),'Keyboard Back is not a native button');
          backFocused=true;
          await run.key('space');
          await run.waitUntil(async current=>(await preferences()).eventAnimation.previewActive===false&&current.split('The focused UI element is ')[1]?.includes('ID: settings.notifications.event-animation'),'Keyboard Back must stop preview and restore entry focus');
          break;
        }
      }
      assert(backFocused,`Tab did not reach Back for native Space activation: visited=${JSON.stringify(returnVisited)}`);
      assert((await preferences()).eventAnimation.style===rememberedStyle,'Keyboard Back lost the remembered style');
      assertPreviewIsolation(initial,await preferences());
      return {visited,activated,returnVisited,keyboardSelection:true,fourStyleSelections:true,rememberedStyle,fiveEventPreviews:true,keyboardReplay:true,keyboardSwitches:true,keyboardBack:true,backFocus:true,previewIsolation:true,driverSHA256};
    });
  }
  async function resourceRecovery() {
    return run.test('event-animation-native-resource-recovery',async()=>{
      await run.control('Break animation resources');
      await requireSettingsKey();
      await enter();
      await run.waitUntil(resourceFailurePresent,'Resource fallback reason');
      assert((await preferences()).eventAnimation.style==='mechanicalDuck','Failure lost selection');
      const language=(await preferences()).language;
      const fallbackState=await run.state();
      assert(/failed validation|校验失败/i.test(fallbackState),'Resource failure did not expose its checksum reason');
      await run.observe('event-animation-resource-fallback');
      await requireSettingsKey();
      await scrollToTop();
      await run.pointerID('settings.animation.back',{text:language==='zh-Hans'?'返回通知':'Back to Notifications'});
      await run.waitUntil(state=>valueIs(lineForID(state,'settings.notifications.event-animation'),styleLabels[language].original),'Overview must show the resource fallback style');
      await run.observe('event-animation-resource-overview-fallback');
      await enter();
      await run.control('Restore animation resources');
      await requireSettingsKey();
      assert(resourceFailurePresent(await run.state()),'Restoring bytes silently skipped explicit retry');
      await run.clickID('settings.animation.retry');
      await run.waitUntil(state=>!resourceFailurePresent(state),'Explicit retry recovery');
      assert((await preferences()).eventAnimation.style==='mechanicalDuck','Retry lost the selected character');
      await requireSettingsKey();
      await scrollToTop();
      await run.pointerID('settings.animation.back',{text:language==='zh-Hans'?'返回通知':'Back to Notifications'});
      await run.waitUntil(state=>valueIs(lineForID(state,'settings.notifications.event-animation'),styleLabels[language].mechanicalDuck),'Overview must show the recovered character');
      return {fallbackReason:true,selectionKept:true,overviewFallback:true,explicitRetry:true,overviewRecovery:true,driverSHA256};
    });
  }
  async function prepareRestart() {
    return run.test('event-animation-native-restart-prepare',async()=>{
      await requireSettingsKey();
      await enter();
      await run.clickID('settings.animation.style.pixelGhost');
      await run.waitUntil(async()=> (await preferences()).eventAnimation.style==='pixelGhost','Restart style preparation');
      if((await preferences()).eventAnimation.showsCharacter)await run.clickID('settings.animation.show-character');
      if(!(await preferences()).eventAnimation.usesStaticExpression)await run.clickID('settings.animation.static-expression');
      await run.waitUntil(async()=>{
        const value=(await preferences()).eventAnimation;
        return value.style==='pixelGhost'&&!value.showsCharacter&&value.usesStaticExpression&&value.effectiveStyle==='original';
      },'Restart preference preparation');
      const read=await preferences();
      const persisted=await persistedAnimation();
      assert(persisted.preferences.style==='pixelGhost'&&!persisted.preferences.showsCharacter&&persisted.preferences.usesStaticExpression,'Restart preparation was not persisted on disk');
      assert(persisted.language===read.language,'Restart language was not persisted on disk');
      const expected={bundleSHA256:run.report.build.bundleSHA256,fixtureRoot:run.report.active.root,language:read.language,...persisted,driverSHA256};
      await fs.writeFile(restartExpectedFile,JSON.stringify(expected,null,2));
      return {persisted:expected,restartControl:'Restart animation fixture',driverSHA256};
    });
  }
  async function verifyRestart() {
    return run.test('event-animation-native-restart-restored',async()=>{
      const expected=JSON.parse(await fs.readFile(restartExpectedFile,'utf8'));
      assert(expected.bundleSHA256===run.report.build.bundleSHA256,'Restart launched a different candidate bundle');
      assert(expected.fixtureRoot!==run.report.active.root,'Restart did not create a fresh isolated fixture root');
      const persisted=await persistedAnimation();
      assert(persisted.SHA256===expected.SHA256,'Restart changed the saved animation preference bytes');
      assert(persisted.language===expected.language,'Restart changed the saved language preference');
      const read=await preferences();
      assert(read.language===expected.language,'Restart changed the resolved interface language');
      assert(read.eventAnimation.style==='pixelGhost'&&!read.eventAnimation.showsCharacter&&read.eventAnimation.usesStaticExpression&&read.eventAnimation.effectiveStyle==='original','Restart did not restore remembered style and both switches');
      await run.control('Show settings');
      await requireSettingsKey();
      await enter();
      const state=await run.state();
      assertStyleSelection(state,'pixelGhost',expected.language);
      for(const id of ['settings.animation.show-character','settings.animation.static-expression'])assert(/\bcheckbox\b|\bcheck box\b/.test(lineForID(state,id)),`Restored switch is absent: ${id}`);
      await run.observe('event-animation-restart-restored-preferences');
      return {freshFixture:true,persistedBytes:true,rememberedStyle:true,showsCharacter:false,usesStaticExpression:true,effectiveStyle:'original',language:expected.language,driverSHA256};
    });
  }
  return {...run,matrix,interactions,keyboard,resourceRecovery,prepareRestart,verifyRestart};
}
