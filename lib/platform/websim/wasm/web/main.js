/**
 * WebSim — WASM Board Simulator Shell
 *
 * Loads a Zig-compiled WASM module and drives the simulation loop.
 * Supports: display canvas, LED, ADC button group, power button, log.
 */

let wasm = null;
let memory = null;
let running = false;
let canvasCtx = null;
let imageData = null;

/** Get WASM memory buffer (lazy — works during _start before memory is set) */
function mem() {
    if (memory) return memory.buffer;
    if (wasm) return wasm.instance.exports.memory.buffer;
    return new ArrayBuffer(0);
}

const decoder = new TextDecoder();

// ============================================================================
// UI Elements
// ============================================================================

const statusEl = document.getElementById('status');
const logContent = document.getElementById('logContent');
const logClear = document.getElementById('logClear');
const displayCanvas = document.getElementById('displayCanvas');
const btnPower = document.getElementById('btnPower');
const btnBoot = document.getElementById('btnBoot');

// ============================================================================
// ADC Button Group Input
// ============================================================================

const adcButtons = document.querySelectorAll('.adc-btn');
let activeAdcBtn = null;

function setAdcButton(btn, pressed) {
    if (!wasm) return;
    const ex = wasm.instance.exports;

    if (pressed) {
        // Release previous button if any
        if (activeAdcBtn && activeAdcBtn !== btn) {
            activeAdcBtn.classList.remove('pressed');
        }
        activeAdcBtn = btn;
        btn.classList.add('pressed');
        const adcValue = parseInt(btn.dataset.adc);
        ex.setAdcValue(adcValue);
    } else {
        if (activeAdcBtn === btn) {
            activeAdcBtn = null;
        }
        btn.classList.remove('pressed');
        ex.setAdcValue(4095); // No button pressed
    }
}

adcButtons.forEach(btn => {
    btn.addEventListener('mousedown', (e) => { e.preventDefault(); setAdcButton(btn, true); });
    btn.addEventListener('mouseup', () => setAdcButton(btn, false));
    btn.addEventListener('mouseleave', () => { if (activeAdcBtn === btn) setAdcButton(btn, false); });
    btn.addEventListener('touchstart', (e) => { e.preventDefault(); setAdcButton(btn, true); });
    btn.addEventListener('touchend', () => setAdcButton(btn, false));
    btn.addEventListener('touchcancel', () => setAdcButton(btn, false));
});

// Keyboard shortcuts for ADC buttons
const keyMap = {
    'ArrowUp': 200,     // vol+
    'ArrowDown': 500,    // vol-
    'ArrowLeft': 800,    // left
    'ArrowRight': 1100,  // right
    'Escape': 1400,      // back
    'Enter': 1700,       // confirm
    'KeyR': 2000,        // rec
};

document.addEventListener('keydown', (e) => {
    if (e.repeat) return;
    const adcVal = keyMap[e.code];
    if (adcVal !== undefined && wasm) {
        e.preventDefault();
        wasm.instance.exports.setAdcValue(adcVal);
        // Highlight corresponding button
        adcButtons.forEach(btn => {
            if (parseInt(btn.dataset.adc) === adcVal) btn.classList.add('pressed');
        });
    }
    // Space = power button (H106) or BOOT button (DevKit)
    if (e.code === 'Space') {
        e.preventDefault();
        if (btnPower) setPowerButton(true);
        else if (btnBoot) setBootButton(true);
    }
});

document.addEventListener('keyup', (e) => {
    const adcVal = keyMap[e.code];
    if (adcVal !== undefined && wasm) {
        e.preventDefault();
        wasm.instance.exports.setAdcValue(4095);
        adcButtons.forEach(btn => {
            if (parseInt(btn.dataset.adc) === adcVal) btn.classList.remove('pressed');
        });
    }
    if (e.code === 'Space') {
        e.preventDefault();
        if (btnPower) setPowerButton(false);
        else if (btnBoot) setBootButton(false);
    }
});

// ============================================================================
// Power Button Input
// ============================================================================

// Power button (H106 board)
function setPowerButton(pressed) {
    if (!wasm) return;
    if (btnPower) btnPower.classList.toggle('pressed', pressed);
    if (pressed) {
        wasm.instance.exports.powerPress();
    } else {
        wasm.instance.exports.powerRelease();
    }
}

if (btnPower) {
    btnPower.addEventListener('mousedown', (e) => { e.preventDefault(); setPowerButton(true); });
    btnPower.addEventListener('mouseup', () => setPowerButton(false));
    btnPower.addEventListener('mouseleave', () => setPowerButton(false));
    btnPower.addEventListener('touchstart', (e) => { e.preventDefault(); setPowerButton(true); });
    btnPower.addEventListener('touchend', () => setPowerButton(false));
    btnPower.addEventListener('touchcancel', () => setPowerButton(false));
}

