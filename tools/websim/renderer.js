/**
 * WebSim Board Renderer
 *
 * Dynamically generates board UI from a JSON config.
 * Uses fixed element IDs (contract for future custom HTML override).
 *
 * Element ID Contract:
 *   #board-name        — board name text
 *   #board-chip        — chip info text
 *   #status            — running/idle status badge
 *   #led-container     — LED parent div
 *   #led-{n}           — individual LED (0-indexed)
 *   #adc-btn-{n}       — ADC button (data-adc = value)
 *   #btn-boot          — boot button
 *   #btn-power         — power button
 *   #display-canvas    — LCD canvas (width/height from config)
 *   #mic-btn           — mic toggle
 *   #wifi-status       — WiFi status
 *   #ble-status        — BLE status
 *   #log-content       — log output
 */

function renderBoard(config) {
    var root = document.getElementById('board-root');
    if (!root) { root = document.body; }
    root.innerHTML = '';

    // Header: two rows — title on top, labels below
    var header = el('header', 'sim-header');
    var boardName = config.name || 'Unknown Board';
    var chipInfo = config.chip ? '<span class="chip-badge">' + config.chip + '</span>' : '';
    var targetInfo = config.target ? '<span class="target-badge">' + config.target + '</span>' : '';

    header.innerHTML =
        '<div class="header-top">' +
            '<h1 id="board-name">' + boardName + '</h1>' +
            '<div class="header-actions">' +
                '<button class="rec-btn" id="rec-btn">REC</button>' +
                '<span class="status running" id="status">Running</span>' +
                '<button class="close-btn" id="close-btn">&#10005;</button>' +
            '</div>' +
        '</div>' +
        '<div class="header-labels">' + chipInfo + targetInfo + '</div>';
    root.appendChild(header);

    // Board frame
    var board = el('div', 'board');

    // Display
    if (config.display) {
        var displayWrap = el('div', 'display-frame');
        var canvas = document.createElement('canvas');
        canvas.id = 'display-canvas';
        canvas.width = config.display.width || 240;
        canvas.height = config.display.height || 240;
        canvas.style.width = Math.min(canvas.width, 400) + 'px';
        canvas.style.height = Math.min(canvas.height, 400) + 'px';
        canvas.style.background = '#000';
        canvas.style.display = 'block';
        displayWrap.appendChild(canvas);
        board.appendChild(displayWrap);
    }

    // LEDs
    if (config.leds && config.leds.count > 0) {
        var ledGroup = el('div', 'component-group');
        ledGroup.appendChild(compLabel('LED Strip (' + config.leds.count + 'x)'));
        var ledContainer = el('div', 'leds');
        ledContainer.id = 'led-container';
        for (var i = 0; i < config.leds.count; i++) {
            var led = el('div', 'led');
            led.id = 'led-' + i;
            ledContainer.appendChild(led);
        }
        ledGroup.appendChild(ledContainer);
        board.appendChild(ledGroup);
    }

    // ADC Buttons
    if (config.buttons && config.buttons.adc && config.buttons.adc.length > 0) {
        var btnGroup = el('div', 'component-group');
        btnGroup.appendChild(compLabel('Buttons'));
        var btnRows = el('div', 'adc-buttons');
        var row = null;
        config.buttons.adc.forEach(function(btn, idx) {
            if (idx % 3 === 0) {
                row = el('div', 'btn-row');
                btnRows.appendChild(row);
            }
            var button = el('button', 'hw-button adc-btn');
            button.id = 'adc-btn-' + idx;
            button.dataset.adc = btn.value;
            button.innerHTML = '<span class="btn-inner">' + btn.name + '</span>';
            row.appendChild(button);
        });
        btnGroup.appendChild(btnRows);
        board.appendChild(btnGroup);
    }

    // Boot / Power buttons
    if (config.buttons) {
        var sysRow = el('div', 'btn-row');
        var hasSys = false;
        if (config.buttons.boot) {
            var bootBtn = el('button', 'hw-button boot-btn');
            bootBtn.id = 'btn-boot';
            bootBtn.innerHTML = '<span class="btn-inner">BOOT</span>';
            sysRow.appendChild(bootBtn);
            hasSys = true;
        }
        if (config.buttons.power) {
            var pwrBtn = el('button', 'hw-button power-btn');
            pwrBtn.id = 'btn-power';
            pwrBtn.innerHTML = '<span class="btn-inner">PWR</span>';
            sysRow.appendChild(pwrBtn);
            hasSys = true;
        }
        if (hasSys) {
            var sysGroup = el('div', 'component-group');
            sysGroup.appendChild(sysRow);
            board.appendChild(sysGroup);
        }
    }

    // Audio — permissions already acquired on waiting page.
    // Firmware controls mic start/stop through HAL, UI just shows status.
    if (config.audio && (config.audio.speaker || config.audio.mic)) {
        var audioGroup = el('div', 'component-group');
        audioGroup.appendChild(compLabel('Audio'));
        var audioStatus = el('div', 'audio-status');
        audioStatus.id = 'audio-status';
        audioStatus.textContent = 'Idle';
        audioGroup.appendChild(audioStatus);
        if (config.audio.speaker) {
            var vuWrap = el('div', 'vu-meter');
            vuWrap.id = 'speaker-vu';
            vuWrap.innerHTML = '<div class="vu-bar"></div>';
            audioGroup.appendChild(vuWrap);
        }
        board.appendChild(audioGroup);
    }

    root.appendChild(board);

    // Status row (WiFi / BLE)
    if (config.wifi || config.ble) {
        var statusRow = el('div', 'status-row');
        if (config.wifi) {
            var wifiEl = el('span', '');
            wifiEl.id = 'wifi-status';
            wifiEl.textContent = 'WiFi: -';
            statusRow.appendChild(wifiEl);
        }
        if (config.ble) {
            var bleEl = el('span', '');
            bleEl.id = 'ble-status';
            bleEl.textContent = 'BLE: -';
            statusRow.appendChild(bleEl);
        }
        root.appendChild(statusRow);
    }

    // Log panel
    var logPanel = el('div', 'log-panel');
    logPanel.innerHTML = '<div class="log-header"><span>Console</span>' +
        '<div class="log-actions">' +
        '<button class="log-btn" id="log-copy">Copy</button>' +
        '<button class="log-btn" id="log-clear">Clear</button>' +
        '</div></div>' +
        '<div class="log-content" id="log-content"></div>';
    root.appendChild(logPanel);

    // Bind log buttons
    var logCopy = document.getElementById('log-copy');
    var logClear = document.getElementById('log-clear');
    var logContent = document.getElementById('log-content');
    if (logClear) logClear.addEventListener('click', function() { logContent.innerHTML = ''; });
    if (logCopy) logCopy.addEventListener('click', function() {
        var ta = document.createElement('textarea');
        ta.value = logContent.innerText;
        ta.style.cssText = 'position:fixed;left:-9999px;';
        document.body.appendChild(ta); ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
        logCopy.textContent = 'Copied!';
        setTimeout(function() { logCopy.textContent = 'Copy'; }, 1000);
    });

    // Floating mic button (always visible, handles WebRTC permission)
    var micFloat = el('div', 'mic-float');
    micFloat.id = 'mic-float';
    micFloat.innerHTML = '&#127908;'; // microphone emoji
    micFloat.title = 'Click to enable microphone';
    root.appendChild(micFloat);

    var _micStream = null;
    var _micProcessor = null;
    micFloat.addEventListener('click', function() {
        if (_micStream) {
            // Stop mic
            _micStream.getTracks().forEach(function(t) { t.stop(); });
            _micStream = null;
            if (_micProcessor) { _micProcessor.disconnect(); _micProcessor = null; }
            micFloat.classList.remove('active');
            micFloat.title = 'Click to enable microphone';
        } else {
            // Start mic — MUST use shared AudioContext for AEC to work
            var ctx = window._sharedAudioCtx;
            if (!ctx) {
                ctx = new (window.AudioContext || window.webkitAudioContext)({sampleRate: 16000});
                window._sharedAudioCtx = ctx;
            }
            // Resume context (required after user gesture)
            if (ctx.state === 'suspended') ctx.resume();

            navigator.mediaDevices.getUserMedia({
                audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true, sampleRate: 16000}
            }).then(function(stream) {
                _micStream = stream;
                micFloat.classList.add('active');
                micFloat.classList.remove('denied');
                micFloat.title = 'Microphone active (click to stop)';

                var source = ctx.createMediaStreamSource(stream);
                _micProcessor = ctx.createScriptProcessor(256, 1, 1);
                _micProcessor.onaudioprocess = function(e) {
                    // Zero output to prevent mic passthrough to speaker
                    e.outputBuffer.getChannelData(0).fill(0);

                    if (!_wasm || !_wasm.instance) return;
                    var input = e.inputBuffer.getChannelData(0);
                    var ex = _wasm.instance.exports;
                    if (ex.pushAudioInSample) {
                        // Scale down mic input so firmware's gain (e.g. 16x) doesn't clip i16
                        for (var s = 0; s < input.length; s++) {
                            ex.pushAudioInSample(Math.max(-32768, Math.min(32767, Math.round(input[s] * 2000))));
                        }
                    }
                };
                source.connect(_micProcessor);
                // Must connect to destination for processing to work,
                // but output is zeroed above so no audio leak
                _micProcessor.connect(ctx.destination);
            }).catch(function(err) {
                micFloat.classList.add('denied');
                micFloat.title = 'Microphone denied: ' + err.message;
                // Show error in log panel
                var logEl = document.getElementById('log-content');
                if (logEl) logEl.innerHTML += '<div class="log-line error">[MIC] ' + err.name + ': ' + err.message + '</div>';
                console.error('[MIC]', err);
            });
        }
    });

    // Bind input handlers
    bindInputHandlers(config);

    // Close button — return to waiting page
    var closeBtn = document.getElementById('close-btn');
    if (closeBtn) {
        closeBtn.addEventListener('click', function() {
            _polling = false;
            if (typeof zigClose === 'function') {
                zigClose();
            } else {
                // Fallback: reload to go back to waiting page
                window.location.reload();
            }
        });
    }

    // REC button (placeholder — TODO: implement recording)
    var recBtn = document.getElementById('rec-btn');
    if (recBtn) {
        recBtn.addEventListener('click', function() {
            recBtn.textContent = recBtn.textContent === 'REC' ? 'STOP' : 'REC';
            recBtn.classList.toggle('recording');
        });
    }
}

