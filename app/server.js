// --- DEBUG: Log on startup ---
console.log('---------------------------------');
console.log('ViniCapture API server.js starting...');
console.log(`[DEBUG] process.env.DISPLAY = ${process.env.DISPLAY}`);
console.log('---------------------------------');

const express = require('express');
const cors = require('cors');
const { spawn, exec } = require('child_process');
const path = require('path');
const fs = require('fs'); // Added for profile management

const app = express();
const port = 3000;

app.use(cors());
app.use(express.json()); // Added to parse JSON request bodies
app.use(express.static(path.join(__dirname, 'public')));

// --- Persistent Storage Setup ---
const HLS_DIR = '/var/www/hls';
const DATA_DIR = '/data'; // Persistent volume
const PROFILES_PATH = path.join(DATA_DIR, 'profiles.json');

let ffmpegProcess = null;

// --- Helper Functions ---

/**
 * Cleans up all generated stream files.
 */
function cleanupStreamFiles() {
    console.log('[DEBUG] [cleanupStreamFiles] Attempting to clear HLS directory...');
    try {
        const files = fs.readdirSync(HLS_DIR);
        let cleanedCount = 0;
        for (const file of files) {
            if (file.endsWith('.ts') || file.endsWith('.m3u8')) {
                fs.unlinkSync(path.join(HLS_DIR, file));
                cleanedCount++;
            }
        }
        console.log(`[DEBUG] [cleanupStreamFiles] HLS directory cleared. Removed ${cleanedCount} files.`);
    } catch (e) {
        console.error('[ERROR] [cleanupStreamFiles] Error during file cleanup:', e.message);
    }
}

// ================================================================
// --- FFmpeg Profile Management ---
// ================================================================

function getDefaultProfiles() {
    console.log('[DEBUG] [getDefaultProfiles] Generating default profiles in memory.');
    return [
        {
            "id": "default-nvenc",
            "name": "Default (NVIDIA NVENC)",
            "command": "-f x11grab -video_size 1920x1080 -framerate 30 -i :1.0+0,0 -f pulse -i default -c:v h264_nvenc -preset p6 -tune hq -b:v 6M -c:a aac -b:a 192k -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments+discont_start+omit_endlist -hls_segment_filename /var/www/hls/segment_%03d.ts /var/www/hls/live.m3u8",
            "active": true,
            "isDefault": true
        },
        {
            "id": "default-cpu",
            "name": "Default (CPU x264 - ultrafast)",
            "command": "-f x11grab -video_size 1920x1080 -framerate 30 -i :1.0+0,0 -f pulse -i default -c:v libx264 -preset ultrafast -tune zerolatency -b:v 6M -c:a aac -b:a 192k -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments+discont_start+omit_endlist -hls_segment_filename /var/www/hls/segment_%03d.ts /var/www/hls/live.m3u8",
            "active": false,
            "isDefault": true
        }
    ];
}

function getProfiles() {
    console.log(`[DEBUG] [getProfiles] Checking for profiles file at: ${PROFILES_PATH}`);
    if (!fs.existsSync(PROFILES_PATH)) {
        console.log('[DEBUG] [getProfiles] Profiles file not found. Creating default profiles file...');
        try {
            const defaults = getDefaultProfiles();
            fs.writeFileSync(PROFILES_PATH, JSON.stringify(defaults, null, 2));
            console.log('[DEBUG] [getProfiles] Default profiles file created.');
            return defaults;
        } catch (e) {
            console.error("[ERROR] [getProfiles] Failed to write default profiles:", e);
            return getDefaultProfiles(); // Return from memory
        }
    }
    try {
        console.log('[DEBUG] [getProfiles] Profiles file found. Reading and parsing...');
        const profilesData = fs.readFileSync(PROFILES_PATH, 'utf8');
        const profiles = JSON.parse(profilesData);
        console.log(`[DEBUG] [getProfiles] Successfully parsed ${profiles.length} profiles.`);
        return profiles;
    } catch (e) {
        console.error("[ERROR] [getProfiles] Failed to parse profiles.json, returning defaults:", e);
        return getDefaultProfiles(); // Return from memory
    }
}

function saveProfiles(profiles) {
    console.log(`[DEBUG] [saveProfiles] Attempting to save ${profiles.length} profiles to ${PROFILES_PATH}`);
    try {
        fs.writeFileSync(PROFILES_PATH, JSON.stringify(profiles, null, 2));
        console.log('[DEBUG] [saveProfiles] Profiles saved successfully.');
        return true;
    } catch (e) {
        console.error("[ERROR] [saveProfiles] Failed to save profiles:", e);
        return false;
    }
}

function getActiveProfile() {
    console.log('[DEBUG] [getActiveProfile] Getting all profiles to find active one...');
    const profiles = getProfiles();
    let activeProfile = profiles.find(p => p.active);
    if (!activeProfile) {
        console.warn('[DEBUG] [getActiveProfile] No active profile found. Falling back to first profile.');
        activeProfile = profiles[0];
        if (activeProfile) {
            console.log(`[DEBUG] [getActiveProfile] Setting profile "${activeProfile.name}" as active and resaving.`);
            activeProfile.active = true;
            saveProfiles(profiles);
        }
    }
    
    if (activeProfile) {
        console.log(`[DEBUG] [getActiveProfile] Found active profile: "${activeProfile.name}"`);
    } else {
         console.error('[ERROR] [getActiveProfile] No profiles found at all. Falling back to in-memory default.');
        activeProfile = getDefaultProfiles()[0];
    }
    return activeProfile;
}

