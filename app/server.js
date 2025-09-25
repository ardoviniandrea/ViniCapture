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
// --- NEW: FFmpeg Profile Management ---
// ================================================================

/**
 * Returns the default list of profiles if none exist.
 */
function getDefaultProfiles() {
    console.log('[DEBUG] [getDefaultProfiles] Generating default profiles in memory.');
    return [
        {
            "id": "default-nvenc",
            "name": "Default (NVIDIA NVENC)",
            "command": "ffmpeg -f x11grab -video_size 1920x1080 -framerate 30 -i :1.0+0,0 -f pulse -i default -c:v h264_nvenc -preset p6 -tune hq -b:v 6M -c:a aac -b:a 192k -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments+discont_start+omit_endlist -hls_segment_filename /var/www/hls/segment_%03d.ts /var/www/hls/live.m3u8",
            "active": true,
            "isDefault": true
        },
        {
            "id": "default-cpu",
            "name": "Default (CPU x264 - ultrafast)",
            "command": "ffmpeg -f x11grab -video_size 1920x1080 -framerate 30 -i :1.0+0,0 -f pulse -i default -c:v libx264 -preset ultrafast -tune zerolatency -b:v 6M -c:a aac -b:a 192k -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments+discont_start+omit_endlist -hls_segment_filename /var/www/hls/segment_%03d.ts /var/www/hls/live.m3u8",
            "active": false,
            "isDefault": true
        }
    ];
}

/**
 * Reads all profiles from the JSON file.
 */
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

/**
 * Saves the entire profiles object to the JSON file.
 * @param {object} profiles - The complete profiles object to save.
 */
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

/**
 * Gets the currently active profile.
 */
function getActiveProfile() {
    console.log('[DEBUG] [getActiveProfile] Getting all profiles to find active one...');
    const profiles = getProfiles();
    let activeProfile = profiles.find(p => p.active);
    if (!activeProfile) {
        console.warn('[DEBUG] [getActiveProfile] No active profile found. Falling back to first profile.');
        activeProfile = profiles[0]; // Fallback to first profile
        if (activeProfile) {
            console.log(`[DEBUG] [getActiveProfile] Setting profile "${activeProfile.name}" as active and resaving.`);
            activeProfile.active = true;
            saveProfiles(profiles); // Save the fallback state
        }
    }
    
    if (activeProfile) {
        console.log(`[DEBUG] [getActiveProfile] Found active profile: "${activeProfile.name}"`);
    } else {
         console.error('[ERROR] [getActiveProfile] No profiles found at all. Falling back to in-memory default.');
        activeProfile = getDefaultProfiles()[0]; // Ultimate fallback
    }
    return activeProfile;
}

// ================================================================
// --- API Endpoints (Updated) ---
// ================================================================

/**
 * API: Get current capture status
 */
app.get('/api/status', (req, res) => {
    const isRunning = (ffmpegProcess !== null);
    console.log(`[API] GET /api/status. Running: ${isRunning}`);
    res.json({
        running: isRunning
    });
});

/**
 * API: Start the FFmpeg capture
 * (NOW USES THE ACTIVE PROFILE)
 */