function bindInputHandlers(config) {
    // ADC buttons
    var adcBtns = document.querySelectorAll('.adc-btn');
    var activeAdc = null;
    // Helper: call WASM export if available
    function wasmCall(name, arg) {
        if (_wasm && _wasm.instance && _wasm.instance.exports[name]) {
            if (arg !== undefined) _wasm.instance.exports[name](arg);
            else _wasm.instance.exports[name]();
        }
    }

    adcBtns.forEach(function(btn) {
        btn.addEventListener('mousedown', function(e) {
            e.preventDefault();
            if (activeAdc && activeAdc !== btn) activeAdc.classList.remove('pressed');
            activeAdc = btn; btn.classList.add('pressed');
            wasmCall('setAdcValue', parseInt(btn.dataset.adc));
        });
        btn.addEventListener('mouseup', function() {
            if (activeAdc === btn) activeAdc = null;
            btn.classList.remove('pressed');
            wasmCall('setAdcValue', 4095);
        });
        btn.addEventListener('mouseleave', function() {
            if (activeAdc === btn) { activeAdc = null; btn.classList.remove('pressed');
                wasmCall('setAdcValue', 4095); }
        });
    });

    var bootBtn = document.getElementById('btn-boot');
    if (bootBtn) {
        bootBtn.addEventListener('mousedown', function(e) { e.preventDefault(); bootBtn.classList.add('pressed');
            wasmCall('buttonPress'); });
        bootBtn.addEventListener('mouseup', function() { bootBtn.classList.remove('pressed');
            wasmCall('buttonRelease'); });
    }

    var pwrBtn = document.getElementById('btn-power');
    if (pwrBtn) {
        pwrBtn.addEventListener('mousedown', function(e) { e.preventDefault(); pwrBtn.classList.add('pressed');
            wasmCall('powerPress'); });
        pwrBtn.addEventListener('mouseup', function() { pwrBtn.classList.remove('pressed');
            wasmCall('powerRelease'); });
    }

    document.addEventListener('keydown', function(e) {
        if (e.repeat) return;
        if (e.code === 'Space' && bootBtn) { e.preventDefault(); bootBtn.classList.add('pressed');
            wasmCall('buttonPress'); }
    });
    document.addEventListener('keyup', function(e) {
        if (e.code === 'Space' && bootBtn) { e.preventDefault(); bootBtn.classList.remove('pressed');
            wasmCall('buttonRelease'); }
    });
}

// Note: state polling removed — WASM firmware drives the frame loop directly
// via requestAnimationFrame in board_template.html's loadWasmFirmware()

// Helpers
function el(tag, cls) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    return e;
}
function compLabel(text) {
    var e = el('div', 'component-label');
    e.textContent = text;
    return e;
}
