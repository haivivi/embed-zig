/**
 * WebSim — WASM Board Simulator Shell
 *
 * Loads a Zig-compiled WASM module and drives the simulation loop.
 * Uses typed accessor exports (getLedColor, getLogLinePtr, etc.)
 * instead of raw memory offsets — safe regardless of Zig struct layout.
 */

// ============================================================================
// WASM Module
// ============================================================================

let wasm = null;
let memory = null;
let running = false;

const decoder = new TextDecoder();

// ============================================================================
// UI Elements
// ============================================================================

const statusEl = document.getElementById('status');
const logContent = document.getElementById('logContent');
const btnBoot = document.getElementById('btnBoot');
const logClear = document.getElementById('logClear');

// ============================================================================
// Button Input
// ============================================================================

let buttonDown = false;

function setButton(pressed) {
    if (pressed === buttonDown) return;
    buttonDown = pressed;
    btnBoot.classList.toggle('pressed', pressed);
    if (wasm) {
        if (pressed) {
            wasm.instance.exports.buttonPress();
        } else {
            wasm.instance.exports.buttonRelease();
        }
    }
}

// Mouse events
btnBoot.addEventListener('mousedown', (e) => { e.preventDefault(); setButton(true); });
btnBoot.addEventListener('mouseup', () => setButton(false));
btnBoot.addEventListener('mouseleave', () => { if (buttonDown) setButton(false); });

// Touch events
btnBoot.addEventListener('touchstart', (e) => { e.preventDefault(); setButton(true); });
btnBoot.addEventListener('touchend', () => setButton(false));
btnBoot.addEventListener('touchcancel', () => setButton(false));

// Keyboard (Space)
document.addEventListener('keydown', (e) => {
    if (e.code === 'Space' && !e.repeat) { e.preventDefault(); setButton(true); }
});
document.addEventListener('keyup', (e) => {
    if (e.code === 'Space') { e.preventDefault(); setButton(false); }
});

// Log clear
logClear.addEventListener('click', () => { logContent.innerHTML = ''; });

// ============================================================================
// State Reading — LEDs (via typed exports)
// ============================================================================

function updateLEDs() {
    const ex = wasm.instance.exports;
    const ledCount = ex.getLedCount();
    const container = document.getElementById('ledContainer');

    // Ensure correct number of LED elements
    while (container.children.length < ledCount) {
        const led = document.createElement('div');
        led.className = 'led';
        led.id = `led-${container.children.length}`;
        container.appendChild(led);
    }

    for (let i = 0; i < ledCount; i++) {
        const packed = ex.getLedColor(i); // 0x00RRGGBB
        const r = (packed >> 16) & 0xFF;
        const g = (packed >> 8) & 0xFF;
        const b = packed & 0xFF;

        const el = container.children[i];
        const isLit = packed !== 0;

        if (isLit) {
            const color = `rgb(${r},${g},${b})`;
            el.classList.add('lit');
            el.style.background = color;
            el.style.setProperty('--led-color', color);
        } else {
            el.classList.remove('lit');
            el.style.background = '';
            el.style.removeProperty('--led-color');
        }
    }
}

// ============================================================================
// State Reading — Log (via typed exports)
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

    // Update DOM
    logContent.innerHTML = lines.map(line => {
        let cls = 'log-line';
        if (line.startsWith('[INFO]')) cls += ' info';
        else if (line.startsWith('[ERROR]')) cls += ' error';
        else if (line.startsWith('[WARN]')) cls += ' warn';
        return `<div class="${cls}">${escapeHtml(line)}</div>`;
    }).join('');

    // Auto-scroll to bottom
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

    // Update time in shared state
    ex.setTime(Math.floor(timestamp));

    // Step the simulation
    ex.step();

    // Read state and update UI
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
        // WASM imports (functions Zig can call)
        const importObject = {
            env: {
                consoleLog: (ptr, len) => {
                    const text = decoder.decode(
                        new Uint8Array(memory.buffer, ptr, len)
                    );
                    console.log('[WASM]', text);
                },
            },
        };

        const response = await fetch('app.wasm');
        const bytes = await response.arrayBuffer();
        wasm = await WebAssembly.instantiate(bytes, importObject);

        // Get memory reference
        memory = wasm.instance.exports.memory;

        // Initialize the app
        const ex = wasm.instance.exports;
        ex.setTime(Math.floor(performance.now()));
        ex.init();

        // Start simulation loop
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