// BOOT button (ESP32 DevKit board)
function setBootButton(pressed) {
    if (!wasm) return;
    if (btnBoot) btnBoot.classList.toggle('pressed', pressed);
    if (pressed) {
        wasm.instance.exports.buttonPress();
    } else {
        wasm.instance.exports.buttonRelease();
    }
}

if (btnBoot) {
    btnBoot.addEventListener('mousedown', (e) => { e.preventDefault(); setBootButton(true); });
    btnBoot.addEventListener('mouseup', () => setBootButton(false));
    btnBoot.addEventListener('mouseleave', () => { if (btnBoot.classList.contains('pressed')) setBootButton(false); });
    btnBoot.addEventListener('touchstart', (e) => { e.preventDefault(); setBootButton(true); });
    btnBoot.addEventListener('touchend', () => setBootButton(false));
    btnBoot.addEventListener('touchcancel', () => setBootButton(false));
}

// Log clear
logClear.addEventListener('click', () => { logContent.innerHTML = ''; });

// Log copy
const logCopy = document.getElementById('logCopy');
if (logCopy) {
    logCopy.addEventListener('click', () => {
        const text = logContent.innerText;
        navigator.clipboard.writeText(text).then(() => {
            logCopy.textContent = 'Copied!';
            setTimeout(() => { logCopy.textContent = 'Copy'; }, 1000);
        });
    });
}

// ============================================================================
// Display Canvas (240x240 RGB565)
// ============================================================================

function initCanvas() {
    canvasCtx = displayCanvas.getContext('2d');
    imageData = canvasCtx.createImageData(240, 240);
}

function updateDisplay() {
    const ex = wasm.instance.exports;
    if (!ex.getDisplayDirty()) return;
    ex.clearDisplayDirty();

    const fbPtr = ex.getDisplayFbPtr();
    const fbSize = ex.getDisplayFbSize();
    const width = ex.getDisplayWidth();
    const height = ex.getDisplayHeight();

    // Read RGB565 framebuffer from WASM memory and convert to RGBA
    const fb = new Uint8Array(memory.buffer, fbPtr, fbSize);
    const rgba = imageData.data;

    for (let i = 0; i < width * height; i++) {
        // RGB565: RRRRRGGGGGGBBBBB (little-endian: low byte first)
        const lo = fb[i * 2];
        const hi = fb[i * 2 + 1];
        const rgb565 = (hi << 8) | lo;

        const r = (rgb565 >> 11) & 0x1F;
        const g = (rgb565 >> 5) & 0x3F;
        const b = rgb565 & 0x1F;

        rgba[i * 4] = (r * 255 / 31) | 0;
        rgba[i * 4 + 1] = (g * 255 / 63) | 0;
        rgba[i * 4 + 2] = (b * 255 / 31) | 0;
        rgba[i * 4 + 3] = 255;
    }

    canvasCtx.putImageData(imageData, 0, 0);
}

// ============================================================================
// LED State
// ============================================================================

// ============================================================================
// LED Glow Renderer (canvas-based diffuse light through plastic dome)
// ============================================================================

// Diamond layout positions: 1-2-3-2-1 = 9 LEDs
// Coordinates are normalized (0-1) within the dome oval
const LED_POSITIONS = [
    // Row 0: 1 LED
    { x: 0.50, y: 0.20 },
    // Row 1: 2 LEDs
    { x: 0.35, y: 0.35 }, { x: 0.65, y: 0.35 },
    // Row 2: 3 LEDs
    { x: 0.22, y: 0.50 }, { x: 0.50, y: 0.50 }, { x: 0.78, y: 0.50 },
    // Row 3: 2 LEDs
    { x: 0.35, y: 0.65 }, { x: 0.65, y: 0.65 },
    // Row 4: 1 LED
    { x: 0.50, y: 0.80 },
];

let glowCtx = null;
let glowCanvas = null;

function initGlow() {
    glowCanvas = document.getElementById('ledGlowCanvas');
    if (glowCanvas) {
        glowCtx = glowCanvas.getContext('2d');
    }
}

