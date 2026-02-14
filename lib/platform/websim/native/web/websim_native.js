/**
 * WebSim Native SDK — webview-based board simulator runtime.
 *
 * Same UI as the WASM version, but communicates with native Zig via
 * webview bindings instead of WASM exports.
 *
 * Standard element IDs (all optional — features auto-detect):
 *   #status           — status badge
 *   #displayCanvas    — LVGL display (RGB565)
 *   #ledGlowCanvas    — LED glow rendering canvas
 *   #ledContainer     — LED DOM container (fallback if no glow canvas)
 *   .adc-btn          — ADC buttons (data-adc="200" etc.)
 *   #btnPower         — power button
 *   #btnBoot          — boot button
 *   #logContent       — log output area
 *   #logClear         — clear log button
 *   #logCopy          — copy log button
 *   #logAutoScroll    — auto-scroll toggle
 */

const WebSim = (() => {
    let running = false;
    let currentState = {};

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

    function updateLEDs(state) {
        const leds = state.leds;
        const count = state.led_count || 0;
        if (!leds) return;

        if (glowCtx) {
            const w = glowCanvas.width, h = glowCanvas.height;
            glowCtx.clearRect(0, 0, w, h);
            for (let i = 0; i < Math.min(count, LED_POSITIONS.length); i++) {
                const packed = leds[i];
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
            const container = document.getElementById('ledContainer');
            if (!container) return;
            while (container.children.length < count) {
                const d = document.createElement('div');
                d.className = 'led';
                container.appendChild(d);
            }
            for (let i = 0; i < count; i++) {
                const packed = leds[i];
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

    function updateLog(state) {
        if (!state.log_dirty) return;
        const content = document.getElementById('logContent');
        if (!content || !state.logs) return;

        content.innerHTML = state.logs.map(l => {
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
            if (pressed) {
                if (activeAdc && activeAdc !== btn) activeAdc.classList.remove('pressed');
                activeAdc = btn;
                btn.classList.add('pressed');
                zigSetAdcValue(parseInt(btn.dataset.adc));
            } else {
                if (activeAdc === btn) activeAdc = null;
                btn.classList.remove('pressed');
                zigSetAdcValue(4095);
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

        const btnPower = document.getElementById('btnPower');
        const btnBoot = document.getElementById('btnBoot');

        function bindBtn(el, pressFn, releaseFn) {
            if (!el) return;
            const down = () => { el.classList.add('pressed'); pressFn(); };
            const up = () => { el.classList.remove('pressed'); releaseFn(); };
            el.addEventListener('mousedown', e => { e.preventDefault(); down(); });
            el.addEventListener('mouseup', up);
            el.addEventListener('mouseleave', () => { if (el.classList.contains('pressed')) up(); });
            el.addEventListener('touchstart', e => { e.preventDefault(); down(); });
            el.addEventListener('touchend', up);
            el.addEventListener('touchcancel', up);
        }

        bindBtn(btnPower, zigPowerPress, zigPowerRelease);
        bindBtn(btnBoot, zigButtonPress, zigButtonRelease);

        // Keyboard
        const keyMap = {
            'ArrowUp':200, 'ArrowDown':500, 'ArrowLeft':800, 'ArrowRight':1100,
            'Escape':1400, 'Enter':1700, 'KeyR':2000,
        };

        document.addEventListener('keydown', e => {
            if (e.repeat) return;
            const v = keyMap[e.code];
            if (v !== undefined) {
                e.preventDefault();
                zigSetAdcValue(v);
                adcBtns.forEach(b => { if (parseInt(b.dataset.adc) === v) b.classList.add('pressed'); });
            }
            if (e.code === 'Space') {
                e.preventDefault();
                if (btnPower) { btnPower.classList.add('pressed'); zigPowerPress(); }
                else if (btnBoot) { btnBoot.classList.add('pressed'); zigButtonPress(); }
            }
        });

        document.addEventListener('keyup', e => {
            const v = keyMap[e.code];
            if (v !== undefined) {
                e.preventDefault();
                zigSetAdcValue(4095);
                adcBtns.forEach(b => { if (parseInt(b.dataset.adc) === v) b.classList.remove('pressed'); });
            }
            if (e.code === 'Space') {
                e.preventDefault();
                if (btnPower) { btnPower.classList.remove('pressed'); zigPowerRelease(); }
                else if (btnBoot) { btnBoot.classList.remove('pressed'); zigButtonRelease(); }
            }
        });
    }

    // ========================================================================
    // WiFi / Net Status
    // ========================================================================

    function initWifiStatus() {
        const btn = document.getElementById('wifiDisconnectBtn');
        if (btn) btn.addEventListener('click', () => zigWifiForceDisconnect());
    }

    function updateWifiStatus(state) {
        const wifiEl = document.getElementById('wifiStatus');
        const ipEl = document.getElementById('ipStatus');
        if (!wifiEl && !ipEl) return;

        if (wifiEl) {
            if (state.wifi_connected) {
                const ssid = state.wifi_ssid || '';
                const rssi = state.wifi_rssi || 0;
                wifiEl.textContent = `WiFi: ${ssid} (${rssi} dBm)`;
                wifiEl.classList.add('connected');
                wifiEl.classList.remove('disconnected');
            } else {
                wifiEl.textContent = 'WiFi: disconnected';
                wifiEl.classList.remove('connected');
                wifiEl.classList.add('disconnected');
            }
        }

        if (ipEl) {
            if (state.net_has_ip) {
                ipEl.textContent = `IP: ${state.net_ip || '—'}`;
                ipEl.classList.add('has-ip');
            } else {
                ipEl.textContent = 'IP: —';
                ipEl.classList.remove('has-ip');
            }
        }
    }

    // ========================================================================
    // BLE Status
    // ========================================================================
    const BLE_STATES = ['uninit', 'idle', 'adv', 'scan', 'connecting', 'connected'];

    function initBleStatus() {
        const connectBtn = document.getElementById('bleConnectBtn');
        const disconnectBtn = document.getElementById('bleDisconnectBtn');
        if (connectBtn) connectBtn.addEventListener('click', () => zigBleSimConnect());
        if (disconnectBtn) disconnectBtn.addEventListener('click', () => zigBleSimDisconnect());
    }

    function updateBleStatus(state) {
        const bleEl = document.getElementById('bleStatus');
        if (!bleEl) return;
        const stateName = BLE_STATES[state.ble_state] || 'unknown';
        bleEl.textContent = `BLE: ${stateName}`;
        bleEl.classList.toggle('connected', !!state.ble_connected);
        bleEl.classList.toggle('advertising', stateName === 'adv');
    }

    // ========================================================================
    // Main Loop — polls Zig state via webview binding
    // ========================================================================

    async function frame() {
        if (!running) return;
        try {
            const state = await zigGetState();
            if (state) {
                currentState = state;
                updateLEDs(state);
                updateLog(state);
                updateWifiStatus(state);
                updateBleStatus(state);
            }
        } catch(e) {
            console.warn('WebSim: state poll error:', e);
        }
        requestAnimationFrame(frame);
    }

    // ========================================================================
    // Public API
    // ========================================================================

    return {
        start() {
            const status = document.getElementById('status');

            initDisplay();
            initGlow();
            initLog();
            initInput();
            initWifiStatus();
            initBleStatus();

            running = true;
            if (status) { status.textContent = 'Running'; status.classList.add('running'); }
            requestAnimationFrame(frame);
        }
    };
})();

// Auto-start when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => WebSim.start());
} else {
    WebSim.start();
}
