/**
 * WebSim SDK — Reusable WASM board simulator runtime.
 *
 * Boards only need to provide HTML layout (with standard element IDs)
 * and call `WebSim.start()`. Everything else is handled automatically.
 *
 * Standard element IDs (all optional — features auto-detect):
 *   #status           — status badge ("Loading..." → "Running")
 *   #displayCanvas    — LVGL display (240x240 RGB565)
 *   #ledGlowCanvas    — LED glow rendering canvas
 *   #ledContainer     — LED DOM container (fallback if no glow canvas)
 *   .adc-btn          — ADC buttons (data-adc="200" etc.)
 *   #btnPower         — power button (calls powerPress/Release)
 *   #btnBoot          — boot button (calls buttonPress/Release)
 *   #logContent       — log output area
 *   #logClear         — clear log button
 *   #logCopy          — copy log button
 *   #logAutoScroll    — auto-scroll toggle
 *   #screenRecBtn     — screen recorder button
 *   .sim-container    — recording capture area
 *
 * Keyboard shortcuts (auto-bound):
 *   Arrow keys + Enter + Escape + R → ADC buttons
 *   Space → power or boot button
 */

const WebSim = (() => {
    let wasm = null;
    let memory = null;
    let running = false;
    const decoder = new TextDecoder();

    function mem() {
        if (memory) return memory.buffer;
        if (wasm) return wasm.instance.exports.memory.buffer;
        return new ArrayBuffer(0);
    }

    // ========================================================================
    // Display
    // ========================================================================
    let canvasCtx = null, imageData = null;

    function initDisplay() {
        const c = document.getElementById('displayCanvas');
        if (!c) return;
        canvasCtx = c.getContext('2d');
        imageData = canvasCtx.createImageData(c.width, c.height);
    }

    function updateDisplay() {
        if (!canvasCtx || !wasm) return;
        const ex = wasm.instance.exports;
        if (!ex.getDisplayDirty()) return;
        ex.clearDisplayDirty();

        const fbPtr = ex.getDisplayFbPtr();
        const fbSize = ex.getDisplayFbSize();
        const w = ex.getDisplayWidth(), h = ex.getDisplayHeight();
        const fb = new Uint8Array(memory.buffer, fbPtr, fbSize);
        const rgba = imageData.data;

        for (let i = 0; i < w * h; i++) {
            const lo = fb[i * 2], hi = fb[i * 2 + 1];
            const rgb565 = (hi << 8) | lo;
            rgba[i * 4]     = ((rgb565 >> 11) & 0x1F) * 255 / 31 | 0;
            rgba[i * 4 + 1] = ((rgb565 >> 5) & 0x3F) * 255 / 63 | 0;
            rgba[i * 4 + 2] = (rgb565 & 0x1F) * 255 / 31 | 0;
            rgba[i * 4 + 3] = 255;
        }
        canvasCtx.putImageData(imageData, 0, 0);
    }

    // ========================================================================
    // LED Glow (canvas-based diffuse light)
    // ========================================================================
    const LED_POSITIONS = [
        {x:0.50,y:0.20},{x:0.35,y:0.35},{x:0.65,y:0.35},
        {x:0.22,y:0.50},{x:0.50,y:0.50},{x:0.78,y:0.50},
        {x:0.35,y:0.65},{x:0.65,y:0.65},{x:0.50,y:0.80},
    ];
    let glowCtx = null, glowCanvas = null;

    function initGlow() {
        glowCanvas = document.getElementById('ledGlowCanvas');
        if (glowCanvas) glowCtx = glowCanvas.getContext('2d');
    }

    function updateLEDs() {
        if (!wasm) return;
        const ex = wasm.instance.exports;

        if (glowCtx) {
            // Canvas glow mode
            const count = Math.min(ex.getLedCount(), LED_POSITIONS.length);
            const w = glowCanvas.width, h = glowCanvas.height;
            glowCtx.clearRect(0, 0, w, h);
            for (let i = 0; i < count; i++) {
                const packed = ex.getLedColor(i);
                if (!packed) continue;
                const r = (packed>>16)&0xFF, g = (packed>>8)&0xFF, b = packed&0xFF;
                const pos = LED_POSITIONS[i];
                const cx = pos.x*w, cy = pos.y*h, radius = w*0.35;
                const grad = glowCtx.createRadialGradient(cx,cy,0,cx,cy,radius);
                grad.addColorStop(0, `rgba(${r},${g},${b},0.9)`);
                grad.addColorStop(0.15, `rgba(${r},${g},${b},0.5)`);
                grad.addColorStop(0.5, `rgba(${r},${g},${b},0.15)`);
                grad.addColorStop(1, `rgba(${r},${g},${b},0)`);
                glowCtx.fillStyle = grad;
                glowCtx.fillRect(0,0,w,h);
                const core = glowCtx.createRadialGradient(cx,cy,0,cx,cy,4);
                core.addColorStop(0, `rgba(255,255,255,0.8)`);
                core.addColorStop(0.5, `rgba(${r},${g},${b},0.6)`);
                core.addColorStop(1, `rgba(${r},${g},${b},0)`);
                glowCtx.fillStyle = core;
                glowCtx.fillRect(cx-6,cy-6,12,12);
            }
        } else {
            // DOM LED fallback
            const container = document.getElementById('ledContainer');
            if (!container) return;
            const count = ex.getLedCount();
            while (container.children.length < count) {
                const d = document.createElement('div');
                d.className = 'led';
                container.appendChild(d);
            }
            for (let i = 0; i < count; i++) {
                const packed = ex.getLedColor(i);
                const el = container.children[i];
                if (packed) {
                    const c = `rgb(${(packed>>16)&0xFF},${(packed>>8)&0xFF},${packed&0xFF})`;
                    el.classList.add('lit');
                    el.style.background = c;
                    el.style.setProperty('--led-color', c);
                } else {
                    el.classList.remove('lit');
                    el.style.background = '';
                    el.style.removeProperty('--led-color');
                }
            }
        }
    }

    // ========================================================================
    // Log
    // ========================================================================
    let logAutoScroll = true;

    function initLog() {
        const el = document.getElementById('logClear');
        const content = document.getElementById('logContent');
        if (el) el.addEventListener('click', () => { if (content) content.innerHTML = ''; });

        const copyBtn = document.getElementById('logCopy');
        if (copyBtn && content) copyBtn.addEventListener('click', () => {
            navigator.clipboard.writeText(content.innerText).then(() => {
                copyBtn.textContent = 'Copied!';
                setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1000);
            });
        });

        const scrollBtn = document.getElementById('logAutoScroll');
        if (scrollBtn) {
            scrollBtn.classList.add('active');
            scrollBtn.addEventListener('click', () => {
                logAutoScroll = !logAutoScroll;
                scrollBtn.classList.toggle('active', logAutoScroll);
                scrollBtn.textContent = logAutoScroll ? '\u21A7 Auto' : '\u21A7 Off';
            });
        }
    }

    function updateLog() {
        if (!wasm) return;
        const ex = wasm.instance.exports;
        if (!ex.getLogDirty()) return;
        ex.clearLogDirty();

        const content = document.getElementById('logContent');
        if (!content) return;
        const total = Math.min(ex.getLogCount(), 32);
        const lines = [];
        for (let i = 0; i < total; i++) {
            const len = ex.getLogLineLen(i);
            if (len > 0) {
                const ptr = ex.getLogLinePtr(i);
                lines.push(decoder.decode(new Uint8Array(memory.buffer, ptr, len)));
            }
        }
        content.innerHTML = lines.map(l => {
            let c = 'log-line';
            if (l.startsWith('[INFO]')) c += ' info';
            else if (l.startsWith('[ERROR]')) c += ' error';
            else if (l.startsWith('[WARN]')) c += ' warn';
            return `<div class="${c}">${l.replace(/&/g,'&amp;').replace(/</g,'&lt;')}</div>`;
        }).join('');
        if (logAutoScroll) content.scrollTop = content.scrollHeight;
    }

    // ========================================================================
    // Input (ADC buttons, power, boot, keyboard)
    // ========================================================================

    function initInput() {
        const adcBtns = document.querySelectorAll('.adc-btn');
        let activeAdc = null;

        function setAdc(btn, pressed) {
            if (!wasm) return;
            if (pressed) {
                if (activeAdc && activeAdc !== btn) activeAdc.classList.remove('pressed');
                activeAdc = btn;
                btn.classList.add('pressed');
                wasm.instance.exports.setAdcValue(parseInt(btn.dataset.adc));
            } else {
                if (activeAdc === btn) activeAdc = null;
                btn.classList.remove('pressed');
                wasm.instance.exports.setAdcValue(4095);
            }
        }

        adcBtns.forEach(btn => {
            btn.addEventListener('mousedown', e => { e.preventDefault(); setAdc(btn, true); });
            btn.addEventListener('mouseup', () => setAdc(btn, false));
            btn.addEventListener('mouseleave', () => { if (activeAdc === btn) setAdc(btn, false); });
            btn.addEventListener('touchstart', e => { e.preventDefault(); setAdc(btn, true); });
            btn.addEventListener('touchend', () => setAdc(btn, false));
            btn.addEventListener('touchcancel', () => setAdc(btn, false));
        });

        // Single buttons
        const btnPower = document.getElementById('btnPower');
        const btnBoot = document.getElementById('btnBoot');

        function bindBtn(el, pressExport, releaseExport) {
            if (!el) return;
            const down = () => { if (wasm) { el.classList.add('pressed'); wasm.instance.exports[pressExport](); }};
            const up = () => { if (wasm) { el.classList.remove('pressed'); wasm.instance.exports[releaseExport](); }};
            el.addEventListener('mousedown', e => { e.preventDefault(); down(); });
            el.addEventListener('mouseup', up);
            el.addEventListener('mouseleave', () => { if (el.classList.contains('pressed')) up(); });
            el.addEventListener('touchstart', e => { e.preventDefault(); down(); });
            el.addEventListener('touchend', up);
            el.addEventListener('touchcancel', up);
        }

        bindBtn(btnPower, 'powerPress', 'powerRelease');
        bindBtn(btnBoot, 'buttonPress', 'buttonRelease');

        // Keyboard
        const keyMap = {
            'ArrowUp':200, 'ArrowDown':500, 'ArrowLeft':800, 'ArrowRight':1100,
            'Escape':1400, 'Enter':1700, 'KeyR':2000,
        };

        document.addEventListener('keydown', e => {
            if (e.repeat) return;
            const v = keyMap[e.code];
            if (v !== undefined && wasm) {
                e.preventDefault();
                wasm.instance.exports.setAdcValue(v);
                adcBtns.forEach(b => { if (parseInt(b.dataset.adc) === v) b.classList.add('pressed'); });
            }
            if (e.code === 'Space') {
                e.preventDefault();
                if (btnPower && wasm) { btnPower.classList.add('pressed'); wasm.instance.exports.powerPress(); }
                else if (btnBoot && wasm) { btnBoot.classList.add('pressed'); wasm.instance.exports.buttonPress(); }
            }
        });

        document.addEventListener('keyup', e => {
            const v = keyMap[e.code];
            if (v !== undefined && wasm) {
                e.preventDefault();
                wasm.instance.exports.setAdcValue(4095);
                adcBtns.forEach(b => { if (parseInt(b.dataset.adc) === v) b.classList.remove('pressed'); });
            }
            if (e.code === 'Space') {
                e.preventDefault();
                if (btnPower && wasm) { btnPower.classList.remove('pressed'); wasm.instance.exports.powerRelease(); }
                else if (btnBoot && wasm) { btnBoot.classList.remove('pressed'); wasm.instance.exports.buttonRelease(); }
            }
        });
    }

    // ========================================================================
    // Screen Recorder (html2canvas → canvas → webm → ffmpeg mp4)
    // ========================================================================

    function initRecorder() {
        const btn = document.getElementById('screenRecBtn');
        const target = document.querySelector('.sim-container');
        if (!btn || !target) return;

        let state = 'idle', recorder = null, chunks = [], timerId = null, aborted = false;
        const canvas = document.createElement('canvas');

        btn.addEventListener('click', () => {
            if (state === 'converting') { aborted = true; if (window._ffmpeg) try { window._ffmpeg.terminate(); window._ffmpeg = null; } catch(_) {} return; }
            if (state === 'recording') { state = 'idle'; if (timerId) clearInterval(timerId); target.classList.remove('recording'); if (recorder && recorder.state === 'recording') recorder.stop(); return; }

            // Start
            state = 'recording'; target.classList.add('recording'); chunks = [];
            const r = target.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
            canvas.width = Math.round(r.width * dpr); canvas.height = Math.round(r.height * dpr);
            const stream = canvas.captureStream(20);
            recorder = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp9', videoBitsPerSecond: 4000000 });
            recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data); };
            recorder.onstop = async () => {
                state = 'converting'; aborted = false; btn.textContent = '\u2716 Converting...';
                const blob = new Blob(chunks, { type: 'video/webm' });
                const ts = new Date().toISOString().slice(0,19).replace(/:/g,'-');
                try {
                    if (!window._ffmpeg) {
                        btn.textContent = '\u2716 Loading FFmpeg...';
                        if (!window.FFmpegWASM) await new Promise((ok,err) => { const s = document.createElement('script'); s.src = './ffmpeg.js'; s.onload = ok; s.onerror = err; document.head.appendChild(s); });
                        if (aborted) throw 'Cancelled';
                        const f = new FFmpegWASM.FFmpeg(); await f.load({ coreURL: './ffmpeg-core.js', wasmURL: './ffmpeg-core.wasm' }); window._ffmpeg = f;
                    }
                    if (aborted) throw 'Cancelled';
                    let dots = 0; const dt = setInterval(() => { dots = (dots+1)%4; btn.textContent = '\u2716 Converting' + '.'.repeat(dots); }, 500);
                    const f = window._ffmpeg;
                    await f.writeFile('i.webm', new Uint8Array(await blob.arrayBuffer()));
                    if (aborted) throw 'Cancelled';
                    await f.exec(['-i','i.webm','-c:v','libx264','-preset','fast','-crf','23','-pix_fmt','yuv420p','o.mp4']);
                    clearInterval(dt); if (aborted) throw 'Cancelled';
                    const d = await f.readFile('o.mp4');
                    const u = URL.createObjectURL(new Blob([d], {type:'video/mp4'}));
                    const a = document.createElement('a'); a.href = u; a.download = 'websim-'+ts+'.mp4'; a.click(); URL.revokeObjectURL(u);
                    btn.textContent = 'Saved!';
                } catch(e) {
                    btn.textContent = aborted ? 'Cancelled' : 'Error!';
                    if (!aborted) { const ep = document.getElementById('errorPanel'), ec = document.getElementById('errorContent'); if (ep&&ec) { ep.style.display=''; ec.innerHTML += '<div class="log-line error">MP4: '+e+'</div>'; } }
                }
                state = 'idle'; setTimeout(() => { btn.textContent = '\u25CF Rec'; }, 2000);
            };

            const ctx = canvas.getContext('2d');
            timerId = setInterval(() => {
                if (typeof html2canvas !== 'undefined') html2canvas(target, { scale: dpr, backgroundColor: '#0f1117', logging: false }).then(s => { ctx.clearRect(0,0,canvas.width,canvas.height); ctx.drawImage(s,0,0,canvas.width,canvas.height); }).catch(()=>{});
            }, 50);
            recorder.start(100); btn.textContent = '\u25A0 Stop'; btn.classList.add('recording');
        });
    }

    // ========================================================================
    // WASI Stubs
    // ========================================================================

    const wasiStubs = {
        fd_write: () => 0, fd_read: () => 0, fd_close: () => 0, fd_seek: () => 0,
        fd_fdstat_get: () => 0, fd_prestat_get: () => 8, fd_prestat_dir_name: () => 8,
        environ_get: () => 0,
        environ_sizes_get: (a, b) => { const v = new DataView(mem()); v.setUint32(a,0,true); v.setUint32(b,0,true); return 0; },
        args_get: () => 0,
        args_sizes_get: (a, b) => { const v = new DataView(mem()); v.setUint32(a,0,true); v.setUint32(b,0,true); return 0; },
        clock_time_get: (_,__,p) => { new DataView(mem()).setBigUint64(p, BigInt(Math.floor(performance.now()*1e6)), true); return 0; },
        proc_exit: c => console.log('[WASI] exit:', c),
        random_get: (b, l) => { crypto.getRandomValues(new Uint8Array(mem(), b, l)); return 0; },
    };

    // ========================================================================
    // Main Loop
    // ========================================================================

    function frame(ts) {
        if (!running) return;
        wasm.instance.exports.setTime(Math.floor(ts));
        wasm.instance.exports.step();
        updateDisplay();
        updateLEDs();
        updateLog();
        requestAnimationFrame(frame);
    }

    // ========================================================================
    // Public API
    // ========================================================================

    return {
        /** Start the WebSim runtime. Call once after DOM is ready. */
        async start() {
            const status = document.getElementById('status');
            if (status) status.textContent = 'Loading WASM...';

            try {
                const imports = {
                    env: { consoleLog: (p, l) => console.log('[WASM]', decoder.decode(new Uint8Array(memory.buffer, p, l))) },
                    wasi_snapshot_preview1: wasiStubs,
                };

                const resp = await fetch('app.wasm');
                wasm = await WebAssembly.instantiate(await resp.arrayBuffer(), imports);
                memory = wasm.instance.exports.memory;

                initDisplay();
                initGlow();
                initLog();
                initInput();
                initRecorder();

                wasm.instance.exports.setTime(Math.floor(performance.now()));
                wasm.instance.exports.init();

                running = true;
                if (status) { status.textContent = 'Running'; status.classList.add('running'); }
                requestAnimationFrame(frame);
            } catch (err) {
                if (status) status.textContent = 'Error: ' + err.message;
                console.error('WebSim failed:', err);
            }
        }
    };
})();