// ================================================================
// --- API Endpoints ---
// ================================================================

app.get('/api/status', (req, res) => {
    const isRunning = (ffmpegProcess !== null);
    console.log(`[API] GET /api/status. Running: ${isRunning}`);
    res.json({ running: isRunning });
});

app.post('/api/start', (req, res) => {
    console.log('[API] POST /api/start received.');
    if (ffmpegProcess) {
        return res.status(400).json({ error: 'Capture is already running' });
    }
    
    cleanupStreamFiles();

    const activeProfile = getActiveProfile();
    if (!activeProfile || !activeProfile.command) {
        return res.status(500).json({ error: 'No active FFmpeg profile found or command is empty.' });
    }
    
    const commandString = activeProfile.command;
    const args = (commandString.match(/(?:[^\s"]+|"[^"]*")+/g) || []).map(arg => arg.replace(/^"|"$/g, ''));

    console.log(`[FFmpeg] Starting process with profile: ${activeProfile.name}`);
    console.log(`[FFmpeg] Full Command: ffmpeg ${args.join(' ')}`);

    try {
        ffmpegProcess = spawn('ffmpeg', args);
    } catch (spawnError) {
        console.error(`[FFmpeg] CRITICAL: Failed to spawn 'ffmpeg'. Is it installed? Error: ${spawnError.message}`);
        ffmpegProcess = null;
        return res.status(500).json({ error: `Failed to spawn ffmpeg: ${spawnError.message}`});
    }

    ffmpegProcess.stderr.on('data', (data) => {
        const stderrStr = data.toString();
        if (!stderrStr.startsWith('frame=') && !stderrStr.startsWith('size=')) {
             console.error(`[ffmpeg stderr]: ${stderrStr.trim()}`);
        }
    });

    ffmpegProcess.on('close', (code) => {
        console.log(`[FFmpeg] process exited with code ${code}`);
        ffmpegProcess = null;
        if (code !== 0 && code !== 255) {
            console.error('[FFmpeg] Process exited unexpectedly. Cleaning up.');
        }
        cleanupStreamFiles();
    });
    
    ffmpegProcess.on('error', (err) => {
        console.error('[ffmpeg] Failed to start process:', err.message);
        ffmpegProcess = null;
    });

    res.json({ message: 'Capture started' });
});

app.post('/api/stop', (req, res) => {
    console.log('[API] POST /api/stop received.');
    if (ffmpegProcess) {
        ffmpegProcess.kill('SIGKILL');
        ffmpegProcess = null;
        res.json({ message: 'Capture stopped' });
    } else {
        res.status(400).json({ error: 'Capture is not running' });
    }
    setTimeout(cleanupStreamFiles, 1000);
});

app.get('/api/profiles', (req, res) => {
    const profiles = getProfiles();
    res.json(profiles);
});

app.post('/api/profiles', (req, res) => {
    const profiles = req.body;
    if (!Array.isArray(profiles)) {
        return res.status(400).json({ error: 'Invalid profiles data. Expected an array.' });
    }
    
    if (saveProfiles(profiles)) {
        res.json({ message: 'Profiles saved successfully' });
    } else {
        res.status(500).json({ error: 'Failed to save profiles to disk.' });
    }
});

// --- NEW DEBUGGING ENDPOINT ---
/**
 * Checks for running VNC processes inside the container.
 */
app.get('/api/debug-vnc', (req, res) => {
    console.log('[API] GET /api/debug-vnc received. Checking VNC process status...');
    // Use `ps` to find processes related to kasmvnc or its underlying Xvnc server
    exec("ps aux | grep -E 'kasmvnc|Xvnc' | grep -v grep", (error, stdout, stderr) => {
        if (error) {
            // This case is hit when grep finds no matches, which means the process isn't running.
            console.log('[API] /api/debug-vnc: No VNC processes found.');
            res.status(200).json({
                message: "No running VNC processes found.",
                running: false,
                stdout: stdout,
                stderr: stderr,
                errorCode: error.code
            });
            return;
        }
        if (stderr) {
             console.warn('[API] /api/debug-vnc: Stderr from process check:', stderr);
        }
        console.log('[API] /api/debug-vnc: Found running VNC process(es).');
        res.status(200).json({
            message: "VNC process(es) appear to be running.",
            running: true,
            // Split the output into an array of strings for easier reading
            processes: stdout.split('\n').filter(line => line.length > 0)
        });
    });
});
// --- END OF NEW ENDPOINT ---


app.get('/', (req, res) => {
    console.log(`[API] GET /: Serving index.html`);
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(port, '127.0.0.1', () => {
    console.log(`ViniCapture API listening on http://127.0.0.1:${port}`);
});