function updateLEDs() {
    if (!glowCtx || !wasm) return;

    const ex = wasm.instance.exports;
    const ledCount = Math.min(ex.getLedCount(), LED_POSITIONS.length);
    const w = glowCanvas.width;
    const h = glowCanvas.height;

    // Clear
    glowCtx.clearRect(0, 0, w, h);

    // Draw each LED as a soft radial gradient
    for (let i = 0; i < ledCount; i++) {
        const packed = ex.getLedColor(i);
        if (packed === 0) continue;

        const r = (packed >> 16) & 0xFF;
        const g = (packed >> 8) & 0xFF;
        const b = packed & 0xFF;

        const pos = LED_POSITIONS[i];
        const cx = pos.x * w;
        const cy = pos.y * h;
        const radius = w * 0.35; // large glow radius for diffusion

        const grad = glowCtx.createRadialGradient(cx, cy, 0, cx, cy, radius);
        grad.addColorStop(0, `rgba(${r},${g},${b},0.9)`);
        grad.addColorStop(0.15, `rgba(${r},${g},${b},0.5)`);
        grad.addColorStop(0.5, `rgba(${r},${g},${b},0.15)`);
        grad.addColorStop(1, `rgba(${r},${g},${b},0)`);

        glowCtx.fillStyle = grad;
        glowCtx.fillRect(0, 0, w, h);

        // Bright core (the LED chip itself)
        const coreGrad = glowCtx.createRadialGradient(cx, cy, 0, cx, cy, 4);
        coreGrad.addColorStop(0, `rgba(255,255,255,0.8)`);
        coreGrad.addColorStop(0.5, `rgba(${r},${g},${b},0.6)`);
        coreGrad.addColorStop(1, `rgba(${r},${g},${b},0)`);

        glowCtx.fillStyle = coreGrad;
        glowCtx.fillRect(cx - 6, cy - 6, 12, 12);
    }
}

// ============================================================================
// Log
// ============================================================================

function updateLog() {
    const ex = wasm.instance.exports;
    if (!ex.getLogDirty()) return;
    ex.clearLogDirty();

    const logCount = ex.getLogCount();
    const total = Math.min(logCount, 32);
    const lines = [];

    for (let i = 0; i < total; i++) {
        const len = ex.getLogLineLen(i);
        if (len > 0) {
            const ptr = ex.getLogLinePtr(i);
            const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
            lines.push(text);
        }
    }

    logContent.innerHTML = lines.map(line => {
        let cls = 'log-line';
        if (line.startsWith('[INFO]')) cls += ' info';
        else if (line.startsWith('[ERROR]')) cls += ' error';
        else if (line.startsWith('[WARN]')) cls += ' warn';
        return `<div class="${cls}">${escapeHtml(line)}</div>`;
    }).join('');

    logContent.scrollTop = logContent.scrollHeight;
}

function escapeHtml(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ============================================================================
// Main Loop
// ============================================================================

function frame(timestamp) {
    if (!running) return;
    const ex = wasm.instance.exports;

    ex.setTime(Math.floor(timestamp));
    ex.step();

    updateDisplay();
    updateLEDs();
    updateLog();

    requestAnimationFrame(frame);
}

// ============================================================================
// WASM Loading
// ============================================================================

async function main() {
    statusEl.textContent = 'Loading WASM...';

    try {
        const importObject = {
            env: {
                consoleLog: (ptr, len) => {
                    const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
                    console.log('[WASM]', text);
                },
            },
            // WASI stubs — wasm32-wasi-musl requires these imports at runtime.
            // We only use WASI for libc headers at compile time, so these are no-ops.
            // Note: memory is accessed via mem() since it's not yet set during _start.
            wasi_snapshot_preview1: {
                fd_write: () => 0,
                fd_read: () => 0,
                fd_close: () => 0,
                fd_seek: () => 0,
                fd_fdstat_get: () => 0,
                fd_prestat_get: () => 8,
                fd_prestat_dir_name: () => 8,
                environ_get: () => 0,
                environ_sizes_get: (count_ptr, size_ptr) => {
                    const v = new DataView(mem());
                    v.setUint32(count_ptr, 0, true);
                    v.setUint32(size_ptr, 0, true);
                    return 0;
                },
                args_get: () => 0,
                args_sizes_get: (argc_ptr, size_ptr) => {
                    const v = new DataView(mem());
                    v.setUint32(argc_ptr, 0, true);
                    v.setUint32(size_ptr, 0, true);
                    return 0;
                },
                clock_time_get: (id, precision, time_ptr) => {
                    const v = new DataView(mem());
                    v.setBigUint64(time_ptr, BigInt(Math.floor(performance.now() * 1e6)), true);
                    return 0;
                },
                proc_exit: (code) => console.log('[WASI] exit:', code),
                random_get: (buf, len) => {
                    crypto.getRandomValues(new Uint8Array(mem(), buf, len));
                    return 0;
                },
            },
        };

        const response = await fetch('app.wasm');
        const bytes = await response.arrayBuffer();
        wasm = await WebAssembly.instantiate(bytes, importObject);

        memory = wasm.instance.exports.memory;

        initCanvas();
        initGlow();

        const ex = wasm.instance.exports;
        ex.setTime(Math.floor(performance.now()));
        ex.init();

        running = true;
        statusEl.textContent = 'Running';
        statusEl.classList.add('running');
        requestAnimationFrame(frame);

    } catch (err) {
        statusEl.textContent = 'Error: ' + err.message;
        console.error('WebSim load failed:', err);
    }
}

main();