app.post('/api/start', (req, res) => {
    console.log('[API] POST /api/start received.');
    if (ffmpegProcess) {
        console.warn('[API] /api/start: Capture is already running. Sending 400.');
        return res.status(400).json({ error: 'Capture is already running' });
    }
    
    // 1. Clean up old files
    console.log('[API] /api/start: Cleaning up old stream files...');
    cleanupStreamFiles();

    // 2. Get the active profile command
    const activeProfile = getActiveProfile();
    if (!activeProfile || !activeProfile.command) {
        console.error('[API] /api/start: No active FFmpeg profile found or command is empty. Sending 500.');
        return res.status(500).json({ error: 'No active FFmpeg profile found or command is empty.' });
    }
    
    const commandString = activeProfile.command;

    // 3. Split command string into arguments, respecting quotes
    const args = (commandString.match(/(?:[^\s"]+|"[^"]*")+/g) || [])
                 .map(arg => arg.replace(/^"|"$/g, '')); // Remove surrounding quotes

    console.log(`[FFmpeg] Starting process with profile: ${activeProfile.name}`);
    console.log(`[FFmpeg] Full Command: ffmpeg ${args.join(' ')}`);

    // 4. Spawn the process
    try {
        ffmpegProcess = spawn('ffmpeg', args);
    } catch (spawnError) {
        console.error(`[FFmpeg] CRITICAL: Failed to spawn 'ffmpeg'. Is it installed? Error: ${spawnError.message}`);
        ffmpegProcess = null;
        return res.status(500).json({ error: `Failed to spawn ffmpeg: ${spawnError.message}`});
    }


    ffmpegProcess.stdout.on('data', (data) => {
        // console.log(`ffmpeg stdout: ${data}`); // Usually too noisy
    });

    ffmpegProcess.stderr.on('data', (data) => {
        const stderrStr = data.toString();
        // Filter out verbose frame/size logs
        if (!stderrStr.startsWith('frame=') && !stderrStr.startsWith('size=')) {
             console.error(`[ffmpeg stderr]: ${stderrStr.trim()}`);
        }
    });

    ffmpegProcess.on('close', (code) => {
        console.log(`[FFmpeg] process exited with code ${code}`);
        ffmpegProcess = null;
        if (code !== 0 && code !== 255) { // 255 is SIGKILL (from /stop)
            console.error('[FFmpeg] Process exited unexpectedly. Cleaning up.');
        }
        cleanupStreamFiles();
    });

    // --- THIS IS THE CORRECTED LINE ---
    // The previous version had a syntax error.
    ffmpegProcess.on('error', (err) => {
        console.error('[ffmpeg] Failed to start process:', err.message);
        ffmpegProcess = null;
    });
    // --- END OF FIX ---

    console.log('[API] /api/start: Start command issued. Sending 200.');
    res.json({ message: 'Capture started' });
});

/**
 * API: Stop the FFmpeg capture
 */
app.post('/api/stop', (req, res) => {
    console.log('[API] POST /api/stop received.');
    if (ffmpegProcess) {
        console.log('[API] /api/stop: Ffmpeg process found. Sending SIGKILL...');
        ffmpegProcess.kill('SIGKILL');
        ffmpegProcess = null;
        console.log('[API] /api/stop: Process killed. Sending 200.');
        res.json({ message: 'Capture stopped' });
    } else {
        console.warn('[API] /api/stop: Capture is not running. Sending 400.');
        res.status(400).json({ error: 'Capture is not running' });
    }
    // Clean up files after a short delay to ensure process is dead
    setTimeout(cleanupStreamFiles, 1000);
});

/**
 * NEW API: Get all profiles
 */
app.get('/api/profiles', (req, res) => {
    console.log('[API] GET /api/profiles received. Fetching profiles...');
    const profiles = getProfiles();
    console.log(`[API] /api/profiles: Sending ${profiles.length} profiles.`);
    res.json(profiles);
});

/**
 * NEW API: Save all profiles
 */
app.post('/api/profiles', (req, res) => {
    console.log('[API] POST /api/profiles received. Saving profiles...');
    const profiles = req.body;
    if (!Array.isArray(profiles)) {
        console.error('[API] /api/profiles: Invalid profiles data. Expected an array. Sending 400.');
        return res.status(400).json({ error: 'Invalid profiles data. Expected an array.' });
    }
    
    if (saveProfiles(profiles)) {
        console.log('[API] /api/profiles: Profiles saved. Sending 200.');
        res.json({ message: 'Profiles saved successfully' });
    } else {
        console.error('[API] /api/profiles: Failed to save profiles to disk. Sending 500.');
        res.status(500).json({ error: 'Failed to save profiles to disk.' });
    }
});


// Serve the index.html for the root route
app.get('/', (req, res) => {
    console.log(`[API] GET /: Serving index.html`);
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Nginx proxies to this port
app.listen(port, '127.0.0.1', () => {
    console.log(`ViniCapture API listening on http://127.0.0.1:${port}`);
});

