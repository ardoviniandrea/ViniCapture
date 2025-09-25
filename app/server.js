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
    console.log('[Cleanup] Clearing all temporary stream files...');
    try {
        const files = fs.readdirSync(HLS_DIR);
        for (const file of files) {
            if (file.endsWith('.ts') || file.endsWith('.m3u8')) {
                fs.unlinkSync(path.join(HLS_DIR, file));
            }
        }
        console.log('[Cleanup] HLS directory cleared.');
    } catch (e) {
        console.error('[Cleanup] Error during file cleanup:', e.message);
    }
}

// ================================================================
// --- NEW: FFmpeg Profile Management ---
// ================================================================

/**
 * Returns the default list of profiles if none exist.
 */
function getDefaultProfiles() {
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
    if (!fs.existsSync(PROFILES_PATH)) {
        console.log('Profiles file not found, creating default profiles.');
        try {
            const defaults = getDefaultProfiles();
            fs.writeFileSync(PROFILES_PATH, JSON.stringify(defaults, null, 2));
            return defaults;
        } catch (e) {
            console.error("Failed to write default profiles:", e);
            return getDefaultProfiles(); // Return from memory
        }
    }
    try {
        const profilesData = fs.readFileSync(PROFILES_PATH, 'utf8');
        return JSON.parse(profilesData);
    } catch (e) {
        console.error("Failed to parse profiles.json, returning defaults:", e);
        return getDefaultProfiles(); // Return from memory
    }
}

/**
 * Saves the entire profiles object to the JSON file.
 * @param {object} profiles - The complete profiles object to save.
 */
function saveProfiles(profiles) {
    try {
        fs.writeFileSync(PROFILES_PATH, JSON.stringify(profiles, null, 2));
        console.log('Profiles saved successfully.');
        return true;
    } catch (e) {
        console.error("Failed to save profiles:", e);
        return false;
    }
}

/**
 * Gets the currently active profile.
 */
function getActiveProfile() {
    const profiles = getProfiles();
    let activeProfile = profiles.find(p => p.active);
    if (!activeProfile) {
        activeProfile = profiles[0]; // Fallback to first profile
        if (activeProfile) {
            activeProfile.active = true;
            saveProfiles(profiles); // Save the fallback state
        }
    }
    return activeProfile || getDefaultProfiles()[0]; // Ultimate fallback
}

// ================================================================
// --- API Endpoints (Updated) ---
// ================================================================

/**
 * API: Get current capture status
 */
app.get('/api/status', (req, res) => {
    res.json({
        running: (ffmpegProcess !== null)
    });
});

/**
 * API: Start the FFmpeg capture
 * (NOW USES THE ACTIVE PROFILE)
 */
app.post('/api/start', (req, res) => {
    if (ffmpegProcess) {
        return res.status(400).json({ error: 'Capture is already running' });
    }
    
    // 1. Clean up old files
    cleanupStreamFiles();

    // 2. Get the active profile command
    const activeProfile = getActiveProfile();
    if (!activeProfile || !activeProfile.command) {
        return res.status(500).json({ error: 'No active FFmpeg profile found or command is empty.' });
    }
    
    const commandString = activeProfile.command;

    // 3. Split command string into arguments, respecting quotes
    const args = (commandString.match(/(?:[^\s"]+|"[^"]*")+/g) || [])
                 .map(arg => arg.replace(/^"|"$/g, '')); // Remove surrounding quotes

    console.log(`[FFmpeg] Starting process with profile: ${activeProfile.name}`);
    console.log(`[FFmpeg] Command: ffmpeg ${args.join(' ')}`);

    // 4. Spawn the process
    ffmpegProcess = spawn('ffmpeg', args);

    ffmpegProcess.stdout.on('data', (data) => {
        // console.log(`ffmpeg stdout: ${data}`);
    });

    ffmpegProcess.stderr.on('data', (data) => {
        const stderrStr = data.toString();
        // Filter out verbose frame/size logs
        if (!stderrStr.startsWith('frame=') && !stderrStr.startsWith('size=')) {
             console.error(`[ffmpeg stderr]: ${stderrStr.trim()}`);
        }
    });

    ffmpegProcess.on('close', (code) => {
        console.log(`[ffmpeg] process exited with code ${code}`);
        ffmpegProcess = null;
        if (code !== 0 && code !== 255) { // 255 is SIGKILL (from /stop)
            console.error('[ffmpeg] Process exited unexpectedly. Cleaning up.');
        }
        cleanupStreamFiles();
    });

    ffmpegProcess.on('error', (err) => {
        console.error('[ffmpeg] Failed to start process:', err);
        ffmpegProcess = null;
    });

    res.json({ message: 'Capture started' });
});

/**
 * API: Stop the FFmpeg capture
 */
app.post('/api/stop', (req, res) => {
    if (ffmpegProcess) {
        console.log('[API] Stopping ffmpeg process...');
        ffmpegProcess.kill('SIGKILL');
        ffmpegProcess = null;
        res.json({ message: 'Capture stopped' });
    } else {
        res.status(400).json({ error: 'Capture is not running' });
    }
    // Clean up files after a short delay to ensure process is dead
    setTimeout(cleanupStreamFiles, 1000);
});

/**
 * NEW API: Get all profiles
 */
app.get('/api/profiles', (req, res) => {
    res.json(getProfiles());
});

/**
 * NEW API: Save all profiles
 */
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


// Serve the index.html for the root route
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Nginx proxies to this port
app.listen(port, '127.0.0.1', () => {
    console.log(`ViniCapture API listening on port ${port}`);
});

